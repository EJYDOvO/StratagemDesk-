import Foundation

public enum BundledArtwork {
    public static var directory: URL? { Bundle.module.url(forResource: "Artwork", withExtension: nil) }
}

public enum Direction: String, Codable, CaseIterable, Sendable {
    case up, down, left, right
    public var symbol: String { switch self { case .up: return "↑"; case .down: return "↓"; case .left: return "←"; case .right: return "→" } }
}
public enum ActionKind: String, Codable, CaseIterable, Sendable {
    case shell, executable, application, open, shortcut, delay, notification
    public var title: String { switch self {
    case .shell: return "Shell 脚本"; case .executable: return "可执行文件"; case .application: return "启动应用"
    case .open: return "打开 URL / 文件"; case .shortcut: return "macOS 快捷指令"; case .delay: return "延迟"; case .notification: return "状态通知"
    } }
}
public struct ActionDefinition: Identifiable, Codable, Equatable, Sendable {
    public var id: String = UUID().uuidString
    public var name = "新动作"
    public var kind: ActionKind = .shell
    public var target = ""
    public var shell = "/bin/zsh"
    public var arguments: [String] = []
    public var workingDirectory = ""
    public var environment: [String: String] = [:]
    public var timeout: Double = 30
    public var seconds: Double = 1
    public var approved = false
    public var sensitive = false
    public init() {}
    public var preview: String {
        if sensitive { return "[敏感动作：参数及输出不记录]" }
        switch kind {
        case .shell: return "\(shell) -c\n\(target)\n参数: \(arguments.joined(separator: " · "))\n目录: \(workingDirectory.isEmpty ? "用户主目录" : workingDirectory)\n环境: \(environment.keys.sorted().joined(separator: ", "))"
        case .delay: return "等待 \(seconds) 秒"
        default: return ([target] + arguments).joined(separator: "\n")
        }
    }
}
public struct WorkflowStep: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var actionID: String
    public var continueOnFailure = false
    public var delayAfter: Double = 0
    public init(actionID: String) { self.actionID = actionID }
}
public struct Stratagem: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var name = "自定义战备"
    public var sequence: [Direction] = []
    public var category = "自定义"
    public var icon = "command.square"
    public var description = ""
    public var enabled = false
    public var confirmation = true
    public var steps: [WorkflowStep] = []
    public init() {}
    public var sequenceText: String { sequence.map(\.symbol).joined(separator: " ") }
}
public struct AppSettings: Codable, Equatable, Sendable {
    public var hotkeyCode: UInt32 = 1 // physical S
    public var hotkeyModifiers: UInt32 = 2304 // Command + Option
    public var inputTimeout: Double = 5
    public var workflowTimeout: Double = 120
    public var closeAfterSuccess = true
    public var panelPosition = "topLeft"
    public init() {}
}
public struct Configuration: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var overrides: [String: Stratagem] = [:]
    public var custom: [Stratagem] = []
    public var actions: [ActionDefinition] = []
    public var settings = AppSettings()
    public init() {}
    public func resolved(builtins: [Stratagem]) -> [Stratagem] {
        let ids = Set(builtins.map(\.id))
        return builtins.map { overrides[$0.id] ?? $0 } + overrides.values.filter { !ids.contains($0.id) }.sorted { $0.id < $1.id } + custom
    }
    public func action(_ id: String) -> ActionDefinition? { actions.first { $0.id == id } }
    @discardableResult public mutating func setEnabled(_ enabled: Bool, for ids: Set<String>, builtins: [Stratagem]) -> Int {
        let targets = resolved(builtins: builtins).filter { ids.contains($0.id) && $0.enabled != enabled }
        for var entry in targets {
            entry.enabled = enabled
            if let index = custom.firstIndex(where: { $0.id == entry.id }) { custom[index] = entry }
            else { overrides[entry.id] = entry }
        }
        return targets.count
    }
}
public struct DeskError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
