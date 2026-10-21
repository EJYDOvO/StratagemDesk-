import Foundation

/// One entry and the complete definitions of its referenced actions.
public struct StratagemProfile: Equatable, Sendable {
    public var entry: Stratagem
    public var actions: [ActionDefinition]
    public init(entry: Stratagem, actions: [ActionDefinition]) { self.entry = entry; self.actions = actions }
    public func equivalent(to other: StratagemProfile) -> Bool {
        func normalized(_ profile: StratagemProfile) -> (Stratagem, [ActionDefinition?]) {
            var entry = profile.entry
            let actions = entry.steps.map { step -> ActionDefinition? in
                guard var action = profile.actions.first(where: { $0.id == step.actionID }) else { return nil }
                action.id = ""; return action
            }
            for i in entry.steps.indices { entry.steps[i].id = ""; entry.steps[i].actionID = "" }
            return (entry, actions)
        }
        let lhs = normalized(self), rhs = normalized(other)
        return lhs.0 == rhs.0 && lhs.1 == rhs.1
    }
}

public extension Configuration {
    func profile(for id: String, builtins: [Stratagem]) -> StratagemProfile? {
        guard let entry = resolved(builtins: builtins).first(where: { $0.id == id }) else { return nil }
        var seen: Set<String> = []
        let actions = entry.steps.compactMap { step -> ActionDefinition? in
            guard seen.insert(step.actionID).inserted else { return nil }
            return action(step.actionID)
        }
        return StratagemProfile(entry: entry, actions: actions)
    }
    /// Merge one profile without changing entries or actions used by other profiles.
    mutating func apply(_ profile: StratagemProfile, builtins: [Stratagem]) {
        var entry = profile.entry
        let entries = resolved(builtins: builtins)
        let previousIDs = Set(entries.first(where: { $0.id == entry.id })?.steps.map(\.actionID) ?? [])
        let sharedIDs = Set(entries.filter { $0.id != entry.id }.flatMap { $0.steps.map(\.actionID) })
        var replacements: [String: String] = [:]
        for var action in profile.actions {
            let originalID = action.id
            if let index = actions.firstIndex(where: { $0.id == originalID }) {
                if actions[index] == action { continue }
                if sharedIDs.contains(originalID) {
                    action.id = UUID().uuidString; replacements[originalID] = action.id; actions.append(action)
                } else { actions[index] = action }
            } else { actions.append(action) }
        }
        for i in entry.steps.indices { entry.steps[i].actionID = replacements[entry.steps[i].actionID] ?? entry.steps[i].actionID }
        if let index = custom.firstIndex(where: { $0.id == entry.id }) { custom[index] = entry }
        else if builtins.contains(where: { $0.id == entry.id }) || overrides[entry.id] != nil { overrides[entry.id] = entry }
        else { custom.append(entry) }
        let usedIDs = Set(resolved(builtins: builtins).flatMap { $0.steps.map(\.actionID) })
        actions.removeAll { previousIDs.contains($0.id) && !usedIDs.contains($0.id) }
    }
}
