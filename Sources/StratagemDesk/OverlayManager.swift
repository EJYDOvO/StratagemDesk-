import AppKit
import SwiftUI
import Combine
import StratagemCore

final class InputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
@MainActor final class OverlayManager: NSObject, ObservableObject, NSWindowDelegate {
    @Published var input: [Direction] = []
    @Published var status = "保持按住快捷键，输入方向序列"
    @Published var pending: Stratagem?
    @Published var matched: Stratagem?
    @Published var executionRejected = false
    @Published var holdActive = false
    @Published var presented = false
    @Published var panelSize = CGSize(width: 350, height: 450)
    let model: AppModel
    private var panel: InputPanel!
    private var monitor: Any?
    private var timer: Timer?
    private var subscription: AnyCancellable?
    private var previousApp: NSRunningApplication?
    private var hiding = false
    var shortcutLabel: String { model.hotkey.shortcutLabel }
    var candidates: [Stratagem] {
        let priority = ["desk.terminal", "desk.home", "desk.files", "desk.clock", "desk.calculate", "desk.workflow", "desk.status"]
        return model.activeEntries.filter { $0.enabled && $0.sequence.starts(with: input) }.sorted {
            let a = priority.firstIndex(of: $0.id) ?? 100, b = priority.firstIndex(of: $1.id) ?? 100
            return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a < b
        }
    }
    init(model: AppModel) {
        self.model = model
        super.init()
        panel = InputPanel(contentRect: NSRect(origin: .zero, size: panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "战备终端"; panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none; panel.delegate = self
        panel.contentView = NSHostingView(rootView: OverlayView(overlay: self, executor: model.executor))
        model.hotkey.activate = { [weak self] in self?.beginHold() }
        model.hotkey.release = { [weak self] in self?.endHold() }
        model.hotkey.direction = { [weak self] direction in self?.receive(direction) }
        model.hotkey.confirm = { [weak self] in self?.confirm() }
        model.hotkey.cancel = { [weak self] in
            guard let self else { return }; self.model.executor.cancel(); self.close()
        }
        // Exact Shift+Tab is handled centrally (event tap or in-app fallback). Other registered
        // chords keep direction handling local to the focused panel, with their modifiers held.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel, self.panel.isKeyWindow else { return event }
            if event.keyCode == 53 { self.cancelOrClose(); return nil }
            guard self.holdActive, !self.model.hotkey.usesExactLeftShift else { return event }
            if event.keyCode == 36 { self.confirm(); return nil }
            if let direction = [UInt16(126):Direction.up,125:.down,123:.left,124:.right][event.keyCode] {
                if !event.isARepeat { self.receive(direction) }; return nil
            }
            return event
        }
        subscription = model.executor.$status.dropFirst().sink { [weak self] value in
            DispatchQueue.main.async { self?.finished(value) }
        }
    }
    /// Menu / manager entry: preview only; typing requires a held activation chord.
    func show() { present(held: false) }
    func beginHold() { present(held: true) }
    func endHold() { close() } // Running work continues; unconfirmed input is discarded.
    private func present(held: Bool) {
        guard !model.loadFailed else { model.message = "请先修复配置加载错误"; return }
        if holdActive && held { return }
        timer?.invalidate()
        if !panel.isVisible { previousApp = NSWorkspace.shared.frontmostApplication }
        holdActive = held; input = []; pending = nil; executionRejected = false
        if let runningID = model.executor.runningID {
            var fallback = Stratagem(); fallback.id = runningID; fallback.name = "正在执行的工作流"
            matched = model.activeEntries.first(where: { $0.id == runningID }) ?? model.entry(runningID) ?? fallback
            status = model.executor.summary
        } else {
            matched = nil
            status = held ? "输入方向序列" : "按住 \(shortcutLabel) 开始输入"
            if held { resetTimer() }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let rect = screen?.visibleFrame {
            panelSize = CGSize(width: min(350, rect.width - 32), height: min(450, rect.height - 48))
            let origin: NSPoint
            switch model.committed.settings.panelPosition {
            case "center": origin = NSPoint(x: rect.midX - panelSize.width / 2, y: rect.midY - panelSize.height / 2)
            case "top": origin = NSPoint(x: rect.midX - panelSize.width / 2, y: rect.maxY - panelSize.height - 24)
            case "bottom": origin = NSPoint(x: rect.midX - panelSize.width / 2, y: rect.minY + 24)
            default: origin = NSPoint(x: rect.minX + 18, y: rect.maxY - panelSize.height - 18)
            }
            panel.setFrame(NSRect(origin: origin, size: panelSize), display: false)
        }
        presented = false
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }; self.presented = true
        }
    }
    func receive(_ direction: Direction) {
        guard holdActive, panel.isVisible, model.executor.runningID == nil, pending == nil, matched == nil else { return }
        let entries = model.activeEntries
        if !SequenceMatcher.conflicts(in: entries).isEmpty { status = "序列冲突，请在管理器中修复并保存"; timer?.invalidate(); return }
        input.append(direction); resetTimer()
        switch SequenceMatcher.match(input, in: entries) {
        case .matched(let id):
            timer?.invalidate()
            guard let entry = entries.first(where: { $0.id == id }) else { return }
            matched = entry
            if entry.confirmation { pending = entry; status = "保持按住，按 Return 确认；松开取消" }
            else { launch(entry) }
        case .waiting(let ids): status = "继续输入 · \(ids.count) 个候选"
        case .invalid: input = []; status = "序列错误 · 已重置，请重新输入"
        case .ambiguous: input = []; status = "序列冲突 · 已阻止执行"
        }
    }
    func confirm() { guard holdActive, let item = pending else { return }; pending = nil; launch(item) }
    private func launch(_ item: Stratagem) {
        model.run(item, config: model.committed, preview: false)
        executionRejected = model.executor.runningID != item.id
        status = model.executor.runningID == nil ? model.message : "正在执行 \(item.name)"
    }
    func cancelOrClose() {
        if model.executor.runningID != nil { model.executor.cancel() }
        model.hotkey.cancelSession(); close()
    }
    func close() {
        hiding = true
        defer { hiding = false }
        holdActive = false; presented = false; timer?.invalidate(); timer = nil
        pending = nil; input = []; matched = nil; executionRejected = false
        let shouldRestore = panel.isKeyWindow
        panel.orderOut(nil)
        if shouldRestore, previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousApp?.activate(options: [])
        }
    }
    private func resetTimer() {
        timer?.invalidate()
        let next = Timer(timeInterval: model.committed.settings.inputTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.holdActive else { return }
                self.input = []; self.status = "输入超时 · 继续输入或松开重试"
            }
        }
        timer = next; RunLoop.main.add(next, forMode: .common)
    }
    private func finished(_ value: RunStatus) {
        guard panel.isVisible, matched != nil, value != .running else { return }
        status = model.executor.summary
        // Hold controls visibility. Finishing never closes a panel the user is still holding.
    }
    func windowDidResignKey(_ notification: Notification) {
        guard !hiding, panel.isVisible else { return }
        let trackingExecutedCommand = model.hotkey.hasRegisteredShortcut && matched != nil
        if !holdActive || (!model.hotkey.hasGlobalHoldCapture && !trackingExecutedCommand) {
            model.hotkey.cancelSession(); close()
        }
    }
    #if DEBUG
    func integrationSmoke() async -> [String: String] {
        model.hotkey.activate?()
        try? await Task.sleep(nanoseconds: 150_000_000)
        let focused = panel.isKeyWindow
        for direction in [Direction.up, .right, .down, .left] { receive(direction) }
        let recognized = pending?.id == "acceptance"
        model.hotkey.release?()
        confirm()
        let releasedPendingCancelled = pending == nil && model.executor.runningID == nil && model.executor.logs.isEmpty
        model.hotkey.activate?()
        for direction in [Direction.up, .right, .down, .left] { receive(direction) }
        confirm()
        let started = model.executor.runningID != nil
        model.hotkey.release?()
        let hidden = !panel.isVisible && !holdActive && pending == nil
        await model.executor.waitUntilFinished()
        let output = model.executor.logs.contains { $0.detail.contains("STRATAGEMDESK_E2E_OK") }
        receive(.up)
        let releasedInputIgnored = input.isEmpty
        var rejectedIsExplicit = false
        let original = model.committed
        if let item = model.activeEntries.first(where: { $0.id == "acceptance" }),
           let actionID = item.steps.first?.actionID,
           let index = model.committed.actions.firstIndex(where: { $0.id == actionID }) {
            model.committed.actions[index].approved = false
            beginHold()
            for direction in item.sequence { receive(direction) }
            confirm()
            rejectedIsExplicit = executionRejected && model.executor.runningID == nil
            endHold()
            model.committed = original
        }
        return ["hotkeyRegistration": model.hotkeyError ?? "registered", "panelIsKeyWindow": String(focused),
                "sequenceRecognized": String(recognized), "workflowStatus": model.executor.status.rawValue,
                "stdoutVerified": String(output), "releaseHidesPanel": String(hidden),
                "releaseCancelsUnconfirmedInput": String(releasedPendingCancelled),
                "startedWorkflowContinuesAfterRelease": String(started && hidden && output && model.executor.status == .succeeded),
                "inputWhileReleasedIgnored": String(releasedInputIgnored),
                "rejectedActionHasExplicitBlockedState": String(rejectedIsExplicit),
                "scope": "Native controller integration; physical keyboard and global permission behavior require separate verification."]
    }
    func renderPreview(to directory: URL) async throws {
        // Component rendering only: no desktop screenshot or keyboard injection.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        beginHold()
        var backgroundAlpha: CGFloat = 0
        for (name, sequence) in [("hud-idle", [Direction]()), ("hud-prefix", [.up, .right]),
                                 ("hud-confirmation", [.right, .right, .up]), ("hud-blocked", [.right, .right, .up])] {
            input = sequence; status = sequence.isEmpty ? "输入方向序列" : "继续输入 · \(candidates.count) 个候选"
            matched = nil; pending = nil; executionRejected = false
            if name == "hud-confirmation" || name == "hud-blocked" {
                matched = model.activeEntries.first { $0.id == "desk.workflow" }
                if name == "hud-confirmation" { pending = matched }
                else { executionRejected = true; status = "请逐项审核并启用全部动作后执行" }
            }
            try await Task.sleep(nanoseconds: 350_000_000)
            // ImageRenderer omits AppKit-backed ScrollView content. Render the actual hosted
            // view after layout instead, including its scrolling candidates and alpha channel.
            guard let view = panel.contentView else { throw DeskError("HUD 视图不存在") }
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DeskError("HUD 渲染失败") }
            view.cacheDisplay(in: view.bounds, to: rep)
            if name == "hud-idle" {
                backgroundAlpha = rep.colorAt(x: rep.pixelsWide - 30, y: Int(CGFloat(rep.pixelsHigh) * 0.20))?.alphaComponent ?? 0
            }
            guard let data = rep.representation(using: .png, properties: [:]) else { throw DeskError("PNG 编码失败") }
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        let missing = model.builtins.filter { GameArtwork.shared.image(for: $0) == nil }.map(\.id)
        let report: [String: Any] = [
            "builtins": model.builtins.count, "artworkLoaded": model.builtins.count - missing.count,
            "bundledArtworkOnly": CommandLine.arguments.contains("--bundled-artwork-only"),
            "bundledArtworkAvailable": BundledArtwork.directory != nil,
            "missingArtwork": missing, "panelWidth": panelSize.width, "panelHeight": panelSize.height,
            "panelOpaque": panel.isOpaque,
            "backgroundAlphaSample": backgroundAlpha,
            "fontAvailable": NSFont(name: "DINAlternate-Bold", size: 15) != nil,
            "scope": "Native NSHostingView component render, not a desktop screenshot."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("artwork-validation.json"))
        endHold()
    }
    #endif
}
