import Foundation

public enum MatchResult: Equatable {
    case waiting([String]), matched(String), invalid, ambiguous
}
public enum SequenceMatcher {
    public static func match(_ input: [Direction], in entries: [Stratagem]) -> MatchResult {
        let candidates = entries.filter { $0.enabled && !$0.sequence.isEmpty && $0.sequence.starts(with: input) }
        let exact = candidates.filter { $0.sequence == input }
        if !exact.isEmpty {
            return exact.count == 1 && candidates.count == 1 ? .matched(exact[0].id) : .ambiguous
        }
        return candidates.isEmpty ? .invalid : .waiting(candidates.map(\.id))
    }
    public static func conflicts(in entries: [Stratagem]) -> [String] {
        let active = entries.filter(\.enabled)
        var errors: [String] = []
        for (index, entry) in active.enumerated() {
            if entry.sequence.isEmpty { errors.append("\(entry.name)：方向序列不能为空") }
            for other in active.dropFirst(index + 1) where entry.sequence.starts(with: other.sequence) || other.sequence.starts(with: entry.sequence) {
                errors.append("\(entry.name) ↔ \(other.name)：序列重复或存在前缀冲突")
            }
        }
        return errors
    }
}
