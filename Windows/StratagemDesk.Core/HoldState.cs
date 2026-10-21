namespace StratagemDesk.Core;

public static class HotkeyRules
{
    public static bool IsInputKey(uint key) => key is 0x25 or 0x26 or 0x27 or 0x28 or 0x0D or 0x1B;
}

public enum HoldEffect { Began, Ended, Up, Down, Left, Right, Confirm, Cancel }
public sealed record KeyDecision(bool Consume, List<HoldEffect> Effects);

/// Only current control-key states are kept; no ordinary text is recorded.
public sealed class HoldState(AppSettings settings)
{
    private readonly HashSet<uint> down = [];
    private readonly HashSet<uint> consumed = [];
    private bool suppressed;
    public bool Active { get; private set; }
    public void Cancel() { Active = false; suppressed = down.Contains(settings.HotkeyCode); }
    public void Reset() { Active = false; suppressed = false; down.Clear(); consumed.Clear(); }
    private uint Modifiers => (Has(0x12, 0xA4, 0xA5) ? 1u : 0) | (Has(0x11, 0xA2, 0xA3) ? 2u : 0) |
        (Has(0x10, 0xA0, 0xA1) ? 4u : 0) | (Has(0x5B, 0x5C) ? 8u : 0);
    private bool Has(params uint[] keys) => keys.Any(down.Contains);
    public void Seed(uint key) => down.Add(key);
    public KeyDecision Handle(uint key, bool isDown)
    {
        var effects = new List<HoldEffect>();
        var relevant = key == settings.HotkeyCode || key is 0x10 or 0x11 or 0x12 or >= 0xA0 and <= 0xA5 or 0x5B or 0x5C or 0x25 or 0x26 or 0x27 or 0x28 or 0x0D or 0x1B;
        if (!relevant) return new(false, effects);
        var repeat = isDown && down.Contains(key);
        if (isDown) down.Add(key); else down.Remove(key);
        if (Active && (!down.Contains(settings.HotkeyCode) || (Modifiers & settings.HotkeyModifiers) != settings.HotkeyModifiers ||
            (settings.ExactLeftShift && (!down.Contains(0xA0) || Modifiers != 4))))
        { Active = false; effects.Add(HoldEffect.Ended); suppressed = down.Contains(settings.HotkeyCode); }
        if (!isDown)
        {
            if (key == settings.HotkeyCode) suppressed = false;
            return new(consumed.Remove(key), effects);
        }
        if (key == settings.HotkeyCode && !repeat && !suppressed && !consumed.Contains(key) &&
            Modifiers == settings.HotkeyModifiers && (!settings.ExactLeftShift || down.Contains(0xA0)))
        { Active = true; consumed.Add(key); effects.Add(HoldEffect.Began); return new(true, effects); }
        if (!Active) return new(consumed.Contains(key), effects);
        HoldEffect? effect = key switch { 0x26 => HoldEffect.Up, 0x28 => HoldEffect.Down, 0x25 => HoldEffect.Left, 0x27 => HoldEffect.Right, 0x0D => HoldEffect.Confirm, 0x1B => HoldEffect.Cancel, _ => null };
        if (effect == null) return new(consumed.Contains(key), effects);
        consumed.Add(key);
        if (!repeat) { effects.Add(effect.Value); if (effect == HoldEffect.Cancel) Cancel(); }
        return new(true, effects);
    }
}
