import AppKit
import UserNotifications
import StratagemCore

@MainActor final class ActionRegistry {
    let runner = CommandRunner(hostURL: Bundle.main.executableURL)
    func execute(_ action: ActionDefinition, timeout: Double) async throws -> ActionOutcome {
        try Task.checkCancellation()
        guard action.approved else { throw DeskError("动作尚未审核启用") }
        switch action.kind {
        case .shell, .executable, .shortcut:
            let executable: String, arguments: [String]
            switch action.kind {
            case .shell: executable = action.shell; arguments = ["-c", action.target, "StratagemDesk"] + action.arguments
            case .shortcut: executable = "/usr/bin/shortcuts"; arguments = ["run", action.target] + action.arguments
            default: executable = action.target; arguments = action.arguments
            }
            let result = try await runner.run(executable: executable, arguments: arguments, directory: action.workingDirectory, environment: action.environment, timeout: timeout)
            if result.cancelled { throw CancellationError() }
            return ActionOutcome(success: result.succeeded, detail: "退出码：\(result.exitCode)\(result.timedOut ? " · 超时" : "")\(result.truncated ? " · 输出截断" : "")\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
        case .delay:
            guard action.seconds <= timeout else { throw DeskError("延迟超过剩余超时时间") }
            try await Task.sleep(nanoseconds: UInt64(action.seconds * 1_000_000_000))
            return ActionOutcome(success: true, detail: "延迟完成")
        case .application:
            let path = (action.target as NSString).expandingTildeInPath
            let url: URL?
            if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
            else { url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.target) }
            guard let url else { throw DeskError("未找到应用，请填写 .app 绝对路径或 Bundle ID") }
            let config = NSWorkspace.OpenConfiguration(); config.arguments = action.arguments
            // Opening is an OS dispatch, not a wait for the launched app to exit.
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            return ActionOutcome(success: true, detail: "应用启动请求已完成")
        case .open:
            let target = (action.target as NSString).expandingTildeInPath
            let url = target.hasPrefix("/") ? URL(fileURLWithPath: target) : URL(string: target)
            guard let url, url.scheme != nil else { throw DeskError("请输入有效 URL 或绝对文件路径") }
            let success = NSWorkspace.shared.open(url)
            return ActionOutcome(success: success, detail: success ? "已提交打开请求" : "系统无法打开此目标")
        case .notification:
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                let content = UNMutableNotificationContent(); content.title = "StratagemDesk"
                content.body = action.sensitive ? "工作流状态更新" : action.target
                try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
            return ActionOutcome(success: true, detail: action.target + (settings.authorizationStatus == .authorized ? "" : "\n系统通知未启用，已显示为执行状态"))
        }
    }
}
