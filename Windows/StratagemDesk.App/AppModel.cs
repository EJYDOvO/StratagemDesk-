using System.Text.Json;

namespace StratagemDesk.App;

public sealed class AppModel
{
    public List<Stratagem> Builtins { get; } = Catalog.Load();
    public Configuration Current { get; private set; }
    public Configuration Committed { get; private set; }
    private readonly Configuration defaults;
    public ConfigurationStore Store { get; }
    public WorkflowRunner Runner { get; } = new();
    public ActionRegistry Registry { get; } = new();
    public string Message { get; private set; } = "";
    public bool LoadFailed { get; private set; }
    public bool HasSaved { get; private set; }
    public string? Selection { get; set; }
    public string? HotkeyError { get; set; }
    public bool Dirty => !Json.Same(Current, Committed);
    public event Action? Changed;
    public event Action? Saved;
    public AppModel(string? configuration = null)
    {
        Store = new(PrivateStorage.Prepare(configuration), Builtins, PrivateStorage.CreateFile); defaults = Catalog.Defaults(Builtins);
        Current = Json.Clone(defaults);
        try { if (File.Exists(Store.FilePath)) { Current = Store.Load(); HasSaved = true; } }
        catch (Exception ex) { LoadFailed = true; Message = "配置加载失败，原文件已保留：" + ex.Message; }
        Committed = Json.Clone(Current);
        Runner.Changed += () => Changed?.Invoke();
    }
    public void Notify(string message) { Message = message; Changed?.Invoke(); }
    public List<Stratagem> Entries => Current.Resolve(Builtins);
    public StratagemProfile? CurrentProfile(string id) => Current.Profile(id, Builtins);
    public StratagemProfile? SavedProfile(string id) => HasSaved ? Committed.Profile(id, Builtins) : null;
    public StratagemProfile DefaultProfile(string id) => Builtins.Any(e => e.Id == id) ? defaults.Profile(id, Builtins)! : new(new() { Id = id }, []);
    public void SetDraft(StratagemProfile incoming)
    {
        var profile = new StratagemProfile(Json.Clone(incoming.Entry), Json.Clone(incoming.Actions));
        var previous = CurrentProfile(profile.Entry.Id);
        foreach (var a in profile.Actions)
        {
            var step = profile.Entry.Steps.FirstOrDefault(s => s.ActionId == a.Id);
            var oldStep = previous?.Entry.Steps.FirstOrDefault(s => s.Id == step?.Id);
            var old = previous?.Actions.FirstOrDefault(x => x.Id == oldStep?.ActionId);
            if (old == null) { a.Approved = false; continue; }
            var comparable = Json.Clone(old); comparable.Id = a.Id; comparable.Approved = a.Approved;
            if (!Json.Same(comparable, a)) a.Approved = false;
        }
        Current.Apply(profile, Builtins); Changed?.Invoke();
    }
    public bool SaveAll() => Persist(Json.Clone(Current), null);
    public bool SaveOne(string id)
    {
        if (CurrentProfile(id) is not { } profile) return false;
        var next = Json.Clone(Committed); next.Apply(profile, Builtins); return Persist(next, id);
    }
    private bool Persist(Configuration next, string? id)
    {
        if (LoadFailed) { Notify("请先备份并恢复损坏配置"); return false; }
        if (UI.HasInvalidInput) { Notify("请先修复界面中标红的无效参数"); return false; }
        try
        {
            Store.Save(next); Committed = next; HasSaved = true;
            if (id == null) Current = Json.Clone(next); else Current.Apply(next.Profile(id, Builtins)!, Builtins);
            Notify(id == null ? "已保存全部更改，终端已更新" : "已单独保存此战备，其他草稿保留"); Saved?.Invoke(); return true;
        }
        catch (Exception ex) { Notify("未保存：" + ex.Message); return false; }
    }
    public void Restore(string id, bool factory)
    {
        var profile = factory ? DefaultProfile(id) : SavedProfile(id);
        if (profile != null) { Current.Apply(profile, Builtins); Notify(factory ? "已恢复默认内容，请保存以生效" : "已撤销此战备的未保存更改"); }
    }
    public void SetEnabled(IEnumerable<string> ids, bool enabled)
    { var n = Current.SetEnabled(ids, enabled, Builtins); Notify($"已{(enabled ? "启用" : "停用")} {n} 项，请保存以生效"); }
    public void Add()
    { var entry = new Stratagem { Name = $"自定义战备 {Current.Custom.Count + 1}" }; Current.Custom.Add(entry); Selection = entry.Id; Notify("已新建战备"); }
    public void Duplicate(string id)
    {
        var profile = CurrentProfile(id)!; var e = Json.Clone(profile.Entry); e.Id = Guid.NewGuid().ToString(); e.Name += " 副本"; e.Enabled = false;
        var actions = new List<ActionDefinition>(); var map = new Dictionary<string, string>();
        foreach (var a in profile.Actions) { var copy = Json.Clone(a); copy.Id = Guid.NewGuid().ToString(); map[a.Id] = copy.Id; actions.Add(copy); }
        foreach (var s in e.Steps) { s.Id = Guid.NewGuid().ToString(); s.ActionId = map[s.ActionId]; }
        Current.Apply(new(e, actions), Builtins); Selection = e.Id; Notify("已创建独立副本");
    }
    public void Delete(string id)
    {
        if (Current.Custom.Any(e => e.Id == id)) { Current.Custom.RemoveAll(e => e.Id == id); Selection = null; }
        else if (CurrentProfile(id) is { } p) { p.Entry.Enabled = false; p.Entry.Steps.Clear(); Current.Apply(new(p.Entry, []), Builtins); }
        Notify("已删除自定义战备或清除内置映射，请保存");
    }
    public void Import(string path)
    {
        var next = ConfigurationStore.QuarantinedImport(File.ReadAllBytes(path), Committed.Settings, Builtins);
        Store.Backup(); Store.Save(next); Current = next; Committed = Json.Clone(next); HasSaved = true; LoadFailed = false; Selection = null;
        Notify("已导入并停用全部映射；macOS 动作需要重新绑定并审核"); Saved?.Invoke();
    }
    public void ResetDefaults()
    {
        Store.Backup(); var next = Json.Clone(defaults); Store.Save(next); Current = next; Committed = Json.Clone(next); HasSaved = true;
        LoadFailed = false; Selection = null; Notify("已备份并恢复默认，全部动作未审核"); Saved?.Invoke();
    }
    public string Preview(Stratagem e, Configuration c) => string.Join("\n\n", e.Steps.Select((s, i) =>
        c.Action(s.ActionId) is { } a ? $"{i + 1}. {(a.Sensitive ? "敏感动作" : a.Name)} [{a.Kind}]\n{a.Preview}\n失败后{(s.ContinueOnFailure ? "继续" : "停止")} · 延迟 {s.DelayAfter}s" : "缺失动作"));
    public Task<bool> TestStepAsync(string entryId, string stepId, bool preview = true)
    {
        // Copy-on-write can replace action IDs while an editor control remains alive.
        // Resolve by the stable step ID at click time, never execute the old shared action.
        var step = CurrentProfile(entryId)?.Entry.Steps.FirstOrDefault(s => s.Id == stepId);
        if (step == null) { Notify("此步骤已移除"); return Task.FromResult(false); }
        return RunAsync(new() { Name = "单步测试", Steps = [Json.Clone(step)] }, false, preview);
    }
    public async Task<bool> RunAsync(Stratagem e, bool committed, bool preview)
    {
        if (LoadFailed) { Notify("配置加载失败，执行已阻止"); return false; }
        if (Runner.RunningId != null) { Notify("已有工作流正在执行，请等待完成或取消"); return false; }
        if (!committed && UI.HasInvalidInput) { Notify("请先修复界面中标红的无效参数"); return false; }
        var c = Json.Clone(committed ? Committed : Current);
        try
        {
            ConfigurationStore.Validate(c, Builtins);
            if (e.Steps.Count == 0 || e.Steps.Any(s => c.Action(s.ActionId)?.Approved != true)) throw new InvalidOperationException("请配置并逐项审核全部动作");
            foreach (var step in e.Steps) if (ActionRegistry.UnsupportedReason(c.Action(step.ActionId)!) is { } reason) throw new NotSupportedException(reason);
            if (preview && MessageBox.Show(Preview(e, c), $"执行 {e.Name}？", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return false;
            var result = await Runner.RunAsync(e, c, Registry.ExecuteAsync);
            var logPath = Path.Combine(Path.GetDirectoryName(Store.FilePath)!, "last-run.json");
            PrivateStorage.WriteAtomic(logPath, JsonSerializer.SerializeToUtf8Bytes(result, Json.Options));
            Notify(result.Summary); return true;
        }
        catch (Exception ex) { Notify(ex.Message); return false; }
    }
}
