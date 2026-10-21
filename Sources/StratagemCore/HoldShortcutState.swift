import Foundation

/// Pure state machine for left Shift + Tab. No text, characters, or other key history is retained.
public struct HoldShortcutState {
    public enum Event: Equatable { case down(UInt16, repeatKey: Bool), up(UInt16), modifiersChanged }
    public enum Effect: Equatable { case began, ended, direction(Direction), confirm, cancel }
    public struct Decision: Equatable {
        public var consume: Bool
        public var effects: [Effect]
    }
    public private(set) var active = false
    private var consumedDowns: Set<UInt16> = []
    public init() {}
    public mutating func handle(_ event: Event, leftShift: Bool, otherModifiers: Bool = false) -> Decision {
        var effects: [Effect] = []
        if active && (!leftShift || otherModifiers) { active = false; effects.append(.ended) }
        switch event {
        case .down(let code, let repeatKey):
            if code == 48 {
                if !repeatKey && leftShift && !otherModifiers && !consumedDowns.contains(code) {
                    active = true; consumedDowns.insert(code); effects.append(.began)
                }
                return Decision(consume: consumedDowns.contains(code), effects: effects)
            }
            guard active else { return Decision(consume: consumedDowns.contains(code), effects: effects) }
            let directions: [UInt16: Direction] = [126: .up, 125: .down, 123: .left, 124: .right]
            let effect: Effect?
            if let direction = directions[code] { effect = .direction(direction) }
            else if code == 36 { effect = .confirm }
            else if code == 53 { effect = .cancel; active = false }
            else { effect = nil }
            guard let effect else { return Decision(consume: false, effects: effects) }
            consumedDowns.insert(code)
            if !repeatKey { effects.append(effect) }
            return Decision(consume: true, effects: effects)
        case .up(let code):
            if code == 48 && active { active = false; effects.append(.ended) }
            return Decision(consume: consumedDowns.remove(code) != nil, effects: effects)
        case .modifiersChanged:
            return Decision(consume: false, effects: effects)
        }
    }
    /// Hide on focus loss/Esc but swallow the matching key-ups for keys we already consumed.
    public mutating func cancelSession() { active = false }
    public mutating func reset() { active = false; consumedDowns.removeAll() }
}
