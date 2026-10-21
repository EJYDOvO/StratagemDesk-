using System.Diagnostics;

namespace StratagemDesk.Core;

public enum RunStatus { Running, Succeeded, Failed, Cancelled }
public sealed record StepLog(string StepId, string Name, RunStatus Status, string Detail, DateTimeOffset Date);
public sealed record ActionOutcome(bool Success, string Detail);
public sealed record WorkflowResult(RunStatus Status, string Summary, List<StepLog> Logs);

public sealed class WorkflowRunner
{
    private readonly object gate = new();
    private CancellationTokenSource? cancellation;
    public string? RunningId { get; private set; }
    public WorkflowResult Latest { get; private set; } = new(RunStatus.Succeeded, "尚未执行", []);
    public event Action? Changed;
    public void Cancel() { lock (gate) cancellation?.Cancel(); }
    public async Task<WorkflowResult> RunAsync(Stratagem source, Configuration configuration,
        Func<ActionDefinition, CancellationToken, Task<ActionOutcome>> handler)
    {
        var entry = Json.Clone(source); var c = Json.Clone(configuration);
        lock (gate)
        {
            if (RunningId != null) throw new InvalidOperationException("已有工作流正在执行");
            if (entry.Steps.Count == 0 || entry.Steps.Any(s => c.Action(s.ActionId)?.Approved != true))
                throw new InvalidOperationException("请配置工作流并逐项审核动作");
            cancellation = new(); RunningId = entry.Id;
        }
        using var cancel = cancellation!;
        var logs = new List<StepLog>(); var redact = entry.Steps.Any(s => c.Action(s.ActionId)!.Sensitive);
        var clock = Stopwatch.StartNew(); var failed = false;
        Publish(RunStatus.Running, $"正在执行 {entry.Name}");
        try
        {
            foreach (var step in entry.Steps)
            {
                cancel.Token.ThrowIfCancellationRequested();
                var remaining = c.Settings.WorkflowTimeout - clock.Elapsed.TotalSeconds;
                if (remaining <= 0) throw new TimeoutException("整条工作流超时");
                var action = c.Action(step.ActionId)!;
                var budget = Math.Min(remaining, action.Timeout);
                var index = logs.Count;
                logs.Add(new(step.Id, redact ? $"敏感步骤 {index + 1}" : action.Name, RunStatus.Running, "正在执行", DateTimeOffset.UtcNow));
                Publish(RunStatus.Running, $"正在执行 {entry.Name}");
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel.Token);
                timeout.CancelAfter(TimeSpan.FromSeconds(budget));
                try
                {
                    var result = await handler(Json.Clone(action), timeout.Token).ConfigureAwait(false);
                    timeout.Token.ThrowIfCancellationRequested();
                    var detail = redact ? "[敏感工作流：输出已隐藏]" : result.Detail[..Math.Min(16_384, result.Detail.Length)];
                    logs[index] = logs[index] with { Status = result.Success ? RunStatus.Succeeded : RunStatus.Failed, Detail = detail };
                    if (!result.Success) { failed = true; if (!step.ContinueOnFailure) throw new InvalidOperationException("步骤执行失败"); }
                }
                catch (Exception ex)
                {
                    var cancelled = cancel.IsCancellationRequested;
                    var text = timeout.IsCancellationRequested && !cancelled ? "步骤或工作流超时" : ex.Message;
                    logs[index] = logs[index] with { Status = cancelled ? RunStatus.Cancelled : RunStatus.Failed,
                        Detail = redact ? "[敏感工作流：错误已隐藏]" : logs[index].Detail == "正在执行" ? text[..Math.Min(16_384, text.Length)] : logs[index].Detail };
                    if (cancelled || !step.ContinueOnFailure) throw;
                    failed = true;
                }
                if (step.DelayAfter > 0)
                {
                    if (c.Settings.WorkflowTimeout - clock.Elapsed.TotalSeconds <= step.DelayAfter) throw new TimeoutException("步骤间延迟超过剩余时间");
                    await Task.Delay(TimeSpan.FromSeconds(step.DelayAfter), cancel.Token).ConfigureAwait(false);
                }
            }
            cancel.Token.ThrowIfCancellationRequested();
            if (clock.Elapsed.TotalSeconds > c.Settings.WorkflowTimeout) throw new TimeoutException("工作流超时");
            Publish(failed ? RunStatus.Failed : RunStatus.Succeeded, failed ? "执行结束，部分步骤失败" : "工作流执行成功");
        }
        catch (Exception ex)
        {
            Publish(cancel.IsCancellationRequested ? RunStatus.Cancelled : RunStatus.Failed,
                cancel.IsCancellationRequested ? "工作流已取消" : redact ? "工作流失败（敏感详情隐藏）" : ex is OperationCanceledException ? "步骤或工作流超时" : ex.Message);
        }
        finally { lock (gate) { RunningId = null; cancellation = null; } Changed?.Invoke(); }
        return Latest;

        void Publish(RunStatus status, string summary) { Latest = new(status, summary, [.. logs]); Changed?.Invoke(); }
    }
}
