using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace StratagemDesk.Native;

public sealed record CommandResult(string Stdout, string Stderr, int ExitCode, bool Cancelled, bool Truncated);

/// Creates the command suspended, assigns it to a kill-on-close job, then resumes.
/// No untrusted command is allowed to run before job assignment succeeds.
public sealed class ProcessRunner
{
    public static string Quote(string argument)
    {
        if (argument.Contains('\0')) throw new ArgumentException("参数包含无效字符");
        if (argument.Length != 0 && !argument.Any(c => char.IsWhiteSpace(c) || c == '"')) return argument;
        var b = new StringBuilder("\""); var slashes = 0;
        foreach (var c in argument)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { b.Append('\\', slashes * 2 + 1); b.Append(c); }
            else { b.Append('\\', slashes); b.Append(c); }
            slashes = 0;
        }
        b.Append('\\', slashes * 2); return b.Append('"').ToString();
    }
    public async Task<CommandResult> RunAsync(string executable, IReadOnlyList<string> arguments, string directory,
        IReadOnlyDictionary<string, string> environment, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!Path.IsPathFullyQualified(executable) || !File.Exists(executable)) throw new FileNotFoundException("可执行文件需为存在的 Windows 绝对路径", executable);
        if (!string.IsNullOrEmpty(directory) && !Path.IsPathFullyQualified(directory)) throw new ArgumentException("工作目录必须为绝对路径");
        nint job = 0, outRead = 0, outWrite = 0, errRead = 0, errWrite = 0, nul = 0, attributes = 0, handles = 0, env = 0;
        ProcessInformation process = default;
        FileStream? stdout = null, stderr = null;
        try
        {
            job = CreateJobObjectW(0, null); Check(job != 0);
            var limits = new ExtendedLimits { Basic = new BasicLimits { Flags = 0x2000 } };
            Check(SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf<ExtendedLimits>()));
            var security = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), Inherit = true };
            Check(CreatePipe(out outRead, out outWrite, ref security, 0));
            Check(CreatePipe(out errRead, out errWrite, ref security, 0));
            Check(SetHandleInformation(outRead, 1, 0)); Check(SetHandleInformation(errRead, 1, 0));
            nul = CreateFileW("NUL", 0x80000000, 3, ref security, 3, 0, 0); Check(nul != -1);
            nuint size = 0;
            _ = InitializeProcThreadAttributeList(0, 1, 0, ref size);
            attributes = Marshal.AllocHGlobal(checked((int)size));
            Check(InitializeProcThreadAttributeList(attributes, 1, 0, ref size));
            handles = Marshal.AllocHGlobal(nint.Size * 3); Marshal.Copy(new[] { outWrite, errWrite, nul }, 0, handles, 3);
            Check(UpdateProcThreadAttribute(attributes, 0, 0x20002, handles, (nuint)(nint.Size * 3), 0, 0));
            var start = new StartupInfoEx { Info = new StartupInfo { Size = Marshal.SizeOf<StartupInfoEx>(), Flags = 0x100,
                StandardInput = nul, StandardOutput = outWrite, StandardError = errWrite }, Attributes = attributes };
            var variables = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (System.Collections.DictionaryEntry e in Environment.GetEnvironmentVariables()) variables[(string)e.Key] = (string)e.Value!;
            foreach (var pair in environment)
            {
                if (pair.Key.Length == 0 || pair.Key.Contains('=') || pair.Key.Contains('\0') || pair.Value.Contains('\0')) throw new ArgumentException("环境变量无效");
                variables[pair.Key] = pair.Value;
            }
            env = Marshal.StringToHGlobalUni(string.Join('\0', variables.Select(p => p.Key + "=" + p.Value)) + "\0\0");
            var command = new StringBuilder(string.Join(" ", new[] { executable }.Concat(arguments).Select(Quote)));
            if (command.Length >= 32767) throw new ArgumentException("可执行文件参数超过 Windows 命令行长度限制（32767 字符）");
            Check(CreateProcessW(executable, command, 0, 0, true, 0x00000004 | 0x00000400 | 0x08000000 | 0x00080000,
                env, string.IsNullOrWhiteSpace(directory) ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) : directory, ref start, out process));
            if (!AssignProcessToJobObject(job, process.Process))
            { var error = Marshal.GetLastWin32Error(); _ = TerminateProcess(process.Process, 1); throw new Win32Exception(error, "无法将命令加入受控进程组"); }
            Close(ref outWrite); Close(ref errWrite); Close(ref nul);
            stdout = new(new SafeFileHandle(outRead, ownsHandle: true), FileAccess.Read); outRead = 0;
            stderr = new(new SafeFileHandle(errRead, ownsHandle: true), FileAccess.Read); errRead = 0;
            var outTask = CaptureAsync(stdout); var errTask = CaptureAsync(stderr);
            Check(ResumeThread(process.Thread) != uint.MaxValue);
            var processHandle = process.Process;
            var exited = Task.Run(() => { Check(WaitForSingleObject(processHandle, uint.MaxValue) == 0); });
            var cancelled = false;
            using var registration = cancellationToken.Register(() => { _ = TerminateJobObject(job, 1); });
            await exited.ConfigureAwait(false);
            cancelled = cancellationToken.IsCancellationRequested;
            Check(GetExitCodeProcess(process.Process, out var code));
            // Descendants and their inherited pipe handles must not outlive the command.
            _ = TerminateJobObject(job, 1);
            var output = await outTask.ConfigureAwait(false); var errorOutput = await errTask.ConfigureAwait(false);
            return new(output.Text, errorOutput.Text, unchecked((int)code), cancelled, output.Truncated || errorOutput.Truncated);
        }
        finally
        {
            if (job != 0) _ = TerminateJobObject(job, 1);
            stdout?.Dispose(); stderr?.Dispose();
            Close(ref process.Thread); Close(ref process.Process);
            Close(ref outRead); Close(ref outWrite); Close(ref errRead); Close(ref errWrite); Close(ref nul); Close(ref job);
            if (attributes != 0) { DeleteProcThreadAttributeList(attributes); Marshal.FreeHGlobal(attributes); }
            if (handles != 0) Marshal.FreeHGlobal(handles);
            if (env != 0) Marshal.FreeHGlobal(env);
        }
    }
    private static async Task<(string Text, bool Truncated)> CaptureAsync(Stream stream)
    {
        const int limit = 1_048_576;
        using var memory = new MemoryStream(); var bytes = new byte[8192]; var truncated = false;
        while (true)
        {
            var count = await stream.ReadAsync(bytes).ConfigureAwait(false); if (count == 0) break;
            var keep = Math.Min(count, limit - checked((int)memory.Length));
            if (keep > 0) memory.Write(bytes, 0, keep);
            if (keep < count) truncated = true;
        }
        return (Encoding.UTF8.GetString(memory.ToArray()), truncated);
    }
    private static void Check(bool success) { if (!success) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    private static void Close(ref nint handle) { if (handle != 0 && handle != -1) _ = CloseHandle(handle); handle = 0; }
    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes { public int Length; public nint Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct StartupInfo
    {
        public int Size; public nint Reserved, Desktop, Title; public uint X, Y, Width, Height, XChars, YChars, Fill, Flags;
        public ushort Show, ReservedBytes; public nint ReservedData, StandardInput, StandardOutput, StandardError;
    }
    [StructLayout(LayoutKind.Sequential)] private struct StartupInfoEx { public StartupInfo Info; public nint Attributes; }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInformation { public nint Process, Thread; public uint ProcessId, ThreadId; }
    [StructLayout(LayoutKind.Sequential)] private struct BasicLimits
    { public long ProcessTime, JobTime; public uint Flags; public nuint MinimumWorkingSet, MaximumWorkingSet; public uint ActiveProcesses; public nuint Affinity; public uint Priority, Scheduling; }
    [StructLayout(LayoutKind.Sequential)] private struct IoCounters { public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits
    { public BasicLimits Basic; public IoCounters Io; public nuint ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern nint CreateJobObjectW(nint security, string? name);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetInformationJobObject(nint job, int type, ref ExtendedLimits data, int size);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AssignProcessToJobObject(nint job, nint process);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool TerminateJobObject(nint job, uint code);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool TerminateProcess(nint process, uint code);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreatePipe(out nint read, out nint write, ref SecurityAttributes security, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetHandleInformation(nint handle, uint mask, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern nint CreateFileW(string name, uint access, uint share, ref SecurityAttributes security, uint creation, uint flags, nint template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreateProcessW(string application, StringBuilder command, nint processSecurity, nint threadSecurity,
        [MarshalAs(UnmanagedType.Bool)] bool inherit, uint flags, nint environment, string directory, ref StartupInfoEx startup, out ProcessInformation process);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(nint thread);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(nint handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetExitCodeProcess(nint process, out uint code);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(nint handle);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool InitializeProcThreadAttributeList(nint list, int count, uint flags, ref nuint size);
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UpdateProcThreadAttribute(nint list, uint flags, nuint attribute, nint value, nuint size, nint previous, nint returnedSize);
    [DllImport("kernel32.dll")] private static extern void DeleteProcThreadAttributeList(nint list);
}
