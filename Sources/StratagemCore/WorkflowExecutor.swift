import Foundation
import Combine

public enum RunStatus: String, Codable, Sendable { case running, succeeded, failed, cancelled }
public struct StepLog: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var stepID: String
    public var name: String
    public var status: RunStatus
    public var detail: String
    public var date = Date()
    public init(stepID: String, name: String, status: RunStatus, detail: String) {
        self.stepID = stepID; self.name = name; self.status = status; self.detail = detail
    }
}
public struct ActionOutcome: Sendable {
    public var success: Bool
    public var detail: String
    public init(success: Bool, detail: String) { self.success = success; self.detail = detail }
}
@MainActor public final class WorkflowExecutor: ObservableObject {
    @Published public private(set) var runningID: String?
    @Published public private(set) var status: RunStatus = .succeeded
    @Published public private(set) var logs: [StepLog] = []
    @Published public private(set) var summary = "尚未执行"
    private var task: Task<Void, Never>?
    public var onFinished: ((RunStatus, [StepLog]) -> Void)?
    public init() {}
    public typealias Handler = @MainActor (ActionDefinition, Double) async throws -> ActionOutcome
    @discardableResult public func start(_ stratagem: Stratagem, configuration: Configuration, handler: @escaping Handler) -> Bool {
        guard runningID == nil else { return false }
        logs = []
        let actions = stratagem.steps.compactMap { configuration.action($0.actionID) }
        guard !stratagem.steps.isEmpty, actions.count == stratagem.steps.count, actions.allSatisfy(\.approved) else {
            status = .failed; summary = "请先配置工作流，并逐项审核启用全部动作"; return false
        }
        runningID = stratagem.id; status = .running; summary = "正在执行 \(stratagem.name)"
        // A sensitive step may pass secrets to later steps through files or process state.
        let redact = actions.contains(where: \.sensitive)
        task = Task {
            let deadline = ProcessInfo.processInfo.systemUptime + configuration.settings.workflowTimeout
            var failed = false
            do {
                for step in stratagem.steps {
                    try Task.checkCancellation()
                    guard let action = configuration.action(step.actionID) else { throw DeskError("动作引用不存在") }
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { throw DeskError("整条工作流超时") }
                    let index = logs.count
                    logs.append(StepLog(stepID: step.id, name: redact ? "敏感步骤 \(index + 1)" : action.name, status: .running, detail: "正在执行"))
                    do {
                        let budget = min(remaining, action.timeout)
                        let result = try await withThrowingTaskGroup(of: ActionOutcome.self) { group in
                            group.addTask { try await handler(action, budget) }
                            group.addTask {
                                try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                                throw DeskError("步骤或工作流超时")
                            }
                            defer { group.cancelAll() }
                            return try await group.next()!
                        }
                        try Task.checkCancellation()
                        logs[index].status = result.success ? .succeeded : .failed
                        logs[index].detail = redact ? "[敏感工作流：输出已隐藏]" : String(result.detail.prefix(16_384))
                        if !result.success { failed = true; if !step.continueOnFailure { throw DeskError("步骤执行失败") } }
                    } catch {
                        logs[index].status = Task.isCancelled ? .cancelled : .failed
                        if logs[index].detail == "正在执行" { logs[index].detail = redact ? "[敏感工作流：错误已隐藏]" : String(error.localizedDescription.prefix(16_384)) }
                        if Task.isCancelled || !step.continueOnFailure { throw error }
                        failed = true
                    }
                    if step.delayAfter > 0 {
                        let remaining = deadline - ProcessInfo.processInfo.systemUptime
                        guard remaining > step.delayAfter else { throw DeskError("步骤间延迟超过工作流剩余时间") }
                        try await Task.sleep(nanoseconds: UInt64(step.delayAfter * 1_000_000_000))
                    }
                }
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime <= deadline else { throw DeskError("整条工作流超时") }
                status = failed ? .failed : .succeeded
                summary = failed ? "执行结束，部分步骤失败" : "工作流执行成功"
            } catch {
                status = Task.isCancelled ? .cancelled : .failed
                summary = Task.isCancelled ? "工作流已取消" : (redact ? "工作流失败（敏感详情已隐藏）" : error.localizedDescription)
            }
            runningID = nil; task = nil; onFinished?(status, logs)
        }
        return true
    }
    public func cancel() { task?.cancel() }
    public func waitUntilFinished() async { await task?.value }
}
