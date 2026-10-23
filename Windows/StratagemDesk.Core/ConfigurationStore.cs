using System.Text.Json;
using System.Diagnostics.CodeAnalysis;

namespace StratagemDesk.Core;

public sealed class ConfigurationStore(string path, IReadOnlyList<Stratagem> builtins, Func<string, FileStream>? createPrivateFile = null)
{
    public string FilePath { get; } = path;
    public Configuration Load() => Decode(File.ReadAllBytes(FilePath), builtins);
    public static Configuration Decode(byte[] bytes, IReadOnlyList<Stratagem> builtins, bool validateSettings = true)
    {
        if (bytes.Length > 10_000_000) throw new InvalidDataException("配置超过 10 MB 限制");
        var c = JsonSerializer.Deserialize<Configuration>(bytes, Json.Options) ?? throw new InvalidDataException("配置为空");
        Validate(c, builtins, validateSettings); return c;
    }
    public static void Validate(Configuration c, IReadOnlyList<Stratagem> builtins, bool validateSettings = true)
    {
        static void Require([DoesNotReturnIf(false)] bool ok, string error) { if (!ok) throw new InvalidDataException(error); }
        static bool Range(double n, double min, double max) => double.IsFinite(n) && n >= min && n <= max;
        Require(c.SchemaVersion == 1, "不支持的 schemaVersion");
        Require(c.Settings != null && c.Custom != null && c.Overrides != null && c.Actions != null, "配置字段缺失");
        var s = c.Settings!;
        if (validateSettings)
            Require(s.HotkeyPlatform == "windows" && s.HotkeyCode is >= 1 and <= 254 && s.HotkeyModifiers is > 0 and <= 15 &&
                !HotkeyRules.IsInputKey(s.HotkeyCode) &&
                (!s.ExactLeftShift || (s.HotkeyCode == 9 && s.HotkeyModifiers == 4)), "热键需使用 Windows 键码和修饰位");
        Require(Range(s.InputTimeout, .5, 60) && Range(s.WorkflowTimeout, 1, 86400) &&
            new[] { "topLeft", "top", "bottom", "center" }.Contains(s.PanelPosition), "设置数值无效");
        var entries = c.Resolve(builtins);
        Require(entries.Select(e => e.Id).Distinct().Count() == entries.Count && entries.All(e => !string.IsNullOrWhiteSpace(e.Id)), "战备 ID 冲突");
        Require(c.Actions!.Select(a => a.Id).Distinct().Count() == c.Actions.Count && c.Overrides!.All(p => p.Key == p.Value.Id), "动作或覆盖 ID 无效");
        foreach (var a in c.Actions)
        {
            Require(!string.IsNullOrWhiteSpace(a.Id) && a.Target != null && a.Shell != null && a.Arguments != null && a.Environment != null && a.WorkingDirectory != null, "动作字段缺失");
            Require(Range(a.Timeout, .1, 86400) && Range(a.Seconds, 0, 86400), "动作超时或延迟无效");
            Require(!new[] { a.Target!, a.Shell!, a.WorkingDirectory! }.Concat(a.Arguments!).Concat(a.Environment!.Keys).Concat(a.Environment.Values).Any(v => v == null || v.Contains('\0')), "动作参数含无效字符");
            Require(a.Environment.Keys.All(k => k.Length != 0 && !k.Contains('=')) && a.Environment.Keys.Distinct(StringComparer.OrdinalIgnoreCase).Count() == a.Environment.Count, "环境变量名称无效或重复");
        }
        foreach (var e in entries)
        {
            Require(!string.IsNullOrWhiteSpace(e.Name) && e.Icon != null && e.Category != null && e.Description != null &&
                !new[] { e.Name, e.Icon, e.Category, e.Description }.Any(value => value.Contains('\0')) &&
                e.Sequence != null && e.Sequence.Count <= 32 && e.Steps != null, "战备名称、图标、分类或说明字段无效");
            Require(e.Steps!.Select(step => step.Id).Distinct().Count() == e.Steps.Count &&
                e.Steps.All(step => !string.IsNullOrEmpty(step.Id) && c.Action(step.ActionId) != null && Range(step.DelayAfter, 0, 86400)), "工作流引用或延迟无效");
        }
    }
    public void Save(Configuration c)
    {
        Validate(c, builtins);
        var conflict = SequenceMatcher.Conflicts(c.Resolve(builtins)).FirstOrDefault();
        if (conflict != null) throw new InvalidDataException(conflict);
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        var temp = FilePath + "." + Guid.NewGuid() + ".tmp";
        try
        {
            using (var stream = OpenNew(temp))
            { JsonSerializer.Serialize(stream, c, Json.Options); stream.Flush(flushToDisk: true); }
            File.Move(temp, FilePath, overwrite: true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    private FileStream OpenNew(string path) => createPrivateFile?.Invoke(path) ?? new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
    public void Backup()
    {
        if (!File.Exists(FilePath)) return;
        using var source = File.OpenRead(FilePath);
        using var destination = OpenNew(FilePath + ".backup-" + Guid.NewGuid());
        source.CopyTo(destination); destination.Flush(flushToDisk: true);
    }
    public static Configuration QuarantinedImport(byte[] bytes, AppSettings settings, IReadOnlyList<Stratagem> builtins)
    {
        var c = Decode(bytes, builtins, validateSettings: false); c.Settings = Json.Clone(settings); c.Platform = "windows";
        foreach (var e in c.Overrides.Values.Concat(c.Custom))
        {
            e.Enabled = false; e.Confirmation = true;
            // Importing a workflow is not consent to read an arbitrary local or network image.
            if (e.Icon.IndexOfAny(['/', '\\', ':']) >= 0)
                e.Icon = builtins.FirstOrDefault(b => b.Id == e.Id)?.Icon ?? "command.square";
        }
        foreach (var a in c.Actions) a.Approved = false;
        Validate(c, builtins); return c;
    }
    public static byte[] Export(Configuration c)
    {
        var copy = Json.Clone(c);
        foreach (var a in copy.Actions.Where(a => a.Sensitive))
        { a.Target = ""; a.Arguments = []; a.Environment = []; a.WorkingDirectory = ""; a.Shell = WindowsDefaults.PowerShell; a.Approved = false; }
        return JsonSerializer.SerializeToUtf8Bytes(copy, Json.Options);
    }
}
