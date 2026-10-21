using System.ComponentModel;
using System.Runtime.InteropServices;
using StratagemDesk.Core;

namespace StratagemDesk.Native;

public sealed class HotkeyService : IDisposable
{
    private readonly object gate = new();
    private readonly nint window;
    private readonly HoldState state;
    private readonly HookProc callback;
    private readonly Action<HoldEffect> emit;
    private readonly Thread thread;
    private readonly ManualResetEventSlim ready = new();
    private nint hook;
    private uint threadId;
    private Exception? failure;
    private volatile bool disposed;
    private readonly bool registered;
    public HotkeyService(nint window, AppSettings settings, Action<HoldEffect> emit)
    {
        this.window = window; this.emit = emit; state = new(settings); callback = OnKeyboard;
        // RegisterHotKey cannot distinguish left/right Shift; reserving Shift+Tab would
        // steal the right-Shift chord even when our hook intentionally passes it through.
        if (!settings.ExactLeftShift)
        {
            if (!RegisterHotKey(window, 0x5344, settings.HotkeyModifiers | 0x4000, settings.HotkeyCode))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "快捷键已占用或不可用，请更换组合键");
            registered = true;
        }
        foreach (uint key in new uint[] { 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C })
            if ((GetAsyncKeyState((int)key) & 0x8000) != 0) state.Seed(key);
        if ((GetAsyncKeyState((int)settings.HotkeyCode) & 0x8000) != 0) { state.Seed(settings.HotkeyCode); state.Cancel(); }
        thread = new Thread(MessageLoop) { IsBackground = true, Name = "StratagemDesk keyboard control" };
        thread.Start();
        if (!ready.Wait(TimeSpan.FromSeconds(5))) { Dispose(); throw new TimeoutException("键盘监听启动超时"); }
        if (failure != null) { Dispose(); throw failure; }
    }
    public void Cancel() { lock (gate) state.Cancel(); }
    public void Reset() { lock (gate) state.Reset(); }
    private void MessageLoop()
    {
        try
        {
            threadId = GetCurrentThreadId(); _ = PeekMessageW(out _, 0, 0, 0, 0);
            hook = SetWindowsHookExW(13, callback, GetModuleHandleW(null), 0);
            if (hook == 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "无法安装键盘监听");
            ready.Set();
            while (GetMessageW(out var message, 0, 0, 0) > 0) { _ = TranslateMessage(ref message); _ = DispatchMessageW(ref message); }
        }
        catch (Exception ex) { failure = ex; ready.Set(); }
        finally { if (hook != 0) _ = UnhookWindowsHookEx(hook); hook = 0; }
    }
    private nint OnKeyboard(int code, nint message, nint data)
    {
        if (code < 0 || disposed) return CallNextHookEx(0, code, message, data);
        var key = Marshal.PtrToStructure<KeyboardData>(data);
        // Synthetic keystrokes never launch workflows or modify the physical hold state.
        if ((key.Flags & 0x10) != 0) return CallNextHookEx(0, code, message, data);
        var down = message == 0x100 || message == 0x104;
        var up = message == 0x101 || message == 0x105;
        if (!down && !up) return CallNextHookEx(0, code, message, data);
        KeyDecision decision;
        lock (gate) decision = state.Handle(key.VirtualKey, down);
        foreach (var effect in decision.Effects) emit(effect); // Must only enqueue, never perform UI/commands here.
        return decision.Consume ? 1 : CallNextHookEx(0, code, message, data);
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        if (registered) _ = UnregisterHotKey(window, 0x5344);
        if (threadId != 0) _ = PostThreadMessageW(threadId, 0x12, 0, 0);
        if (thread.IsAlive && Thread.CurrentThread != thread) _ = thread.Join(TimeSpan.FromSeconds(2));
        lock (gate) state.Reset();
        GC.KeepAlive(callback);
    }
    [StructLayout(LayoutKind.Sequential)] private struct KeyboardData { public uint VirtualKey, ScanCode, Flags, Time; public nuint Extra; }
    [StructLayout(LayoutKind.Sequential)] private struct Message { public nint Window; public uint Id; public nuint WParam; public nint LParam; public uint Time; public int X, Y; public uint Private; }
    private delegate nint HookProc(int code, nint message, nint data);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnregisterHotKey(nint window, int id);
    [DllImport("user32.dll", SetLastError = true)] private static extern nint SetWindowsHookExW(int type, HookProc callback, nint module, uint threadId);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32.dll")] private static extern nint CallNextHookEx(nint hook, int code, nint message, nint data);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern int GetMessageW(out Message message, nint window, uint min, uint max);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PeekMessageW(out Message message, nint window, uint min, uint max, uint flags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool TranslateMessage(ref Message message);
    [DllImport("user32.dll")] private static extern nint DispatchMessageW(ref Message message);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PostThreadMessageW(uint id, uint message, nuint wParam, nint lParam);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern nint GetModuleHandleW(string? name);
}
