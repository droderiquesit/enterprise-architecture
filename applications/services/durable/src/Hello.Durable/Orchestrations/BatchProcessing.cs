using Microsoft.Azure.Functions.Worker;
using Microsoft.DurableTask;
using Microsoft.Extensions.Logging;

namespace Hello.Durable.Orchestrations;

/// <summary>Fan-out ProcessItem × N (≤ 50) → fan-in summary → RecordBatchRun (SQL) → optional EnqueueBatchItems.</summary>
public static partial class BatchProcessing
{
    public const string Name = nameof(BatchProcessing);
    public const int MaxItems = 50;

    [Function(Name)]
    public static async Task<BatchSummary> RunAsync([OrchestrationTrigger] TaskOrchestrationContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var input = context.GetInput<BatchInput>() ?? new BatchInput(10, false);
        var count = Math.Clamp(input.Items, 1, MaxItems);
        var log = context.CreateReplaySafeLogger(Name);
        var startedAt = context.CurrentUtcDateTime;

        var tasks = Enumerable.Range(1, count).Select(i => ProcessSafeAsync(context, new ItemInput(context.InstanceId, i))).ToList();
        var results = await Task.WhenAll(tasks);
        var summary = Aggregate(context.InstanceId, results, startedAt, context.CurrentUtcDateTime);

        try
        {
            await context.CallActivityAsync(WorkflowActivityNames.RecordBatchRun, summary, OrderProcessing.DefaultRetry);
            if (input.Enqueue)
            {
                var ids = results.Where(r => r.Succeeded).Select(r => $"{context.InstanceId}:{r.Index}").ToList();
                await context.CallActivityAsync(WorkflowActivityNames.EnqueueBatchItems, new EnqueueInput(context.InstanceId, ids), OrderProcessing.DefaultRetry);
            }
        }
        catch (TaskFailedException)
        {
            await OrderProcessing.RecordOutcomeAsync(context, Name, WorkflowOutcome.Failed, startedAt);
            throw;
        }

        await OrderProcessing.RecordOutcomeAsync(context, Name, summary.Failed == 0 ? WorkflowOutcome.Succeeded : WorkflowOutcome.Failed, startedAt);

        LogDone(log, context.InstanceId, summary.Succeeded, summary.Failed);
        return summary;
    }

    public static BatchSummary Aggregate(string batchId, IReadOnlyCollection<ItemResult> results, DateTime startedAt, DateTime completedAt)
    {
        ArgumentNullException.ThrowIfNull(results);
        return new BatchSummary(
            batchId,
            results.Count,
            results.Count(r => r.Succeeded),
            results.Count(r => !r.Succeeded),
            results.Where(r => r.Succeeded).Sum(r => r.Value),
            new DateTimeOffset(startedAt, TimeSpan.Zero),
            new DateTimeOffset(completedAt, TimeSpan.Zero));
    }

    private static async Task<ItemResult> ProcessSafeAsync(TaskOrchestrationContext context, ItemInput item)
    {
        try
        {
            return await context.CallActivityAsync<ItemResult>(WorkflowActivityNames.ProcessItem, item, OrderProcessing.DefaultRetry);
        }
        catch (TaskFailedException ex)
        {
            return new ItemResult(item.Index, false, 0, ex.FailureDetails.ErrorType);
        }
    }

    [LoggerMessage(EventId = 7101, Level = LogLevel.Information, Message = "Batch {batch_id} completed: {succeeded} succeeded, {failed} failed")]
    private static partial void LogDone(ILogger logger, string batch_id, int succeeded, int failed);
}
