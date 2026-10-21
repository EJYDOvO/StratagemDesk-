namespace StratagemDesk.Core;

public sealed record StratagemProfile(Stratagem Entry, List<ActionDefinition> Actions)
{
    public bool Equivalent(StratagemProfile other)
    {
        static object Normalize(StratagemProfile p)
        {
            var e = Json.Clone(p.Entry);
            var actions = e.Steps.Select(s => p.Actions.FirstOrDefault(a => a.Id == s.ActionId)).Select(a =>
            { if (a == null) return null; var copy = Json.Clone(a); copy.Id = ""; return copy; }).ToList();
            foreach (var s in e.Steps) { s.Id = ""; s.ActionId = ""; }
            return new { Entry = e, Actions = actions };
        }
        return Json.Same(Normalize(this), Normalize(other));
    }
}
public static class Profiles
{
    public static StratagemProfile? Profile(this Configuration c, string id, IReadOnlyList<Stratagem> builtins)
    {
        var e = c.Resolve(builtins).FirstOrDefault(e => e.Id == id);
        if (e == null) return null;
        return new(Json.Clone(e), e.Steps.Select(s => s.ActionId).Distinct().Select(c.Action).Where(a => a != null).Select(a => Json.Clone(a!)).ToList());
    }
    public static void Apply(this Configuration c, StratagemProfile profile, IReadOnlyList<Stratagem> builtins)
    {
        var entry = Json.Clone(profile.Entry); var entries = c.Resolve(builtins);
        var previous = entries.FirstOrDefault(e => e.Id == entry.Id)?.Steps.Select(s => s.ActionId).ToHashSet() ?? [];
        var shared = entries.Where(e => e.Id != entry.Id).SelectMany(e => e.Steps).Select(s => s.ActionId).ToHashSet();
        var replacements = new Dictionary<string, string>();
        foreach (var source in profile.Actions)
        {
            var a = Json.Clone(source); var old = c.Action(a.Id);
            if (old != null && Json.Same(old, a)) continue;
            if (old != null && shared.Contains(a.Id)) { var id = a.Id; a.Id = Guid.NewGuid().ToString(); replacements[id] = a.Id; }
            else if (old != null) c.Actions.Remove(old);
            c.Actions.Add(a);
        }
        foreach (var s in entry.Steps) s.ActionId = replacements.GetValueOrDefault(s.ActionId) ?? s.ActionId;
        if (c.Custom.Any(e => e.Id == entry.Id)) c.Update(entry);
        else if (builtins.Any(e => e.Id == entry.Id) || c.Overrides.ContainsKey(entry.Id)) c.Overrides[entry.Id] = entry;
        else c.Custom.Add(entry);
        var used = c.Resolve(builtins).SelectMany(e => e.Steps).Select(s => s.ActionId).ToHashSet();
        c.Actions.RemoveAll(a => previous.Contains(a.Id) && !used.Contains(a.Id));
    }
}
public enum MatchKind { Waiting, Matched, Invalid, Ambiguous }
public sealed record MatchResult(MatchKind Kind, List<string> Ids);
public static class SequenceMatcher
{
    public static bool StartsWith(IReadOnlyList<Direction> sequence, IReadOnlyList<Direction> input) => sequence.Count >= input.Count && sequence.Take(input.Count).SequenceEqual(input);
    public static MatchResult Match(IReadOnlyList<Direction> input, IEnumerable<Stratagem> entries)
    {
        var candidates = entries.Where(e => e.Enabled && e.Sequence.Count > 0 && StartsWith(e.Sequence, input)).ToList();
        var exact = candidates.Where(e => e.Sequence.SequenceEqual(input)).ToList();
        if (exact.Count != 0) return exact.Count == 1 && candidates.Count == 1 ? new(MatchKind.Matched, [exact[0].Id]) : new(MatchKind.Ambiguous, []);
        return candidates.Count == 0 ? new(MatchKind.Invalid, []) : new(MatchKind.Waiting, candidates.Select(e => e.Id).ToList());
    }
    public static List<string> Conflicts(IEnumerable<Stratagem> entries)
    {
        var active = entries.Where(e => e.Enabled).ToList(); var errors = new List<string>();
        for (var i = 0; i < active.Count; i++)
        {
            var e = active[i]; if (e.Sequence.Count == 0) errors.Add($"{e.Name}：方向序列不能为空");
            foreach (var other in active.Skip(i + 1))
                if (StartsWith(e.Sequence, other.Sequence) || StartsWith(other.Sequence, e.Sequence)) errors.Add($"{e.Name} ↔ {other.Name}：序列重复或前缀冲突");
        }
        return errors;
    }
}
