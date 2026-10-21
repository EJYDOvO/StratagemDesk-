using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Threading;
using System.Windows.Media.Animation;

namespace StratagemDesk.App;

public sealed class OverlayWindow : Window
{
    private readonly AppModel model;
    private readonly GameArtwork artwork;
    private readonly StackPanel rows = new();
    private readonly TextBlock feedback = UI.Text("");
    private readonly List<Direction> input = [];
    private readonly Stopwatch idle = new();
    private readonly DispatcherTimer timer;
    private Stratagem? matched;
    private Stratagem? pending;
    private string state = "";
    public bool Held { get; private set; }
    public bool Pending => pending != null;
    public bool IsRejected { get; private set; }
    public List<Stratagem> Candidates
    {
        get
        {
            var order = new[] { "desk.terminal", "desk.home", "desk.files", "desk.clock", "desk.calculate", "desk.workflow", "desk.status" };
            return model.Committed.Resolve(model.Builtins).Where(e => e.Enabled && SequenceMatcher.StartsWith(e.Sequence, input))
                .OrderBy(e => { var i = Array.IndexOf(order, e.Id); return i < 0 ? 1000 : i; }).ThenBy(e => e.Name).ToList();
        }
    }
    public OverlayWindow(AppModel model, GameArtwork artwork)
    {
        this.model = model; this.artwork = artwork;
        Width = 350; Height = 450; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true; Background = Brushes.Transparent; Topmost = true; ShowActivated = false; ShowInTaskbar = false;
        var content = new StackPanel { Margin = new(18, 0, 0, 0) };
        var title = UI.Text("⊕  STRATAGEMS", 17); title.FontWeight = FontWeights.Bold; title.Foreground = Brushes.White;
        content.Children.Add(new Border { Background = new SolidColorBrush(Color.FromArgb(245, 19, 22, 19)), Child = title, Padding = new(10, 5, 10, 5), HorizontalAlignment = HorizontalAlignment.Left, Margin = new(0, 0, 0, 8) });
        var body = new StackPanel();
        body.Children.Add(new ScrollViewer { Content = rows, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden, MaxHeight = 370 });
        feedback.Foreground = Brushes.PaleGoldenrod; feedback.FontSize = 11; body.Children.Add(feedback);
        content.Children.Add(new Border { Child = body, Background = new SolidColorBrush(Color.FromArgb(245, 19, 22, 19)), BorderBrush = new SolidColorBrush(Color.FromArgb(100, 240, 240, 220)), BorderThickness = new(.6), Padding = new(8) });
        Content = content;
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            _ = SetWindowLongPtrW(hwnd, -20, GetWindowLongPtrW(hwnd, -20) | 0x08000080); // no activation, tool window
        };
        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(100), DispatcherPriority.Background, (_, _) =>
        {
            if (Held && pending == null && matched == null && idle.Elapsed.TotalSeconds >= model.Committed.Settings.InputTimeout)
            { input.Clear(); state = "TIMED OUT"; idle.Restart(); Render(); }
        }, Dispatcher); timer.Stop();
    }
    public void Begin(bool held = true)
    {
        if (model.LoadFailed) { model.Notify("请先修复配置加载错误"); return; }
        if (Held && held) return;
        Held = held; input.Clear(); pending = null; matched = null; IsRejected = false; state = "";
        if (model.Runner.RunningId is { } running)
        { matched = model.Committed.Resolve(model.Builtins).FirstOrDefault(e => e.Id == running) ?? new() { Name = "正在执行的工作流" }; state = "ACTIVATING"; }
        idle.Restart(); if (held) timer.Start(); else timer.Stop(); Render(); Show(); Position();
        if (SystemParameters.ClientAreaAnimation) BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(100)));
    }
    public void End() { Held = false; timer.Stop(); input.Clear(); pending = null; matched = null; IsRejected = false; Hide(); }
    public void Receive(Direction d)
    {
        if (!Held || !IsVisible || matched != null || model.Runner.RunningId != null) return;
        var entries = model.Committed.Resolve(model.Builtins);
        if (SequenceMatcher.Conflicts(entries).Count != 0) { state = "SEQUENCE CONFLICT"; Render(); return; }
        input.Add(d); idle.Restart(); state = "";
        var result = SequenceMatcher.Match(input, entries);
        switch (result.Kind)
        {
            case MatchKind.Matched:
                matched = Json.Clone(entries.First(e => e.Id == result.Ids[0])); timer.Stop();
                if (matched.Confirmation) { pending = matched; state = "HOLD + RETURN TO CONFIRM"; }
                else _ = LaunchAsync(matched);
                break;
            case MatchKind.Invalid: input.Clear(); state = "INPUT ERROR"; break;
            case MatchKind.Ambiguous: input.Clear(); state = "SEQUENCE CONFLICT"; break;
        }
        Render();
    }
    public void Confirm() { if (Held && pending is { } e) { pending = null; _ = LaunchAsync(e); } }
    public async Task LaunchAsync(Stratagem e)
    {
        state = "ACTIVATING"; Render();
        var accepted = await model.RunAsync(e, true, false); IsRejected = !accepted;
        if (IsVisible && matched?.Id == e.Id) { state = accepted ? model.Runner.Latest.Status.ToString().ToUpperInvariant() : "BLOCKED"; Render(); }
    }
    private void Render()
    {
        rows.Children.Clear(); feedback.Text = state;
        var entries = matched != null ? new List<Stratagem> { matched } : Candidates;
        foreach (var e in entries)
        {
            var row = new DockPanel { MinHeight = 52, Margin = new(0, 0, 0, 2) };
            row.Children.Add(new Image { Source = artwork.Image(e), Width = 40, Height = 40, Margin = new(0, 3, 10, 3) });
            var text = new StackPanel(); var name = UI.Text(artwork.Name(e).ToUpperInvariant(), 15); name.Foreground = Brushes.Beige; name.FontWeight = FontWeights.Bold; name.FontFamily = new("Bahnschrift"); text.Children.Add(name);
            var arrows = new TextBlock { FontSize = 21, FontFamily = new("Segoe UI Symbol"), Margin = new(0, -4, 0, 0) };
            for (var i = 0; i < e.Sequence.Count; i++) arrows.Inlines.Add(new System.Windows.Documents.Run(e.Sequence[i] switch { Direction.Up => "⬆", Direction.Down => "⬇", Direction.Left => "⬅", _ => "➡" }) { Foreground = i < input.Count ? artwork.Accent(e) : Brushes.Beige });
            text.Children.Add(arrows); row.Children.Add(text); rows.Children.Add(row);
        }
        if (entries.Count == 0) { var none = UI.Text("NO STRATAGEMS"); none.Foreground = Brushes.Beige; rows.Children.Add(none); }
        if (pending != null) { var preview = UI.Text(model.Preview(pending, model.Committed), 11); preview.Foreground = Brushes.Beige; rows.Children.Add(preview); }
    }
    private void Position()
    {
        var cursor = System.Windows.Forms.Cursor.Position;
        var screen = System.Windows.Forms.Screen.FromPoint(cursor).WorkingArea;
        var monitor = MonitorFromPoint(new NativePoint { X = cursor.X, Y = cursor.Y }, 2);
        _ = GetDpiForMonitor(monitor, 0, out var dpi, out _); var scale = dpi == 0 ? 1 : dpi / 96d;
        var w = Math.Min((int)(350 * scale), screen.Width - 32); var h = Math.Min((int)(450 * scale), screen.Height - 48);
        var x = screen.Left + 18; var y = screen.Top + 18;
        switch (model.Committed.Settings.PanelPosition)
        {
            case "center": x = screen.Left + (screen.Width - w) / 2; y = screen.Top + (screen.Height - h) / 2; break;
            case "top": x = screen.Left + (screen.Width - w) / 2; break;
            case "bottom": x = screen.Left + (screen.Width - w) / 2; y = screen.Bottom - h - 18; break;
        }
        _ = SetWindowPos(new WindowInteropHelper(this).Handle, -1, x, y, w, h, 0x0010 | 0x0040);
    }
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern nint GetWindowLongPtrW(nint window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern nint SetWindowLongPtrW(nint window, int index, nint value);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X, Y; }
    [DllImport("user32.dll")] private static extern nint MonitorFromPoint(NativePoint point, uint flags);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(nint monitor, int type, out uint x, out uint y);
}
