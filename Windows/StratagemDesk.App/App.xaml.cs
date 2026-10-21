using System.Text.Json;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace StratagemDesk.App;

public partial class DesktopApp : System.Windows.Application
{
    private AppModel model = null!;
    private MainWindow manager = null!;
    private OverlayWindow overlay = null!;
    private HotkeyService? hotkey;
    private Forms.NotifyIcon? tray;
    private Mutex? singleton;
    private int generation;
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e); var smoke = e.Args.Contains("--smoke");
        var index = Array.IndexOf(e.Args, "--configuration");
        var path = index >= 0 && index + 1 < e.Args.Length ? e.Args[index + 1] : null;
        if (smoke && path == null) { Shutdown(2); return; }
        try
        {
            if (!smoke)
            {
                singleton = new Mutex(true, @"Local\StratagemDeskPublic-" + Environment.UserName, out var created);
                if (!created) { MessageBox.Show("StratagemDesk 已在托盘运行，请从托盘打开管理器。"); Shutdown(); return; }
            }
            model = new(path); var artwork = new GameArtwork(); manager = new(model, artwork); overlay = new(model, artwork);
            MainWindow = manager; manager.ShowHud += () => overlay.Begin(false); manager.ShowActivated = !smoke; manager.Show();
            model.Saved += ResumeHotkey; ResumeHotkey();
            if (!smoke)
            {
                tray = new Forms.NotifyIcon { Icon = System.Drawing.SystemIcons.Application, Text = "StratagemDesk", Visible = true };
                var menu = new Forms.ContextMenuStrip();
                menu.Items.Add("管理战备", null, (_, _) => Dispatcher.BeginInvoke(ShowManager));
                menu.Items.Add("终端预览", null, (_, _) => Dispatcher.BeginInvoke(() => overlay.Begin(false)));
                menu.Items.Add("取消工作流", null, (_, _) => model.Runner.Cancel());
                menu.Items.Add("退出", null, (_, _) => Dispatcher.BeginInvoke(() => Shutdown())); tray.ContextMenuStrip = menu;
                tray.DoubleClick += (_, _) => Dispatcher.BeginInvoke(ShowManager);
                model.Registry.Notification += text => Dispatcher.BeginInvoke(() => tray?.ShowBalloonTip(3000, "StratagemDesk", text, Forms.ToolTipIcon.Info));
                SystemEvents.SessionSwitch += OnSessionSwitch; SystemEvents.PowerModeChanged += OnPowerModeChanged;
            }
            if (smoke) _ = SmokeAsync(artwork);
        }
        catch (Exception ex)
        {
            if (smoke && path != null) { Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(Path.Combine(Path.GetDirectoryName(path)!, "startup-error.txt"), ex.ToString()); }
            else MessageBox.Show(ex.Message, "StratagemDesk 启动失败");
            Shutdown(1);
        }
    }
    private void ShowManager() { manager.Show(); manager.Activate(); }
    public void PauseHotkey() { generation++; hotkey?.Dispose(); hotkey = null; overlay.End(); }
    public void ResumeHotkey()
    {
        PauseHotkey(); var current = generation;
        try
        {
            hotkey = new(new WindowInteropHelper(manager).Handle, Json.Clone(model.Committed.Settings), effect =>
                Dispatcher.BeginInvoke(() => { if (current == generation) Handle(effect); }));
            model.HotkeyError = null;
        }
        catch (Exception ex) { model.HotkeyError = ex.Message; }
        model.Notify(model.HotkeyError ?? "热键已注册，保存状态用于终端");
    }
    private void Handle(HoldEffect effect)
    {
        switch (effect)
        {
            case HoldEffect.Began: overlay.Begin(); break;
            case HoldEffect.Ended: overlay.End(); break;
            case HoldEffect.Up: overlay.Receive(Direction.Up); break;
            case HoldEffect.Down: overlay.Receive(Direction.Down); break;
            case HoldEffect.Left: overlay.Receive(Direction.Left); break;
            case HoldEffect.Right: overlay.Receive(Direction.Right); break;
            case HoldEffect.Confirm: overlay.Confirm(); break;
            case HoldEffect.Cancel: model.Runner.Cancel(); hotkey?.Cancel(); overlay.End(); break;
        }
    }
    private void OnSessionSwitch(object sender, SessionSwitchEventArgs e) => Dispatcher.BeginInvoke(() => { hotkey?.Reset(); overlay.End(); });
    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e) => Dispatcher.BeginInvoke(() => { hotkey?.Reset(); overlay.End(); });
    protected override void OnExit(ExitEventArgs e)
    {
        model?.Runner.Cancel(); hotkey?.Dispose(); tray?.Dispose(); singleton?.Dispose();
        SystemEvents.SessionSwitch -= OnSessionSwitch; SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        if (manager != null) manager.AllowClose = true;
        base.OnExit(e);
    }
    private async Task SmokeAsync(GameArtwork artwork)
    {
        var directory = Path.GetDirectoryName(model.Store.FilePath)!;
        var checks = new Dictionary<string, bool>();
        try
        {
            var invalidPanel = new StackPanel(); UI.Number(invalidPanel, "输入超时", 5, v => model.Current.Settings.InputTimeout = v);
            var invalidWindow = new Window { Content = invalidPanel, Width = 200, Height = 120, ShowActivated = false, ShowInTaskbar = false };
            invalidWindow.Show(); await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            var numeric = invalidPanel.Children.OfType<TextBox>().Single(); numeric.Text = "NaN";
            checks["invalidNumericInputBlocked"] = UI.HasInvalidInput && !model.SaveAll() && model.Current.Settings.InputTimeout == 5;
            numeric.Text = "5";
            var sharedAction = new ActionDefinition { Approved = true, Target = "Write-Output 'ORIGINAL_SHARED'" };
            var firstShared = new Stratagem { Name = "Shared A", Steps = [new() { ActionId = sharedAction.Id }] };
            var secondShared = new Stratagem { Name = "Shared B", Steps = [new() { ActionId = sharedAction.Id }] };
            var sharedPath = Path.Combine(directory, "shared-fixture", "configuration.json");
            new ConfigurationStore(sharedPath, model.Builtins).Save(new() { Custom = [firstShared, secondShared], Actions = [sharedAction] });
            var sharedModel = new AppModel(sharedPath); var changedShared = sharedModel.CurrentProfile(firstShared.Id)!;
            changedShared.Actions[0].Target = "Write-Output 'EDITED_SHARED'"; sharedModel.SetDraft(changedShared);
            checks["legacySharedEditIsIsolated"] = sharedModel.CurrentProfile(secondShared.Id)!.Actions[0].Target == sharedAction.Target && !sharedModel.CurrentProfile(firstShared.Id)!.Actions[0].Approved;
            changedShared = sharedModel.CurrentProfile(firstShared.Id)!; changedShared.Actions[0].Approved = true; sharedModel.SetDraft(changedShared);
            var testedCurrent = await sharedModel.TestStepAsync(firstShared.Id, firstShared.Steps[0].Id, false);
            checks["stepTestUsesCurrentDetachedAction"] = testedCurrent && sharedModel.Runner.Latest.Status == RunStatus.Succeeded &&
                sharedModel.Runner.Latest.Logs.Any(l => l.Detail.Contains("EDITED_SHARED", StringComparison.Ordinal) && !l.Detail.Contains("ORIGINAL_SHARED", StringComparison.Ordinal));
            var a = new ActionDefinition { Name = "验收安全输出", Kind = ActionKind.Shell, Target = "Write-Output 'STRATAGEMDESK_WINDOWS_OK'" };
            var e = new Stratagem { Id = "windows-acceptance", Name = "Windows 验收", Enabled = true, Sequence = [Direction.Up, Direction.Right, Direction.Down, Direction.Left], Steps = [new() { ActionId = a.Id }] };
            model.SetDraft(new(e, [a])); var approved = model.CurrentProfile(e.Id)!; approved.Actions[0].Approved = true; model.SetDraft(approved);
            checks["saveFixture"] = model.SaveOne(e.Id);
            numeric.Text = "invalid";
            checks["invalidDraftRunStillBlocked"] = UI.HasInvalidInput && !await model.RunAsync(e, false, false);
            checks["invalidDraftCannotBlockSavedWorkflow"] = UI.HasInvalidInput && await model.RunAsync(model.Committed.Profile(e.Id, model.Builtins)!.Entry, true, false)
                && model.Runner.Latest.Status == RunStatus.Succeeded && model.Runner.Latest.Logs.Any(l => l.Detail.Contains("STRATAGEMDESK_WINDOWS_OK", StringComparison.Ordinal));
            numeric.Text = "5"; invalidWindow.Close();
            overlay.Begin(); foreach (var d in e.Sequence) overlay.Receive(d); checks["sequenceRecognized"] = overlay.Pending;
            overlay.End(); overlay.Confirm(); checks["releaseCancelsPending"] = !overlay.Pending && model.Runner.RunningId == null;
            overlay.Begin(); foreach (var d in e.Sequence) overlay.Receive(d); overlay.Confirm();
            var running = model.Runner.RunningId != null; overlay.End();
            for (var i = 0; i < 400 && model.Runner.RunningId != null; i++) await Task.Delay(50);
            checks["releaseHidesHud"] = !overlay.Held && !overlay.IsVisible;
            checks["workflowContinuesAfterRelease"] = running && model.Runner.Latest.Status == RunStatus.Succeeded && model.Runner.Latest.Logs.Any(l => l.Detail.Contains("STRATAGEMDESK_WINDOWS_OK", StringComparison.Ordinal));
            overlay.Receive(Direction.Up); checks["releasedInputIgnored"] = !overlay.Pending && !overlay.IsVisible;
            model.SetEnabled([e.Id], false); overlay.Begin(); checks["unsavedEnableStateNotApplied"] = overlay.Candidates.Any(x => x.Id == e.Id); overlay.End();
            checks["saveDisabled"] = model.SaveOne(e.Id); overlay.Begin(); checks["savedDisabledHidden"] = overlay.Candidates.All(x => x.Id != e.Id); overlay.End();
            var other = new Stratagem { Name = "独立草稿" }; model.SetDraft(new(other, [])); model.Current.Settings.InputTimeout = 17;
            var changed = model.CurrentProfile(e.Id)!; changed.Entry.Name = "已保存改名"; model.SetDraft(changed);
            checks["singleSave"] = model.SaveOne(e.Id); var disk = model.Store.Load();
            checks["otherDraftAndSettingsExcluded"] = disk.Profile(other.Id, model.Builtins) == null && disk.Settings.InputTimeout == 5 && model.CurrentProfile(other.Id) != null && model.Current.Settings.InputTimeout == 17;
            changed = model.CurrentProfile(e.Id)!; changed.Actions[0].Target = "Write-Output changed"; model.SetDraft(changed);
            checks["editingRevokesApproval"] = !model.CurrentProfile(e.Id)!.Actions[0].Approved;
            model.Restore(e.Id, false); checks["restoreSavedIncludesAction"] = model.CurrentProfile(e.Id)!.Equivalent(model.SavedProfile(e.Id)!);
            model.SetEnabled([e.Id], true); checks["saveEnabled"] = model.SaveOne(e.Id);
            var collision = new Stratagem { Enabled = true, Sequence = [Direction.Up] }; model.SetDraft(new(collision, []));
            var before = File.ReadAllBytes(model.Store.FilePath); checks["conflictPreservesFile"] = !model.SaveOne(collision.Id) && before.SequenceEqual(File.ReadAllBytes(model.Store.FilePath)); model.Delete(collision.Id);
            model.Restore(e.Id, true); checks["customDefaultIsBlankAndDisabled"] = model.CurrentProfile(e.Id)!.Entry.Steps.Count == 0 && !model.CurrentProfile(e.Id)!.Entry.Enabled;
            model.Restore(e.Id, false);
            model.SetEnabled([e.Id], false);
            var ids = new[] { "desk.terminal", "desk.home", "desk.files", "desk.clock", "desk.calculate", "desk.workflow", "desk.status" };
            model.SetEnabled(ids, true); model.Current.Settings.HotkeyCode = 0x79; model.Current.Settings.HotkeyModifiers = 3; checks["saveBuiltinSelection"] = model.SaveAll();
            checks["hotkeyRegistered"] = model.HotkeyError == null;
            model.Selection = "desk.workflow"; manager.RefreshEditor();
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            SaveImage(manager, Path.Combine(directory, "manager.png"));
            overlay.Begin(); await Task.Delay(150); SaveImage(overlay, Path.Combine(directory, "hud.png")); overlay.End();
            var icons = artwork.Validate(model.Builtins);
            checks["allBundledArtworkLoaded"] = (int)icons["loaded"] == model.Builtins.Count && (int)icons["hashVerified"] == model.Builtins.Count;
            var passed = checks.Values.All(v => v);
            File.WriteAllBytes(Path.Combine(directory, "smoke.json"), JsonSerializer.SerializeToUtf8Bytes(new { passed, checks, icons,
                scope = "Windows WPF controllers, native command execution and rendering. No physical keyboard injection; interactive desktop acceptance remains separate." }, Json.Options));
            Shutdown(passed ? 0 : 1);
        }
        catch (Exception ex) { File.WriteAllText(Path.Combine(directory, "smoke-error.txt"), ex.ToString()); Shutdown(1); }
    }
    private static void SaveImage(Window window, string path)
    {
        window.UpdateLayout(); var bitmap = new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth), (int)Math.Ceiling(window.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(window); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); using var stream = File.Create(path); encoder.Save(stream);
    }
}
