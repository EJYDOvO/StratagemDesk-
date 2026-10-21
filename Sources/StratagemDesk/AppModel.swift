import AppKit
import SwiftUI
import UniformTypeIdentifiers
import StratagemCore

@MainActor final class AppModel: ObservableObject {
    @Published var configuration = Configuration()
    @Published var committed = Configuration()
    @Published var builtins: [Stratagem] = []
    @Published var message = ""
    @Published var hotkeyError: String?
    @Published var loadFailed = false
    @Published var selection: String?
    @Published var hasSavedConfiguration = false
    private var factoryDefaults = Configuration()
    let executor = WorkflowExecutor()
    let registry = ActionRegistry()
    let hotkey = HotkeyManager()
    let store: ConfigurationStore
    var showOverlay: (() -> Void)?
    var entries: [Stratagem] { configuration.resolved(builtins: builtins) }
    var activeEntries: [Stratagem] { committed.resolved(builtins: builtins) }
    var dirty: Bool { configuration != committed }
    var conflicts: [String] { SequenceMatcher.conflicts(in: entries) }
    init() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--configuration"), args.count > index + 1 {
            store = ConfigurationStore(url: URL(fileURLWithPath: args[index + 1]))
        } else { store = ConfigurationStore(url: ConfigurationStore.defaultURL) }
        do {
            builtins = try BuiltinCatalog.load()
            factoryDefaults = BuiltinCatalog.defaults(builtins: builtins)
            if FileManager.default.fileExists(atPath: store.url.path) { configuration = try store.load(); hasSavedConfiguration = true }
            else { configuration = factoryDefaults }
            #if DEBUG
            if args.contains("--ui-smoke") {
                // Explicit, isolated acceptance fixture. Only emits a constant string.
                guard args.contains("--configuration") else { throw DeskError("UI 验收必须使用独立配置路径") }
                var a = ActionDefinition(); a.name = "验收：只读 Shell"; a.kind = .shell
                a.target = "printf 'STRATAGEMDESK_E2E_OK\\n'"; a.approved = true
                var item = Stratagem(); item.id = "acceptance"; item.name = "桌面验收"; item.category = "验收"
                item.sequence = [.up, .right, .down, .left]; item.enabled = true; item.confirmation = true
                item.steps = [WorkflowStep(actionID: a.id)]
                configuration.actions.append(a); configuration.custom.append(item); selection = item.id
            }
            #endif
            committed = configuration
        } catch { loadFailed = true; message = "配置未加载，原文件已保留：\(error.localizedDescription)" }
        hotkey.reportError = { [weak self] error in self?.hotkeyError = error }
        hotkeyError = hotkey.register(committed.settings)
        executor.onFinished = { [weak self] _, logs in self?.saveLogs(logs) }
    }
    func entry(_ id: String) -> Stratagem? { entries.first { $0.id == id } }
    func update(_ entry: Stratagem) {
        if let index = configuration.custom.firstIndex(where: { $0.id == entry.id }) { configuration.custom[index] = entry }
        else { configuration.overrides[entry.id] = entry }
    }
    func binding(_ id: String) -> Binding<Stratagem> {
        Binding(get: { self.entry(id) ?? Stratagem() }, set: { self.update($0) })
    }
    func setEnabled(_ enabled: Bool, for ids: Set<String>) {
        let count = configuration.setEnabled(enabled, for: ids, builtins: builtins)
        message = count == 0 ? "所选战备已处于目标状态" : "已\(enabled ? "启用" : "停用") \(count) 个战备，请保存以生效"
    }
    func actionBinding(_ step: WorkflowStep, for entryID: String) -> Binding<ActionDefinition>? {
        func actionID() -> String? { self.entry(entryID)?.steps.first(where: { $0.id == step.id })?.actionID }
        guard let id = actionID(), configuration.action(id) != nil else { return nil }
        return Binding(get: { self.configuration.action(actionID() ?? "") ?? ActionDefinition() }, set: { action in
            guard let id = actionID(), var profile = self.configuration.profile(for: entryID, builtins: self.builtins),
                  let index = profile.actions.firstIndex(where: { $0.id == id }) else { return }
            var revised = action
            revised.id = id
            var oldContent = profile.actions[index]; oldContent.approved = revised.approved
            if oldContent != revised { revised.approved = false }
            profile.actions[index] = revised
            self.configuration.apply(profile, builtins: self.builtins)
        })
    }
    func defaultProfile(_ id: String) -> StratagemProfile {
        if builtins.contains(where: { $0.id == id }), let profile = factoryDefaults.profile(for: id, builtins: builtins) { return profile }
        var blank = Stratagem(); blank.id = id
        return StratagemProfile(entry: blank, actions: [])
    }
    func savedProfile(_ id: String) -> StratagemProfile? {
        hasSavedConfiguration ? committed.profile(for: id, builtins: builtins) : nil
    }
    func restoreProfile(_ id: String, useDefault: Bool) {
        guard let profile = useDefault ? defaultProfile(id) : savedProfile(id) else { return }
        configuration.apply(profile, builtins: builtins)
        message = useDefault ? "已恢复此战备的默认内容，请保存以生效" : "已撤销此战备的未保存更改"
    }
    @discardableResult func saveProfile(_ id: String) -> Bool {
        guard !loadFailed else { message = "请先修复配置加载错误"; return false }
        guard let profile = configuration.profile(for: id, builtins: builtins) else { return false }
        do {
            var next = committed
            next.apply(profile, builtins: builtins)
            try ConfigurationStore.validate(next)
            let entries = next.resolved(builtins: builtins)
            guard Set(entries.map(\.id)).count == entries.count else { throw DeskError("自定义 ID 与内置 ID 冲突") }
            if let conflict = SequenceMatcher.conflicts(in: entries).first { throw DeskError(conflict) }
            try store.save(next)
            committed = next; hasSavedConfiguration = true
            if let saved = next.profile(for: id, builtins: builtins) { configuration.apply(saved, builtins: builtins) }
            hotkeyError = hotkey.register(committed.settings)
            message = "已单独保存此战备，终端映射已更新"; return true
        } catch { message = "此战备未保存：\(error.localizedDescription)"; return false }
    }
    @discardableResult func save() -> Bool {
        guard !loadFailed else { message = "请先备份损坏配置并恢复，再保存"; return false }
        do {
            try ConfigurationStore.validate(configuration)
            guard Set(entries.map(\.id)).count == entries.count else { throw DeskError("自定义 ID 与内置 ID 冲突") }
            if let conflict = conflicts.first { throw DeskError(conflict) }
            try store.save(configuration)
            committed = configuration; hasSavedConfiguration = true; hotkeyError = hotkey.register(committed.settings)
            message = "已保存，新的战备映射立即生效"; return true
        } catch { message = error.localizedDescription; return false }
    }
    func add() { var entry = Stratagem(); entry.name = "自定义战备 \(configuration.custom.count + 1)"; configuration.custom.append(entry); selection = entry.id }
    func duplicate(_ entry: Stratagem) {
        var copy = entry; copy.id = UUID().uuidString; copy.name += " 副本"; copy.enabled = false
        copy.steps = copy.steps.map { step in var s = step; s.id = UUID().uuidString; return s }
        configuration.custom.append(copy); selection = copy.id
    }
    func delete(_ entry: Stratagem) {
        if configuration.custom.contains(where: { $0.id == entry.id }) { configuration.custom.removeAll { $0.id == entry.id }; selection = nil }
        else { var e = entry; e.enabled = false; e.steps = []; update(e); message = "已停用内置战备并清除映射；内置定义保留" }
    }
    func addAction(_ kind: ActionKind, to id: String) {
        var a = ActionDefinition(); a.kind = kind; a.name = kind.title
        if kind == .shell { a.target = "printf 'Hello from StratagemDesk\\n'" }
        configuration.actions.append(a)
        guard var entry = entry(id) else { return }; entry.steps.append(WorkflowStep(actionID: a.id)); update(entry)
    }
    func copyAction(_ action: ActionDefinition, to id: String) {
        var copy = action; copy.id = UUID().uuidString; copy.approved = false
        configuration.actions.append(copy)
        guard var entry = entry(id) else { return }
        entry.steps.append(WorkflowStep(actionID: copy.id)); update(entry)
    }
    func run(_ entry: Stratagem, config: Configuration? = nil, preview: Bool = true) {
        guard executor.runningID == nil else { message = "已有工作流正在运行，请先取消或等待完成"; return }
        let config = config ?? configuration
        do { try ConfigurationStore.validate(config) } catch { message = error.localizedDescription; return }
        guard !entry.steps.isEmpty, entry.steps.allSatisfy({ config.action($0.actionID)?.approved == true }) else { message = "请逐项审核并启用全部动作后执行"; return }
        if preview {
            let alert = NSAlert(); alert.messageText = "执行 \(entry.name)？"
            alert.informativeText = previewText(entry, config: config)
            alert.addButton(withTitle: "执行"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        _ = executor.start(entry, configuration: config) { [registry] action, timeout in try await registry.execute(action, timeout: timeout) }
    }
    func previewText(_ entry: Stratagem, config: Configuration) -> String {
        entry.steps.enumerated().map { index, step in
            guard let a = config.action(step.actionID) else { return "缺失动作" }
            return "\(index + 1). \(a.name) [\(a.kind.title)]\n\(a.preview)\n失败后\(step.continueOnFailure ? "继续" : "停止") · 步后延迟 \(step.delayAfter)s"
        }.joined(separator: "\n\n")
    }
    func testStep(_ step: WorkflowStep) {
        var entry = Stratagem(); entry.name = "单步测试"; entry.steps = [step]; run(entry)
    }
    func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try ConfigurationStore.quarantinedImport(Data(contentsOf: url), preserving: committed.settings)
            let alert = NSAlert(); alert.messageText = "导入并替换当前配置？"
            alert.informativeText = "当前配置会在本地备份。导入的所有战备默认停用，动作必须逐项审核启用。全局设置保持不变。"
            alert.addButton(withTitle: "备份并导入"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try backup(); try store.save(imported)
            configuration = imported; committed = imported; hasSavedConfiguration = true; loadFailed = false; selection = nil
            message = "导入完成：请逐项审核动作、启用战备并保存"
        } catch { message = "导入失败：\(error.localizedDescription)" }
    }
    func exportFile() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "StratagemDesk.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ConfigurationStore.exportData(configuration).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            message = "已导出；敏感动作的参数和脚本已清空"
        } catch { message = error.localizedDescription }
    }
    func restoreDefaults() {
        let alert = NSAlert(); alert.messageText = "备份当前配置并恢复默认？"
        alert.informativeText = "所有默认映射均需重新审核启用。备份保存在配置文件旁。"
        alert.addButton(withTitle: "备份并恢复"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try backup(); let config = BuiltinCatalog.defaults(builtins: builtins); try store.save(config)
            configuration = config; committed = config; hasSavedConfiguration = true; loadFailed = false; selection = nil
            hotkeyError = hotkey.register(config.settings); message = "已恢复默认配置"
        } catch { message = error.localizedDescription }
    }
    private func backup() throws {
        if FileManager.default.fileExists(atPath: store.url.path) {
            let target = store.url.deletingLastPathComponent().appendingPathComponent("configuration-backup-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: store.url, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
    }
    #if DEBUG
    func profileSmoke() throws -> [String: Bool] {
        guard CommandLine.arguments.contains("--configuration") else { throw DeskError("档案验收必须使用独立配置") }
        var first = Stratagem(); first.name = "档案 A"; first.sequence = [.down]
        var second = Stratagem(); second.name = "档案 B"; second.sequence = [.down, .up]
        var action = ActionDefinition(); action.name = "档案动作"; action.target = "printf profile"
        first.steps = [WorkflowStep(actionID: action.id)]; second.steps = first.steps
        configuration = Configuration(); configuration.custom = [first, second]; configuration.actions = [action]
        committed = configuration; try store.save(committed); hasSavedConfiguration = true
        var result: [String: Bool] = [:]
        var edited = action; edited.target = "printf changed"
        actionBinding(first.steps[0], for: first.id)?.wrappedValue = edited
        result["editingSharedActionIsIsolated"] = configuration.profile(for: second.id, builtins: builtins)?.actions == [action]
        configuration.custom[0].name = "档案 A 当前"; configuration.custom[1].name = "档案 B 草稿"
        configuration.settings.inputTimeout = 17
        result["singleSaveSucceeded"] = saveProfile(first.id)
        let disk = try store.load()
        result["otherDraftAndSettingsNotSaved"] = disk.custom[1].name == second.name && disk.settings.inputTimeout == 5
            && configuration.custom[1].name == "档案 B 草稿" && configuration.settings.inputTimeout == 17
        configuration.custom[0].name = "未保存改名"
        restoreProfile(first.id, useDefault: false)
        result["restoreSavedIncludesAction"] = configuration.profile(for: first.id, builtins: builtins)?.equivalent(to: disk.profile(for: first.id, builtins: builtins)!) == true
        configuration.custom[1].enabled = true
        result["secondSaveSucceeded"] = saveProfile(second.id)
        configuration.custom[0].enabled = true
        let beforeFailure = try Data(contentsOf: store.url)
        let conflictRejected = !saveProfile(first.id)
        let afterFailure = try Data(contentsOf: store.url)
        result["conflictingSavePreservesDisk"] = conflictRejected && afterFailure == beforeFailure
        restoreProfile(first.id, useDefault: true)
        result["customDefaultIsDisabledBlankTemplate"] = entry(first.id)?.enabled == false && entry(first.id)?.steps.isEmpty == true && entry(first.id)?.sequence.isEmpty == true
        result["defaultOnlyChangesDraft"] = committed.custom[0].name == "档案 A 当前"
        // Select a builtin to render the real manager with three distinct snapshots.
        selection = "desk.workflow"
        if var demo = configuration.profile(for: selection!, builtins: builtins) {
            demo.entry.name += " · 当前编辑"; configuration.apply(demo, builtins: builtins)
        }
        return result
    }
    #endif
    private func saveLogs(_ logs: [StepLog]) {
        do {
            let url = store.url.deletingLastPathComponent().appendingPathComponent("last-run.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted]; e.dateEncodingStrategy = .iso8601
            try e.encode(logs).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { message = "日志保存失败：\(error.localizedDescription)" }
    }
}
