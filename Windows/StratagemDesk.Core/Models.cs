using System.Text.Json;
using System.Text.Json.Serialization;

namespace StratagemDesk.Core;

public enum Direction { Up, Down, Left, Right }
public enum ActionKind { Shell, Executable, Application, Open, Shortcut, Delay, Notification }

public sealed record ActionDefinition
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "新动作";
    public ActionKind Kind { get; set; } = ActionKind.Shell;
    public string Target { get; set; } = "";
    public string Shell { get; set; } = WindowsDefaults.PowerShell;
    public List<string> Arguments { get; set; } = [];
    public string WorkingDirectory { get; set; } = "";
    public Dictionary<string, string> Environment { get; set; } = [];
    public double Timeout { get; set; } = 30;
    public double Seconds { get; set; } = 1;
    public bool Approved { get; set; }
    public bool Sensitive { get; set; }
    [JsonIgnore] public string Preview => Sensitive ? "[敏感动作：参数与输出隐藏]" :
        $"{Kind}: {Target}\n参数: {string.Join(" · ", Arguments)}\n目录: {WorkingDirectory}\n环境变量: {string.Join(", ", Environment.Keys)}";
}
public sealed record WorkflowStep
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    [JsonPropertyName("actionID")] public string ActionId { get; set; } = "";
    public bool ContinueOnFailure { get; set; }
    public double DelayAfter { get; set; }
}
public sealed record Stratagem
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "自定义战备";
    public List<Direction> Sequence { get; set; } = [];
    public string Category { get; set; } = "自定义";
    public string Icon { get; set; } = "command.square";
    public string Description { get; set; } = "";
    public bool Enabled { get; set; }
    public bool Confirmation { get; set; } = true;
    public List<WorkflowStep> Steps { get; set; } = [];
    [JsonIgnore] public string SequenceText => string.Join(" ", Sequence.Select(Symbol));
    public static string Symbol(Direction d) => d switch { Direction.Up => "↑", Direction.Down => "↓", Direction.Left => "←", _ => "→" };
}
public sealed record AppSettings
{
    public string HotkeyPlatform { get; set; } = "windows";
    public uint HotkeyCode { get; set; } = 0x53;
    public uint HotkeyModifiers { get; set; } = 3; // Win32 Control + Alt
    public bool ExactLeftShift { get; set; }
    public double InputTimeout { get; set; } = 5;
    public double WorkflowTimeout { get; set; } = 120;
    public bool CloseAfterSuccess { get; set; } = true;
    public string PanelPosition { get; set; } = "topLeft";
}
public sealed record Configuration
{
    public int SchemaVersion { get; set; } = 1;
    public string Platform { get; set; } = "windows";
    public Dictionary<string, Stratagem> Overrides { get; set; } = [];
    public List<Stratagem> Custom { get; set; } = [];
    public List<ActionDefinition> Actions { get; set; } = [];
    public AppSettings Settings { get; set; } = new();
    public List<Stratagem> Resolve(IReadOnlyList<Stratagem> builtins)
    {
        var ids = builtins.Select(e => e.Id).ToHashSet();
        return [.. builtins.Select(e => Overrides.GetValueOrDefault(e.Id) ?? e),
            .. Overrides.Values.Where(e => !ids.Contains(e.Id)).OrderBy(e => e.Id), .. Custom];
    }
    public ActionDefinition? Action(string id) => Actions.FirstOrDefault(a => a.Id == id);
    public void Update(Stratagem entry)
    {
        var i = Custom.FindIndex(e => e.Id == entry.Id);
        if (i >= 0) Custom[i] = entry; else Overrides[entry.Id] = entry;
    }
    public int SetEnabled(IEnumerable<string> ids, bool enabled, IReadOnlyList<Stratagem> builtins)
    {
        var selected = ids.ToHashSet(); var count = 0;
        foreach (var entry in Resolve(builtins).Where(e => selected.Contains(e.Id) && e.Enabled != enabled))
        { var copy = Json.Clone(entry); copy.Enabled = enabled; Update(copy); count++; }
        return count;
    }
}
public static class Json
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false) }
    };
    public static T Clone<T>(T value) => JsonSerializer.Deserialize<T>(JsonSerializer.Serialize(value, Options), Options)!;
    public static bool Same<T>(T a, T b) => JsonSerializer.Serialize(a, Options) == JsonSerializer.Serialize(b, Options);
}
public static class WindowsDefaults
{
    public static string PowerShell => Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
}
public static class Catalog
{
    public static List<Stratagem> Load()
    {
        using var stream = typeof(Catalog).Assembly.GetManifestResourceStream("builtins.json")!;
        return JsonSerializer.Deserialize<List<Stratagem>>(stream, Json.Options)!;
    }
    public static Configuration Defaults(IReadOnlyList<Stratagem> builtins)
    {
        var c = new Configuration();
        void Bind(string id, ActionKind kind, string target, string name)
        {
            var e = Json.Clone(builtins.First(e => e.Id == id));
            var a = new ActionDefinition { Name = name, Kind = kind, Target = target };
            e.Steps = [new() { ActionId = a.Id }]; c.Actions.Add(a); c.Overrides[e.Id] = e;
        }
        Bind("desk.terminal", ActionKind.Application, Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.System), "cmd.exe"), "打开命令提示符");
        Bind("desk.workflow", ActionKind.Shell, "Write-Output 'StratagemDesk Public ready'", "安全 PowerShell 测试");
        Bind("desk.calculate", ActionKind.Application, Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.System), "calc.exe"), "打开计算器");
        Bind("desk.home", ActionKind.Open, System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile), "打开用户目录");
        Bind("desk.files", ActionKind.Application, Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.Windows), "explorer.exe"), "打开文件管理器");
        Bind("desk.clock", ActionKind.Shell, "Get-Date -Format o", "读取时间");
        Bind("desk.status", ActionKind.Notification, "StratagemDesk Public ready", "状态通知");
        Bind("desk.pause", ActionKind.Delay, "", "等待一秒");
        var custom = new Stratagem { Name = "Custom Stratagem", Sequence = [Direction.Up, Direction.Right, Direction.Up, Direction.Down, Direction.Left] };
        foreach (var a in new[] { new ActionDefinition { Target = "Write-Output 'Workflow step 1'" },
            new ActionDefinition { Kind = ActionKind.Delay, Name = "延迟" }, new ActionDefinition { Kind = ActionKind.Notification, Name = "通知", Target = "工作流完成" } })
        { c.Actions.Add(a); custom.Steps.Add(new() { ActionId = a.Id }); }
        c.Custom.Add(custom); return c;
    }
}
