import SwiftUI
import AppKit
import Darwin
import ApplicationServices

@main struct Launcher {
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "--command-host" {
            guard setsid() >= 0 || getpgrp() == getpid() else { perror("setsid"); exit(126) }
            let values = Array(args.dropFirst(2)).map { strdup($0) } + [nil]
            values.withUnsafeBufferPointer { pointer in _ = execv(args[2], pointer.baseAddress!) }
            perror("execv"); values.forEach { free($0) }; exit(127)
        }
        DesktopApp.main()
    }
}
struct DesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var overlay: OverlayManager!
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model = AppModel(); overlay = OverlayManager(model: model)
        model.showOverlay = { [weak self] in self?.overlay.show() }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "StratagemDesk Public — 战备管理器"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ConfigurationView(model: model)); window.center()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "command.square.fill", accessibilityDescription: "StratagemDesk")
        let menu = NSMenu()
        for (title, action) in [("打开战备终端", #selector(activate)), ("管理战备…", #selector(manage)), ("取消运行", #selector(cancel)), ("退出 StratagemDesk", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        statusItem.menu = menu
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "退出 StratagemDesk", action: #selector(quit), keyEquivalent: "q"); quitItem.target = self
        appMenu.addItem(quitItem); appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let editItem = NSMenuItem(); editItem.title = "编辑"; let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] { editMenu.addItem(withTitle: title, action: action, keyEquivalent: key) }
        editItem.submenu = editMenu; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        manage()
        #if DEBUG
        if CommandLine.arguments.contains("--profile-smoke"), CommandLine.arguments.contains("--configuration") {
            Task {
                do {
                    let result = try model.profileSmoke()
                    let directory = model.store.url.deletingLastPathComponent()
                    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent("profile-integration.json"))
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if let id = model.selection {
                        let renderer = ImageRenderer(content: StratagemProfileView(model: model, entryID: id)
                            .padding(16).frame(width: 760).environment(\.colorScheme, .light).background(Color.white))
                        renderer.scale = 2
                        if let cg = renderer.cgImage {
                            try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                                .write(to: directory.appendingPathComponent("profile-component.png"))
                        }
                    }
                } catch { fputs("Profile smoke failed: \(error)\n", stderr) }
                NSApp.terminate(nil)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-hud"), CommandLine.arguments.count > index + 1 {
            Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                do { try await overlay.renderPreview(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
                catch { fputs("HUD render failed: \(error)\n", stderr) }
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--integration-smoke"),
           CommandLine.arguments.contains("--ui-smoke"),
           CommandLine.arguments.contains("--configuration") {
            Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let result = await overlay.integrationSmoke()
                let file = model.store.url.deletingLastPathComponent().appendingPathComponent("integration-result.json")
                do {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(result).write(to: file, options: .atomic)
                } catch { fputs("Integration result write failed: \(error)\n", stderr) }
                NSApp.terminate(nil)
            }
        }
        #endif
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard let model, model.hotkey.usesExactLeftShift else { return }
        if model.hotkey.requiresAuthorization && AXIsProcessTrusted() || model.hotkey.hasGlobalHoldCapture && !AXIsProcessTrusted() {
            model.hotkeyError = model.hotkey.register(model.committed.settings)
        }
    }
    @objc func activate() { overlay.show() }
    @objc func manage() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func cancel() { model.executor.cancel() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.executor.runningID != nil else { return .terminateNow }
        model.executor.cancel()
        Task { await model.executor.waitUntilFinished(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
