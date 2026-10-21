using System.Globalization;
using System.Windows.Input;
using Microsoft.Win32;

namespace StratagemDesk.App;

internal static class UI
{
    private static readonly DependencyProperty InputError = DependencyProperty.RegisterAttached("InputError", typeof(string), typeof(UI));
    private static readonly List<WeakReference<TextBox>> inputs = [];
    public static bool HasInvalidInput => inputs.Any(r => r.TryGetTarget(out var box) && box.IsLoaded && box.GetValue(InputError) != null);
    public static void MarkError(TextBox box, string? error)
    { box.SetValue(InputError, error); box.ToolTip = error; box.ClearValue(Control.BorderBrushProperty); if (error != null) box.BorderBrush = Brushes.IndianRed; }
    public static TextBlock Text(string value, double size = 13) => new() { Text = value, FontSize = size, TextWrapping = TextWrapping.Wrap, Margin = new(0, 3, 0, 4) };
    public static Button Button(string text, Action action)
    {
        var b = new Button { Content = text };
        b.Click += (_, _) => { try { action(); } catch (Exception ex) { MessageBox.Show(ex.Message, "操作未完成", MessageBoxButton.OK, MessageBoxImage.Warning); } }; return b;
    }
    public static TextBox Input(string value, Action<string> changed, bool multiline = false)
    {
        var box = new TextBox { Text = value, AcceptsReturn = multiline, MinHeight = multiline ? 65 : 26,
            TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        inputs.RemoveAll(r => !r.TryGetTarget(out _)); inputs.Add(new(box));
        box.TextChanged += (_, _) => changed(box.Text); return box;
    }
    public static CheckBox Check(string text, bool value, Action<bool> changed)
    {
        var box = new CheckBox { Content = text, IsChecked = value }; box.Click += (_, _) => changed(box.IsChecked == true); return box;
    }
    public static GroupBox Group(string title, UIElement content) => new() { Header = title, Content = content };
    public static void Field(Panel panel, string label, string value, Action<string> changed, bool multiline = false)
    { panel.Children.Add(Text(label, 12)); panel.Children.Add(Input(value, changed, multiline)); }
    public static void Number(Panel panel, string label, double value, Action<double> changed)
    {
        panel.Children.Add(Text(label, 12)); TextBox? box = null;
        box = Input(value.ToString(CultureInfo.InvariantCulture), text =>
        {
            if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var n) && double.IsFinite(n)) { MarkError(box!, null); changed(n); }
            else MarkError(box!, "请输入有限数值，当前输入未应用");
        }); panel.Children.Add(box);
    }
}

