using System.Diagnostics;
using StratagemDesk.Core;

namespace StratagemDesk.Native;

public sealed class ActionRegistry
{
    private readonly ProcessRunner runner = new();
    public event Action<string>? Notification;
    public static string? UnsupportedReason(ActionDefinition action)
    {
        if (action.Kind == ActionKind.Shortcut) return "macOS 快捷指令无法在 Windows 运行，请改绑为 Windows 应用或 PowerShell";
        if (action.Kind == ActionKind.Shell && !new[] { "powershell.exe", "pwsh.exe" }.Contains(Path.GetFileName(action.Shell), StringComparer.OrdinalIgnoreCase))
            return "Windows Shell 动作使用 PowerShell；原 zsh 脚本需重新编写。其他解释器可用“可执行文件”动作";
        if (action.Kind is ActionKind.Application or ActionKind.Executable && !Path.IsPathFullyQualified(action.Target))
            return "请重新绑定 Windows 应用或可执行文件的绝对路径";
        return null;
    }
    public async Task<ActionOutcome> ExecuteAsync(ActionDefinition action, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (!action.Approved) throw new InvalidOperationException("动作尚未审核");
        if (UnsupportedReason(action) is { } reason) throw new NotSupportedException(reason);
        switch (action.Kind)
        {
            case ActionKind.Shell:
            case ActionKind.Executable:
            {
                using var shell = action.Kind == ActionKind.Shell ? new PowerShellCommand(action.Target, action.Arguments) : null;
                var args = shell?.Arguments ?? action.Arguments;
                var result = await runner.RunAsync(action.Kind == ActionKind.Shell ? action.Shell : action.Target,
                    args, action.WorkingDirectory, action.Environment, token).ConfigureAwait(false);
                if (result.Cancelled) throw new OperationCanceledException(token);
                return new(result.ExitCode == 0, $"退出码：{result.ExitCode}{(result.Truncated ? " · 输出截断" : "")}\nstdout:\n{result.Stdout}\nstderr:\n{result.Stderr}");
            }
            case ActionKind.Delay:
                await Task.Delay(TimeSpan.FromSeconds(action.Seconds), token).ConfigureAwait(false); return new(true, "延迟完成");
            case ActionKind.Notification:
                Notification?.Invoke(action.Sensitive ? "工作流状态更新" : action.Target); return new(true, action.Target);
            case ActionKind.Application:
                if (!File.Exists(action.Target)) throw new FileNotFoundException("找不到应用", action.Target);
                var start = new ProcessStartInfo(action.Target) { UseShellExecute = true };
                foreach (var arg in action.Arguments) start.ArgumentList.Add(arg);
                using (Process.Start(start)) { }
                return new(true, "应用启动请求已提交");
            case ActionKind.Open:
                var target = ExpandHome(action.Target);
                if (!(Path.IsPathFullyQualified(target) || Uri.TryCreate(target, UriKind.Absolute, out _)))
                    throw new ArgumentException("请输入 Windows 文件绝对路径或完整 URL");
                using (Process.Start(new ProcessStartInfo(target) { UseShellExecute = true })) { }
                return new(true, "已提交打开请求");
            default: throw new NotSupportedException("不支持此动作");
        }
    }
    private static string ExpandHome(string value) => value == "~" ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) :
        value.StartsWith("~/", StringComparison.Ordinal) || value.StartsWith("~\\", StringComparison.Ordinal) ?
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), value[2..]) : value;
}
