using System.Windows.Input;

namespace StratagemDesk.App;

public sealed class SettingsWindow : Window
{
    private readonly AppModel model;
    private readonly TextBlock label;
    private bool recording;
    public SettingsWindow(AppModel model)
    {
        this.model = model; Title = "全局设置"; Width = 650; Height = 700; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var panel = new StackPanel { Margin = new(18) }; Content = new ScrollViewer { Content = panel };
        var s = model.Current.Settings;
        panel.Children.Add(UI.Text("输入与执行", 21)); label = UI.Text(Label(s), 18); panel.Children.Add(label);
        panel.Children.Add(UI.Button("录制快捷键（Esc 取消）", () => { recording = true; label.Text = "按下组合键…"; ((DesktopApp)Application.Current).PauseHotkey(); }));
        panel.Children.Add(UI.Text("默认 Ctrl+Alt+S。按住显示，方向键输入，松开收起。左 Shift+Tab 可录制为精确左 Shift 模式；Windows 保留组合键可能无法注册。"));
        UI.Number(panel, "输入超时（0.5–60 秒）", s.InputTimeout, v => s.InputTimeout = v);
        UI.Number(panel, "工作流超时（1–86400 秒）", s.WorkflowTimeout, v => s.WorkflowTimeout = v);
        panel.Children.Add(UI.Text("悬浮窗口位置"));
        var position = new ComboBox { ItemsSource = new[] { "topLeft", "center", "top", "bottom" }, SelectedItem = s.PanelPosition, Margin = new(3) };
        position.SelectionChanged += (_, _) => s.PanelPosition = (string)position.SelectedItem; panel.Children.Add(position);
        panel.Children.Add(UI.Text("登录启动", 18));
        var login = new WrapPanel(); login.Children.Add(UI.Button("启用", () => { PrivateStorage.SetLogin(true); model.Notify("已启用当前用户登录启动"); }));
        login.Children.Add(UI.Button("停用", () => { PrivateStorage.SetLogin(false); model.Notify("已停用登录启动"); })); panel.Children.Add(login);
        panel.Children.Add(UI.Text("通知由 Windows 托盘提示和应用内状态显示，系统可能根据通知设置隐藏托盘提示。"));
        panel.Children.Add(UI.Text("本地配置", 18)); panel.Children.Add(UI.Text(model.Store.FilePath));
        panel.Children.Add(UI.Text("配置与运行日志保存在当前用户私有目录；敏感参数导出时清空。导入 macOS 配置后，需要重新绑定不兼容的操作，所有动作重新审核。"));
        panel.Children.Add(UI.Button("备份并恢复默认", () =>
        {
            if (MessageBox.Show("将备份当前文件并恢复停用、未审核的默认配置。继续？", "恢复默认", MessageBoxButton.OKCancel) == MessageBoxResult.OK) { model.ResetDefaults(); Close(); }
        }));
        panel.Children.Add(UI.Button("保存全部并关闭", () => { if (model.SaveAll()) Close(); }));
        Closed += (_, _) => { recording = false; ((DesktopApp)Application.Current).ResumeHotkey(); };
        PreviewKeyDown += Record;
    }
    public static string Label(AppSettings s)
    {
        if (s.ExactLeftShift) return "左 Shift + Tab";
        return (s.HotkeyModifiers.HasFlag(2) ? "Ctrl+" : "") + (s.HotkeyModifiers.HasFlag(1) ? "Alt+" : "") +
            (s.HotkeyModifiers.HasFlag(4) ? "Shift+" : "") + (s.HotkeyModifiers.HasFlag(8) ? "Win+" : "") + KeyInterop.KeyFromVirtualKey((int)s.HotkeyCode);
    }
    private void Record(object sender, KeyEventArgs e)
    {
        if (!recording) return; e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key == Key.Escape) { recording = false; label.Text = Label(model.Current.Settings); ((DesktopApp)Application.Current).ResumeHotkey(); return; }
        if (HotkeyRules.IsInputKey((uint)KeyInterop.VirtualKeyFromKey(key))) { label.Text = "请选择其他主键；方向键和 Enter 用于输入及确认"; return; }
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin) return;
        var flags = Keyboard.Modifiers; uint mask = 0;
        if (flags.HasFlag(ModifierKeys.Alt)) mask |= 1; if (flags.HasFlag(ModifierKeys.Control)) mask |= 2;
        if (flags.HasFlag(ModifierKeys.Shift)) mask |= 4; if (flags.HasFlag(ModifierKeys.Windows)) mask |= 8;
        if (mask == 0) { label.Text = "组合键需包含修饰键"; return; }
        var s = model.Current.Settings; s.HotkeyCode = (uint)KeyInterop.VirtualKeyFromKey(key); s.HotkeyModifiers = mask;
        s.ExactLeftShift = key == Key.Tab && mask == 4 && Keyboard.IsKeyDown(Key.LeftShift) && !Keyboard.IsKeyDown(Key.RightShift);
        s.HotkeyPlatform = "windows"; label.Text = Label(s) + " · 保存后生效"; recording = false; ((DesktopApp)Application.Current).ResumeHotkey();
    }
}

internal static class ModifierExtensions
{
    public static bool HasFlag(this uint value, uint mask) => (value & mask) != 0;
}
