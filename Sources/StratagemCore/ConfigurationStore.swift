import Foundation

public enum BuiltinCatalog {
    public static func load() throws -> [Stratagem] {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "builtins", withExtension: "json") else { throw DeskError("内置战备资源缺失") }
        return try JSONDecoder().decode([Stratagem].self, from: Data(contentsOf: url))
    }
    public static func defaults(builtins: [Stratagem]) -> Configuration {
        var config = Configuration()
        func bind(_ id: String, _ kind: ActionKind, _ target: String, _ label: String, arguments: [String] = []) {
            guard var item = builtins.first(where: { $0.id == id }) else { return }
            var action = ActionDefinition(); action.kind = kind; action.target = target; action.name = label
            action.arguments = arguments
            item.steps = [WorkflowStep(actionID: action.id)]
            config.actions.append(action); config.overrides[item.id] = item
        }
        bind("desk.terminal", .application, "/System/Applications/Utilities/Terminal.app", "启动 Terminal")
        bind("desk.home", .open, NSHomeDirectory(), "打开主目录")
        bind("desk.calculate", .application, "/System/Applications/Calculator.app", "打开计算器")
        bind("desk.files", .application, "/System/Library/CoreServices/Finder.app", "打开 Finder")
        bind("desk.clock", .executable, "/bin/date", "读取时间")
        bind("desk.status", .notification, "StratagemDesk Public ready", "状态通知")
        bind("desk.pause", .delay, "", "等待一秒")
        bind("desk.workflow", .shell, "printf 'StratagemDesk Public ready\\n'", "安全 Shell 测试")
        var custom = Stratagem(); custom.name = "Custom Stratagem"; custom.sequence = [.up, .right, .up, .down, .left]
        for (kind, value) in [(ActionKind.shell, "printf 'Workflow step 1\\n'"), (.delay, ""), (.notification, "工作流完成")] {
            var a = ActionDefinition(); a.kind = kind; a.name = kind.title; a.target = value
            config.actions.append(a); custom.steps.append(WorkflowStep(actionID: a.id))
        }
        config.custom = [custom]
        return config
    }
}
public struct ConfigurationStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StratagemDesk-Public/configuration.json")
    }
    public func load() throws -> Configuration { try Self.decode(Data(contentsOf: url)) }
    public static func decode(_ data: Data) throws -> Configuration {
        guard data.count <= 10_000_000 else { throw DeskError("配置超过 10 MB 限制") }
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        try validate(config)
        return config
    }
    public static func validate(_ config: Configuration) throws {
        guard config.schemaVersion == 1 else { throw DeskError("不支持的 schemaVersion：\(config.schemaVersion)") }
        let s = config.settings
        guard (0.5...60).contains(s.inputTimeout), (1...86400).contains(s.workflowTimeout),
              s.hotkeyCode <= 127, s.hotkeyModifiers & ~UInt32(6912) == 0, s.hotkeyModifiers & 6912 != 0,
              ["topLeft", "center", "top", "bottom"].contains(s.panelPosition) else { throw DeskError("设置数值无效；热键需包含 Shift、Control、Option 或 Command") }
        guard ![UInt32(36), 53, 76, 123, 124, 125, 126].contains(s.hotkeyCode) else { throw DeskError("呼出快捷键不能使用方向键、Return 或 Esc 作为主键") }
        let entries = Array(config.overrides.values) + config.custom
        guard Set(entries.map(\.id)).count == entries.count,
              Set(config.actions.map(\.id)).count == config.actions.count,
              config.overrides.allSatisfy({ $0.key == $0.value.id }) else { throw DeskError("配置中有重复或不一致的 ID") }
        let resolved = config.resolved(builtins: try BuiltinCatalog.load())
        guard Set(resolved.map(\.id)).count == resolved.count else { throw DeskError("自定义 ID 与内置 ID 冲突") }
        for a in config.actions {
            guard !a.id.isEmpty, (0.1...86400).contains(a.timeout), (0...86400).contains(a.seconds),
                  !([a.target, a.shell, a.workingDirectory] + a.arguments + Array(a.environment.keys) + Array(a.environment.values)).contains(where: { $0.contains("\0") }),
                  a.environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") }) else { throw DeskError("动作参数无效：\(a.name)") }
        }
        for item in entries {
            guard !item.id.isEmpty, !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.sequence.count <= 32, Set(item.steps.map(\.id)).count == item.steps.count,
                  item.steps.allSatisfy({ config.action($0.actionID) != nil && (0...86400).contains($0.delayAfter) }) else { throw DeskError("战备或步骤引用无效：\(item.name)") }
        }
    }
    public func save(_ config: Configuration) throws {
        try Self.validate(config)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func quarantinedImport(_ data: Data, preserving settings: AppSettings) throws -> Configuration {
        guard data.count <= 10_000_000 else { throw DeskError("配置超过 10 MB 限制") }
        guard var document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DeskError("配置必须为 JSON 对象") }
        // Replace platform settings before decoding: foreign key codes must never be
        // interpreted as macOS Carbon values, even during import validation.
        document["settings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
        var config = try decode(JSONSerialization.data(withJSONObject: document))
        for i in config.actions.indices { config.actions[i].approved = false }
        for i in config.custom.indices { config.custom[i].enabled = false; config.custom[i].confirmation = true }
        for id in Array(config.overrides.keys) { config.overrides[id]?.enabled = false; config.overrides[id]?.confirmation = true }
        return config
    }
    public static func exportData(_ config: Configuration, includeSensitive: Bool = false) throws -> Data {
        var copy = config
        if !includeSensitive {
            for i in copy.actions.indices where copy.actions[i].sensitive {
                copy.actions[i].target = ""; copy.actions[i].arguments = []; copy.actions[i].environment = [:]
                copy.actions[i].workingDirectory = ""; copy.actions[i].shell = "/bin/zsh"; copy.actions[i].approved = false
            }
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return try e.encode(copy)
    }
}
