import AppKit
import Carbon
import ApplicationServices
import StratagemCore

final class HotkeyManager {
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var localMonitor: Any?
    private var releaseTimer: Timer?
    private var state = HoldShortcutState()
    private var settings = AppSettings()
    private var carbonHeld = false
    private var carbonSuppressed = false
    private var generation = 0
    var activate: (() -> Void)?
    var release: (() -> Void)?
    var direction: ((Direction) -> Void)?
    var confirm: (() -> Void)?
    var cancel: (() -> Void)?
    var reportError: ((String) -> Void)?
    var usesExactLeftShift: Bool { settings.hotkeyCode == 48 && settings.hotkeyModifiers == 512 }
    var hasGlobalHoldCapture: Bool { tap != nil }
    var hasRegisteredShortcut: Bool { hotkey != nil }
    var requiresAuthorization: Bool { usesExactLeftShift && tap == nil }
    var shortcutLabel: String { Self.label(settings) }
    static func label(_ s: AppSettings) -> String {
        if s.hotkeyCode == 48 && s.hotkeyModifiers == 512 { return "左 Shift + Tab" }
        let names: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M",48:"Tab",49:"Space"]
        return (s.hotkeyModifiers & 4096 != 0 ? "⌃" : "") + (s.hotkeyModifiers & 2048 != 0 ? "⌥" : "") + (s.hotkeyModifiers & 512 != 0 ? "⇧" : "") + (s.hotkeyModifiers & 256 != 0 ? "⌘" : "") + (names[s.hotkeyCode] ?? "Key \(s.hotkeyCode)")
    }
    func register(_ settings: AppSettings) -> String? {
        unregister(); self.settings = settings
        if usesExactLeftShift { return installExactHoldCapture() }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let installed = InstallEventHandler(GetEventDispatcherTarget(), { _, event, pointer in
            guard let pointer, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x53545241, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(pointer).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) { manager.beginCarbonHold() }
            else { manager.endCarbonHold() }
            return noErr
        }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return "热键处理器注册失败（\(installed)），可使用菜单栏预览" }
        let status = RegisterEventHotKey(settings.hotkeyCode, settings.hotkeyModifiers, EventHotKeyID(signature: 0x53545241, id: 1), GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &hotkey)
        return status == noErr ? nil : "快捷键被占用或不可用（\(status)）；请更换快捷键"
    }
    private func installExactHoldCapture() -> String? {
        // Unlike Carbon's modifier mask, Quartz device flags distinguish left and right Shift.
        // No event tap is created until the user has granted Accessibility; no automatic prompt.
        if AXIsProcessTrusted() {
            let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(pointer).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    manager.generation += 1; manager.state.reset(); manager.release?()
                    if type == .tapDisabledByTimeout, let tap = manager.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    else { manager.reportError?("键盘捕获已暂停，请在设置中重新检查权限") }
                    return Unmanaged.passUnretained(event)
                }
                let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let kind: HoldShortcutState.Event = type == .keyDown ? .down(code, repeatKey: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) : type == .keyUp ? .up(code) : .modifiersChanged
                let consumed = manager.handle(kind, flags: event.flags.rawValue)
                return consumed ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        }
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            return nil
        }
        // Safe fallback: exact chord only inside our own focused app; never claim global support.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let kind: HoldShortcutState.Event = event.type == .keyDown ? .down(event.keyCode, repeatKey: event.isARepeat) : event.type == .keyUp ? .up(event.keyCode) : .modifiersChanged
            return self.handle(kind, flags: UInt64(event.modifierFlags.rawValue)) ? nil : event
        }
        return "全局左 Shift + Tab 需要辅助功能权限。当前仅在 StratagemDesk 聚焦时可用；请到设置中授权并重新检查。"
    }
    private func handle(_ event: HoldShortcutState.Event, flags: UInt64) -> Bool {
        let leftShift = flags & 0x00000002 != 0 // NX_DEVICELSHIFTKEYMASK (IOKit public header)
        let other = flags & (CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue) != 0
        let decision = state.handle(event, leftShift: leftShift, otherModifiers: other)
        let currentGeneration = generation
        for effect in decision.effects {
            // Never do UI work or command dispatch in a Quartz callback.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                switch effect {
                case .began: self.activate?()
                case .ended: self.release?()
                case .direction(let direction): self.direction?(direction)
                case .confirm: self.confirm?()
                case .cancel: self.cancel?()
                }
            }
        }
        return decision.consume
    }
    private func beginCarbonHold() {
        guard !carbonHeld, !carbonSuppressed else { return }; carbonHeld = true; activate?()
        let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            guard let self, self.carbonHeld || self.carbonSuppressed else { return }
            let modifiers = UInt32(GetCurrentKeyModifiers())
            // Carbon supplies the trigger key's release; polling only modifier flags avoids
            // depending on global key-state access for this permission-free backend.
            if modifiers & self.settings.hotkeyModifiers != self.settings.hotkeyModifiers { self.endCarbonHold() }
        }
        releaseTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func endCarbonHold() {
        let wasHeld = carbonHeld
        carbonHeld = false; carbonSuppressed = false
        releaseTimer?.invalidate(); releaseTimer = nil
        if wasHeld { release?() }
    }
    func cancelSession() {
        generation += 1
        if tap == nil { state.reset() } else { state.cancelSession() }
        // Keep observing release after Esc/focus loss so held-key repeats cannot reopen the HUD.
        carbonSuppressed = carbonHeld || carbonSuppressed
        carbonHeld = false
        if !carbonSuppressed { releaseTimer?.invalidate(); releaseTimer = nil }
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func unregister() {
        generation += 1
        state.reset(); carbonHeld = false; carbonSuppressed = false; releaseTimer?.invalidate(); releaseTimer = nil
        if let hotkey { UnregisterEventHotKey(hotkey) }; hotkey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }; tap = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }; source = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        // Also hide a panel whose physical release was queued before this registration change.
        release?()
    }
    deinit { unregister() }
}