public sealed class MainWindow : Window
{
    private readonly AppModel model;
    private readonly GameArtwork artwork;
    private readonly TextBox search = new();
    private readonly ComboBox category = new();
    private readonly ListBox list = new();
    private readonly StackPanel editor = new() { Margin = new(18) };
    private readonly StackPanel profiles = new();
    private readonly TextBlock message = UI.Text("");
    private readonly TextBox log = new() { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 220, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    private readonly HashSet<string> selected = [];
    private readonly Dictionary<string, CheckBox> checks = [];
    private readonly Dictionary<string, TextBlock> names = [];
    private bool refreshing;
    private string[] visible = [];
    public bool AllowClose { get; set; }
    public event Action? ShowHud;
    public MainWindow(AppModel model, GameArtwork artwork)
    {
        this.model = model; this.artwork = artwork;
        Title = "StratagemDesk Public — Windows 战备管理器"; Width = 1180; Height = 850; MinWidth = 1000; MinHeight = 700;
        var root = new DockPanel(); Content = root;
        var header = new WrapPanel { Margin = new(12) }; DockPanel.SetDock(header, Dock.Top); root.Children.Add(header);
        header.Children.Add(UI.Text("STRATAGEM DESK", 21));
        header.Children.Add(UI.Button("打开终端预览", () => ShowHud?.Invoke()));
        header.Children.Add(UI.Button("保存全部", () => model.SaveAll()));
        header.Children.Add(UI.Button("全局设置", () => { new SettingsWindow(model) { Owner = this }.ShowDialog(); RefreshList(); RefreshEditor(); }));
        header.Children.Add(UI.Button("导入 JSON", Import)); header.Children.Add(UI.Button("导出 JSON", Export));
        header.Children.Add(UI.Button("取消工作流", model.Runner.Cancel));
        var footer = new Border { Child = message, Padding = new(12), Background = Brushes.WhiteSmoke };
        DockPanel.SetDock(footer, Dock.Bottom); root.Children.Add(footer);
        var grid = new Grid(); grid.ColumnDefinitions.Add(new() { Width = new(300) }); grid.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); root.Children.Add(grid);
        var sidebar = new DockPanel { Margin = new(10) }; grid.Children.Add(sidebar);
        var filters = new StackPanel(); DockPanel.SetDock(filters, Dock.Top); sidebar.Children.Add(filters);
        search.Margin = new(3); search.ToolTip = "搜索战备"; search.TextChanged += (_, _) => RefreshList(); filters.Children.Add(search);
        category.Items.Add("全部"); foreach (var c in model.Entries.Select(e => e.Category).Distinct().Order()) category.Items.Add(c);
        category.SelectedIndex = 0; category.Margin = new(3); category.SelectionChanged += (_, _) => RefreshList(); filters.Children.Add(category);
        var batch = new WrapPanel(); batch.Children.Add(UI.Button("全选当前列表", () => { selected.UnionWith(visible); RefreshChecks(); }));
        batch.Children.Add(UI.Button("清空选择", () => { selected.Clear(); RefreshChecks(); })); filters.Children.Add(batch);
        var operations = new WrapPanel();
        operations.Children.Add(UI.Button("启用所选", () => { model.SetEnabled(selected, true); RefreshList(); RefreshEditor(); }));
        operations.Children.Add(UI.Button("停用所选", () => { model.SetEnabled(selected, false); RefreshList(); RefreshEditor(); })); filters.Children.Add(operations);
        var newRow = new WrapPanel(); DockPanel.SetDock(newRow, Dock.Bottom); sidebar.Children.Add(newRow);
        newRow.Children.Add(UI.Button("新建战备", () => { model.Add(); RefreshList(); RefreshEditor(); }));
        list.SelectionChanged += (_, _) => { if (!refreshing && list.SelectedItem is ListBoxItem item) { model.Selection = (string)item.Tag; RefreshEditor(); } };
        sidebar.Children.Add(list);
        var scroll = new ScrollViewer { Content = editor, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }; Grid.SetColumn(scroll, 1); grid.Children.Add(scroll);
        model.Changed += () => Dispatcher.BeginInvoke(RefreshState);
        Closing += (_, e) => { if (!AllowClose) { e.Cancel = true; Hide(); } };
        PreviewKeyDown += (_, e) => { if (e.Key == Key.S && Keyboard.Modifiers == ModifierKeys.Control) { model.SaveAll(); e.Handled = true; } };
        RefreshList(); RefreshEditor(); RefreshState();
    }
    private void RefreshChecks() { refreshing = true; foreach (var (id, check) in checks) check.IsChecked = selected.Contains(id); refreshing = false; RefreshState(); }
    private void RefreshList()
    {
        if (refreshing) return; refreshing = true;
        try
        {
            var priorCategory = category.SelectedItem as string ?? "全部";
            var categories = new[] { "全部" }.Concat(model.Entries.Select(e => e.Category).Distinct().Order()).ToArray();
            if (!category.Items.Cast<string>().SequenceEqual(categories))
            {
                category.Items.Clear(); foreach (var name in categories) category.Items.Add(name);
                category.SelectedItem = categories.Contains(priorCategory) ? priorCategory : "全部";
            }
            var text = search.Text; var filter = category.SelectedItem as string ?? "全部";
            var entries = model.Entries.Where(e => (filter == "全部" || filter == e.Category) && e.Name.Contains(text, StringComparison.OrdinalIgnoreCase)).ToList();
            visible = entries.Select(e => e.Id).ToArray(); selected.IntersectWith(visible);
            list.Items.Clear(); checks.Clear(); names.Clear();
            foreach (var e in entries)
            {
                var row = new DockPanel { Margin = new(2, 7, 2, 7) };
                var check = UI.Check("", selected.Contains(e.Id), value => { if (refreshing) return; if (value) selected.Add(e.Id); else selected.Remove(e.Id); RefreshState(); });
                check.ToolTip = "批量选择 " + e.Name; checks[e.Id] = check; row.Children.Add(check);
                row.Children.Add(new Image { Source = artwork.Image(e), Width = 30, Height = 30, Margin = new(4, 0, 8, 0) });
                var name = UI.Text($"{(e.Enabled ? "● " : "")}{e.Name}\n{e.SequenceText}"); names[e.Id] = name; row.Children.Add(name);
                var item = new ListBoxItem { Content = row, Tag = e.Id, HorizontalContentAlignment = HorizontalAlignment.Stretch };
                list.Items.Add(item); if (model.Selection == e.Id) list.SelectedItem = item;
            }
        }
        finally { refreshing = false; }
        RefreshState();
    }
    private void RefreshState()
    {
        message.Text = $"{model.HotkeyError ?? "热键已就绪"} · 已选 {selected.Count} 项 · {(model.Dirty ? "有未保存更改" : "已保存")}\n{model.Message}";
        foreach (var e in model.Entries) if (names.TryGetValue(e.Id, out var block)) block.Text = $"{(e.Enabled ? "● " : "")}{e.Name}\n{e.SequenceText}";
        if (model.Selection != null) RefreshProfiles(model.Selection);
        var r = model.Runner.Latest; log.Text = r.Summary + "\n" + string.Join("\n\n", r.Logs.Select(l => $"{l.Name} · {l.Status}\n{l.Detail}"));
    }
    public void RefreshEditor()
    {
        if (log.Parent is ContentControl oldOwner) oldOwner.Content = null;
        editor.Children.Clear(); profiles.Children.Clear();
        if (model.Selection is not { } id || model.CurrentProfile(id) is not { } profile)
        { editor.Children.Add(UI.Text("选择或新建战备", 22)); editor.Children.Add(UI.Text("按住 Ctrl+Alt+S 呼出，输入方向序列，松开收起。")); return; }
        var e = profile.Entry; var header = new WrapPanel(); header.Children.Add(UI.Text(e.Name, 22));
        header.Children.Add(UI.Button("复制", () => { model.Duplicate(id); RefreshList(); RefreshEditor(); }));
        header.Children.Add(UI.Button("删除", () => { model.Delete(id); RefreshList(); RefreshEditor(); })); editor.Children.Add(header);
        editor.Children.Add(profiles); RefreshProfiles(id);
        var fields = new StackPanel(); editor.Children.Add(UI.Group("战备配置", fields));
        void Draft() => model.SetDraft(profile);
        UI.Field(fields, "名称", e.Name, v => { e.Name = v; Draft(); });
        UI.Field(fields, "分类", e.Category, v => { e.Category = v; Draft(); RefreshList(); });
        UI.Field(fields, "说明", e.Description, v => { e.Description = v; Draft(); });
        UI.Field(fields, "图标：本地 PNG/JPEG/SVG 路径（内置图标保留原值）", e.Icon, v => { e.Icon = v; Draft(); });
        fields.Children.Add(UI.Button("选择图片", () => { var file = new OpenFileDialog { Filter = "图片|*.png;*.jpg;*.jpeg;*.svg;*.bmp" }; if (file.ShowDialog() == true) { e.Icon = file.FileName; Draft(); RefreshEditor(); } }));
        var sequence = UI.Text(e.SequenceText.Length == 0 ? "未设置序列" : e.SequenceText, 22); fields.Children.Add(sequence);
        var directions = new WrapPanel();
        foreach (var d in Enum.GetValues<Direction>()) directions.Children.Add(UI.Button(Stratagem.Symbol(d), () => { if (e.Sequence.Count < 32) e.Sequence.Add(d); sequence.Text = e.SequenceText; Draft(); }));
        directions.Children.Add(UI.Button("退格", () => { if (e.Sequence.Count > 0) e.Sequence.RemoveAt(e.Sequence.Count - 1); sequence.Text = e.SequenceText; Draft(); }));
        directions.Children.Add(UI.Button("清空", () => { e.Sequence.Clear(); sequence.Text = "未设置序列"; Draft(); })); fields.Children.Add(directions);
        fields.Children.Add(UI.Check("启用战备", e.Enabled, value => { e.Enabled = value; Draft(); }));
        fields.Children.Add(UI.Check("执行前确认", e.Confirmation, value => { e.Confirmation = value; Draft(); }));
        editor.Children.Add(UI.Text("顺序工作流", 20)); editor.Children.Add(UI.Text("操作仅影响此战备；修改内容后会撤销审核。PowerShell 脚本用 $args 接收结构化参数。"));
        var addRow = new WrapPanel(); var kinds = new ComboBox { ItemsSource = Enum.GetValues<ActionKind>(), SelectedIndex = 0, Width = 130, Margin = new(3) };
        addRow.Children.Add(kinds); addRow.Children.Add(UI.Button("添加步骤", () =>
        {
            var a = new ActionDefinition { Kind = (ActionKind)kinds.SelectedItem, Name = kinds.SelectedItem.ToString()!, Target = kinds.SelectedItem is ActionKind.Shell ? "Write-Output 'Hello from StratagemDesk'" : "" };
            profile.Actions.Add(a); profile.Entry.Steps.Add(new() { ActionId = a.Id }); Draft(); RefreshEditor();
        }));
        var reuse = new ComboBox { Width = 190, Margin = new(3), ItemsSource = model.Current.Actions, DisplayMemberPath = "Name" }; addRow.Children.Add(reuse);
        addRow.Children.Add(UI.Button("复制已有动作", () =>
        {
            if (reuse.SelectedItem is not ActionDefinition source) return;
            var copy = Json.Clone(source); copy.Id = Guid.NewGuid().ToString(); copy.Approved = false; profile.Actions.Add(copy);
            e.Steps.Add(new() { ActionId = copy.Id }); Draft(); RefreshEditor();
        })); editor.Children.Add(addRow);
        for (var i = 0; i < e.Steps.Count; i++)
        {
            var index = i; var step = e.Steps[i]; var a = profile.Actions.FirstOrDefault(a => a.Id == step.ActionId);
            if (a == null) { editor.Children.Add(UI.Text("缺失动作")); continue; }
            var box = new StackPanel(); var controls = new WrapPanel(); box.Children.Add(controls);
            controls.Children.Add(UI.Button("↑", () => { if (index > 0) (e.Steps[index - 1], e.Steps[index]) = (e.Steps[index], e.Steps[index - 1]); Draft(); RefreshEditor(); }));
            controls.Children.Add(UI.Button("↓", () => { if (index + 1 < e.Steps.Count) (e.Steps[index + 1], e.Steps[index]) = (e.Steps[index], e.Steps[index + 1]); Draft(); RefreshEditor(); }));
            controls.Children.Add(UI.Button("移除", () => { e.Steps.RemoveAt(index); Draft(); RefreshEditor(); }));
            controls.Children.Add(UI.Button("测试此步", async () => await model.TestStepAsync(id, step.Id)));
            CheckBox? approvedBox = null; var environmentValid = true;
            void ActionChanged() { a.Approved = false; if (approvedBox != null) approvedBox.IsChecked = false; Draft(); }
            UI.Field(box, "动作名称", a.Name, v => { a.Name = v; ActionChanged(); });
            UI.Field(box, a.Kind == ActionKind.Delay ? "说明（延迟秒数见下）" : "目标 / PowerShell 脚本", a.Target, v => { a.Target = v; ActionChanged(); }, a.Kind == ActionKind.Shell);
            if (a.Kind == ActionKind.Shell) UI.Field(box, "PowerShell 绝对路径", a.Shell, v => { a.Shell = v; ActionChanged(); });
            if (a.Kind is ActionKind.Shell or ActionKind.Executable or ActionKind.Application)
                UI.Field(box, "参数：每行一个，保留空参数和行内空格", string.Join("\n", a.Arguments), v => { a.Arguments = v.Length == 0 ? [] : v.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n').ToList(); ActionChanged(); }, true);
            if (a.Kind is ActionKind.Shell or ActionKind.Executable)
            {
                UI.Field(box, "工作目录（留空为用户目录）", a.WorkingDirectory, v => { a.WorkingDirectory = v; ActionChanged(); });
                box.Children.Add(UI.Text("环境变量（JSON 字符串对象）", 12)); TextBox? environmentBox = null;
                environmentBox = UI.Input(System.Text.Json.JsonSerializer.Serialize(a.Environment), v =>
                {
                    try { a.Environment = System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, string>>(v) ?? []; UI.MarkError(environmentBox!, null); environmentValid = true; if (approvedBox != null) approvedBox.IsEnabled = true; ActionChanged(); }
                    catch (System.Text.Json.JsonException) { UI.MarkError(environmentBox!, "环境变量 JSON 无效"); environmentValid = false; if (approvedBox != null) approvedBox.IsEnabled = false; ActionChanged(); model.Notify("环境变量 JSON 无效，当前内容未应用，动作已撤销审核"); }
                }, true); box.Children.Add(environmentBox);
            }
            if (a.Kind == ActionKind.Delay) UI.Number(box, "延迟秒数", a.Seconds, v => { a.Seconds = v; ActionChanged(); });
            UI.Number(box, "动作超时（秒）", a.Timeout, v => { a.Timeout = v; ActionChanged(); });
            box.Children.Add(UI.Check("敏感：隐藏输出及导出参数", a.Sensitive, v => { a.Sensitive = v; ActionChanged(); }));
            approvedBox = UI.Check("我已审核此动作，允许执行", a.Approved, v => { a.Approved = v && environmentValid; Draft(); }); box.Children.Add(approvedBox);
            box.Children.Add(UI.Check("失败后继续", step.ContinueOnFailure, v => { step.ContinueOnFailure = v; Draft(); }));
            UI.Number(box, "步骤后延迟（秒）", step.DelayAfter, v => { step.DelayAfter = v; Draft(); });
            if (ActionRegistry.UnsupportedReason(a) is { } reason) { var warning = UI.Text(reason); warning.Foreground = Brushes.DarkOrange; box.Children.Add(warning); }
            editor.Children.Add(UI.Group($"{index + 1}. {a.Kind}", box));
        }
        editor.Children.Add(UI.Button("预览并测试工作流", async () => await model.RunAsync(model.CurrentProfile(id)!.Entry, false, true)));
        editor.Children.Add(UI.Group("执行结果", log)); RefreshState();
    }
    private void RefreshProfiles(string id)
    {
        profiles.Children.Clear(); var grid = new UniformGrid { Columns = 3 };
        var current = model.CurrentProfile(id); var saved = model.SavedProfile(id);
        var original = model.DefaultProfile(id);
        var unchanged = saved != null && current != null && saved.Equivalent(current);
        void Card(string title, StratagemProfile? p, string note, string button, Action action, bool enabled)
        {
            var contents = new StackPanel { Margin = new(6) };
            contents.Children.Add(UI.Text(p?.Entry.Name ?? "尚无保存档案", 14));
            if (p != null)
            {
                contents.Children.Add(UI.Text(p.Entry.SequenceText));
                contents.Children.Add(UI.Text($"{(p.Entry.Enabled ? "已启用" : "已停用")} · {p.Entry.Steps.Count} 个步骤"));
                contents.Children.Add(new Expander { Header = "配置与操作", Content = UI.Text($"分类：{p.Entry.Category}\n{p.Entry.Description}\n图标：{p.Entry.Icon}\n{(p.Entry.Confirmation ? "执行前确认" : "直接执行")}\n\n" + model.Preview(p.Entry, new Configuration { Actions = p.Actions })) });
            }
            contents.Children.Add(UI.Text(note, 11)); var b = UI.Button(button, () => { action(); RefreshList(); RefreshEditor(); }); b.IsEnabled = enabled; contents.Children.Add(b);
            grid.Children.Add(UI.Group(title, contents));
        }
        Card("默认", original, model.Builtins.Any(e => e.Id == id) ? "出厂配置" : "自定义空白模板", "恢复默认", () => model.Restore(id, true), current?.Equivalent(original) != true);
        Card("当前", current, unchanged ? "与已保存一致" : "未保存的内容", "保存此战备", () => model.SaveOne(id), !unchanged && !model.LoadFailed);
        Card("已保存", saved, "终端使用此状态", "撤销此战备更改", () => model.Restore(id, false), saved != null && !unchanged);
        profiles.Children.Add(UI.Group("独立状态档案", grid));
    }
    private void Import()
    {
        var p = new OpenFileDialog { Filter = "JSON|*.json" }; if (p.ShowDialog() != true) return;
        if (MessageBox.Show("当前配置将备份并替换；所有映射停用，动作撤销审核。继续？", "导入", MessageBoxButton.OKCancel) != MessageBoxResult.OK) return;
        model.Import(p.FileName); RefreshList(); RefreshEditor();
    }
    private void Export()
    {
        var p = new SaveFileDialog { Filter = "JSON|*.json", FileName = "StratagemDesk-windows.json" };
        if (p.ShowDialog() == true) { File.WriteAllBytes(p.FileName, ConfigurationStore.Export(model.Current)); model.Notify("已导出，敏感参数已清空"); }
    }
}
