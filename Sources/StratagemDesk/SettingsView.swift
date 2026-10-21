import SwiftUI
import AppKit
import Carbon
import ServiceManagement
import UserNotifications
import StratagemCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var recording = false
    @State private var monitor: Any?
    @State private var notificationStatus = "读取中"
    @State private var serviceStatus = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("全局设置").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }.padding(.horizontal)
            Form {
                Section("输入与执行") {
                    HStack {
                        Text("激活快捷键")
                        Spacer()
                        Text(hotkeyLabel)
                        Button(recording ? "按下组合键…（Esc 取消）" : "录制快捷键") { beginRecording() }
                    }
                    Text("默认 ⌥⌘S（Command + Option + S）。按住组合键显示并输入方向键，松开任一呼出键收起。可录制其他组合键；被占用时会提示。").font(.caption).foregroundStyle(.secondary)
                    if let error = model.hotkeyError { Text(error).foregroundStyle(.orange) }
                    HStack { Text("输入超时（0.5–60 秒）"); TextField("秒", value: $model.configuration.settings.inputTimeout, format: .number) }
                    HStack { Text("工作流超时（秒）"); TextField("秒", value: $model.configuration.settings.workflowTimeout, format: .number) }
                    Picker("悬浮位置", selection: $model.configuration.settings.panelPosition) {
                        Text("左上角（游戏 HUD）").tag("topLeft"); Text("居中").tag("center"); Text("屏幕上方").tag("top"); Text("屏幕下方").tag("bottom")
                    }
                    Text("窗口随按住状态显示；松开仅收起窗口，已经开始的工作流继续执行。").font(.caption).foregroundStyle(.secondary)
                }
                Section("启动与权限") {
                    HStack {
                        Text(model.hotkeyError != nil ? "热键未就绪" : "热键已就绪")
                        Spacer()
                        if model.hotkey.usesExactLeftShift {
                            Button("请求辅助功能权限") { model.hotkey.requestAccessibility() }
                        }
                        Button("重新检查") { model.hotkeyError = model.hotkey.register(model.committed.settings) }
                    }
                    HStack {
                        Text("登录启动：\(serviceStatus)")
                        Spacer()
                        Button("启用") { setLogin(true) }
                        Button("停用") { setLogin(false) }
                    }
                    HStack {
                        Text("系统通知：\(notificationStatus)")
                        Spacer()
                        Button("请求通知权限") {
                            Task { do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) } catch { model.message = error.localizedDescription }; await refreshNotifications() }
                        }
                    }
                    Text(model.hotkey.usesExactLeftShift
                         ? "左 Shift + Tab 需要辅助功能权限以精确区分左右 Shift；未授权时仅在本应用内可用，不保存输入内容。"
                         : "当前组合键使用 macOS 全局热键注册，无需辅助功能权限。按住时由战备窗口接收方向键。").font(.caption).foregroundStyle(.secondary)
                }
                Section("本地配置") {
                    HStack {
                        Button("导入 JSON…") { model.importFile() }
                        Button("导出 JSON…") { model.exportFile() }
                        Button("备份并恢复默认…") { model.restoreDefaults() }
                    }
                    Text(model.store.url.path).font(.caption).textSelection(.enabled)
                    Text("导入会停用所有战备及动作。敏感参数不导出；运行需要的配置仍以本地明文保存，文件权限为 0600。").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            HStack { Text(model.message).font(.caption).lineLimit(2); Spacer(); Button("保存设置") { model.save() }.keyboardShortcut("s") }.padding(.horizontal)
        }.padding(.vertical)
        .task { refreshService(); await refreshNotifications() }
        .onDisappear { endRecording() }
    }
    var hotkeyLabel: String {
        HotkeyManager.label(model.configuration.settings)
    }
    func beginRecording() {
        endRecording(); model.hotkey.unregister(); recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { endRecording(); return nil }
            if [UInt16(36), 76, 123, 124, 125, 126].contains(event.keyCode) {
                model.message = "请选择其他主键；方向键和 Return 用于输入及确认"
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.intersection([.shift, .control, .option, .command]).isEmpty else { return nil }
            var mods: UInt32 = 0
            if flags.contains(.control) { mods |= UInt32(controlKey) }; if flags.contains(.option) { mods |= UInt32(optionKey) }
            if flags.contains(.command) { mods |= UInt32(cmdKey) }; if flags.contains(.shift) { mods |= UInt32(shiftKey) }
            model.configuration.settings.hotkeyCode = UInt32(event.keyCode); model.configuration.settings.hotkeyModifiers = mods
            endRecording(); return nil
        }
    }
    func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if recording { model.hotkeyError = model.hotkey.register(model.committed.settings) }
        recording = false
    }
    func refreshService() {
        switch SMAppService.mainApp.status {
        case .enabled: serviceStatus = "已启用"
        case .requiresApproval: serviceStatus = "需要在系统设置批准"
        case .notRegistered: serviceStatus = "未启用"
        default: serviceStatus = "不可用（请将应用放入 Applications）"
        }
    }
    func setLogin(_ enable: Bool) {
        do { if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { model.message = "登录启动设置失败：\(error.localizedDescription)" }
        refreshService()
    }
    func refreshNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: notificationStatus = "已允许"
        case .denied: notificationStatus = "已拒绝（应用内状态可用）"
        default: notificationStatus = "未请求"
        }
    }
}
