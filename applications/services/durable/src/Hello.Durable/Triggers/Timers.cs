using Hello.Durable.Orchestrations;
using Microsoft.Azure.Functions.Worker;
using Microsoft.DurableTask;
using Microsoft.DurableTask.Client;
using Microsoft.Extensions.Logging;

namespace Hello.Durable.Triggers;

/// <summary>Reconciliation (RECONCILE_SCHEDULE, default every 30 min) and PurgeHistory (daily 03:15 UTC).</summary>
public sealed partial class Timers(DurableSettings settings, TimeProvider time, ILogger<Timers> logger)
{
    [Function("ReconciliationTimer")]
    public async Task Reconcile([TimerTrigger("%RECONCILE_SCHEDULE%")] TimerInfo timer, [DurableClient] DurableTaskClient client, FunctionContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var id = await StartReconciliationAsync(client, settings, time, "timer", context.CancellationToken).ConfigureAwait(false);
        LogStarted(logger, id);
    }

    [Function("PurgeHistory")]
    public async Task Purge([TimerTrigger("0 15 3 * * *")] TimerInfo timer, [DurableClient] DurableTaskClient client, FunctionContext context)
    {
        ArgumentNullException.ThrowIfNull(client);
        ArgumentNullException.ThrowIfNull(context);
        var cutoff = time.GetUtcNow().AddDays(-settings.HistoryRetentionDays);
        var result = await client.PurgeAllInstancesAsync(
            new PurgeInstancesFilter(
                CreatedFrom: DateTimeOffset.UnixEpoch,
                CreatedTo: cutoff,
                Statuses: [OrchestrationRuntimeStatus.Completed, OrchestrationRuntimeStatus.Failed, OrchestrationRuntimeStatus.Terminated]),
            context.CancellationToken).ConfigureAwait(false);
        LogPurged(logger, result.PurgedInstanceCount, cutoff);
    }

    public static async Task<string> StartReconciliationAsync(DurableTaskClient client, DurableSettings settings, TimeProvider time, string trigger, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(client);
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(time);
        var now = time.GetUtcNow();
        // One run per minute per trigger kind (idempotent against timer double-fires).
        var instanceId = $"reconcile-{trigger}-{now:yyyyMMddHHmm}";
        if (await client.GetInstanceAsync(instanceId, false, cancellationToken).ConfigureAwait(false) is null)
        {
            await client.ScheduleNewOrchestrationInstanceAsync(
                new TaskName(Reconciliation.Name),
                new ReconcileInput(now.AddHours(-settings.ReconcileWindowHours)),
                new StartOrchestrationOptions(instanceId),
                cancellationToken).ConfigureAwait(false);
        }

        return instanceId;
    }

    [LoggerMessage(EventId = 7601, Level = LogLevel.Information, Message = "Reconciliation {workflow_instance_id} scheduled")]
    private static partial void LogStarted(ILogger logger, string workflow_instance_id);

    [LoggerMessage(EventId = 7602, Level = LogLevel.Information, Message = "Purged {purged_count} durable instances created before {cutoff}")]
    private static partial void LogPurged(ILogger logger, int purged_count, DateTimeOffset cutoff);
}
