using Hello.Common.Telemetry;
using Hello.Durable.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace Hello.Durable;

public static class WorkflowActivityNames
{
    public const string ReserveInventory = nameof(ReserveInventory);
    public const string ReleaseInventory = nameof(ReleaseInventory);
    public const string ChargePayment = nameof(ChargePayment);
    public const string RecordFulfillment = nameof(RecordFulfillment);
    public const string UpdateOrderStatus = nameof(UpdateOrderStatus);
    public const string ProcessItem = nameof(ProcessItem);
    public const string RecordBatchRun = nameof(RecordBatchRun);
    public const string EnqueueBatchItems = nameof(EnqueueBatchItems);
    public const string GetOrdersSince = nameof(GetOrdersSince);
    public const string GetFulfillmentRecordsSince = nameof(GetFulfillmentRecordsSince);
    public const string RecordReconciliationRun = nameof(RecordReconciliationRun);
    public const string RecordWorkflowOutcome = nameof(RecordWorkflowOutcome);
}

/// <summary>Lab-only activity failure injection (FAULT_ACTIVITY_FAILURE_RATE, default 0 = off).</summary>
public sealed class ActivityFaults(DurableSettings settings, HelloMetrics metrics)
{
    public void MaybeFail(string activity)
    {
        if (settings.ActivityFailureRate > 0 && Random.Shared.NextDouble() < settings.ActivityFailureRate)
        {
            metrics.FaultsInjected.Add(1, new KeyValuePair<string, object?>("fault.type", "activity_failure"));
            throw new InjectedActivityFailureException($"Injected lab failure in {activity}");
        }
    }
}

public sealed class InjectedActivityFailureException : Exception
{
    public InjectedActivityFailureException()
    {
    }

    public InjectedActivityFailureException(string message)
        : base(message)
    {
    }

    public InjectedActivityFailureException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

/// <summary>
/// Activities: thin, idempotent wrappers over injected services (unit-testable). Each external call is idempotent by
/// order id (reserve/release/payments) or a MERGE keyed by natural id (SQL), so durable retries are safe.
/// </summary>
public sealed partial class WorkflowActivities(
    IInventoryService inventory,
    IPaymentService payments,
    IOrdersService orders,
    IFulfillmentStore store,
    IBatchItemPublisher batchItems,
    ActivityFaults faults,
    HelloMetrics metrics,
    ILogger<WorkflowActivities> logger)
{
    [Function(WorkflowActivityNames.ReserveInventory)]
    public Task<ReserveResult> ReserveInventory([ActivityTrigger] ReserveInput input, FunctionContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        faults.MaybeFail(WorkflowActivityNames.ReserveInventory);
        return inventory.ReserveAsync(input, context.CancellationToken);
    }

    [Function(WorkflowActivityNames.ReleaseInventory)]
    public async Task ReleaseInventory([ActivityTrigger] ReleaseInput input, FunctionContext context)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(context);
        await inventory.ReleaseAsync(input, context.CancellationToken).ConfigureAwait(false);
        LogCompensated(logger, input.OrderId);
    }

    [Function(WorkflowActivityNames.ChargePayment)]
    public Task<PaymentResult> ChargePayment([ActivityTrigger] ChargeInput input, FunctionContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        faults.MaybeFail(WorkflowActivityNames.ChargePayment);
        return payments.ChargeAsync(input, context.CancellationToken);
    }

    [Function(WorkflowActivityNames.RecordFulfillment)]
    public async Task RecordFulfillment([ActivityTrigger] FulfillmentRecord record, FunctionContext context)
    {
        ArgumentNullException.ThrowIfNull(record);
        ArgumentNullException.ThrowIfNull(context);
        faults.MaybeFail(WorkflowActivityNames.RecordFulfillment);
        await store.UpsertFulfillmentAsync(record, context.CancellationToken).ConfigureAwait(false);
    }

    [Function(WorkflowActivityNames.UpdateOrderStatus)]
    public Task UpdateOrderStatus([ActivityTrigger] StatusUpdateInput input, FunctionContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return orders.UpdateStatusAsync(input, context.CancellationToken);
    }

    [Function(WorkflowActivityNames.ProcessItem)]
    public Task<ItemResult> ProcessItem([ActivityTrigger] ItemInput input)
    {
        ArgumentNullException.ThrowIfNull(input);
        faults.MaybeFail(WorkflowActivityNames.ProcessItem);
        // Synthetic CPU-light work with a deterministic value per item.
        return Task.FromResult(new ItemResult(input.Index, true, 1.00m + (input.Index % 10), null));
    }

    [Function(WorkflowActivityNames.RecordBatchRun)]
    public async Task RecordBatchRun([ActivityTrigger] BatchSummary summary, FunctionContext context)
    {
        ArgumentNullException.ThrowIfNull(summary);
        ArgumentNullException.ThrowIfNull(context);
        await store.UpsertBatchRunAsync(summary, context.CancellationToken).ConfigureAwait(false);
    }

    [Function(WorkflowActivityNames.EnqueueBatchItems)]
    public Task EnqueueBatchItems([ActivityTrigger] EnqueueInput input, FunctionContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return batchItems.EnqueueAsync(input, context.CancellationToken);
    }

    [Function(WorkflowActivityNames.GetOrdersSince)]
    public async Task<List<OrderSnapshot>> GetOrdersSince([ActivityTrigger] DateTimeOffset since, FunctionContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return [.. await orders.GetOrdersSinceAsync(since, context.CancellationToken).ConfigureAwait(false)];
    }

    [Function(WorkflowActivityNames.GetFulfillmentRecordsSince)]
    public async Task<List<FulfillmentSnapshot>> GetFulfillmentRecordsSince([ActivityTrigger] DateTimeOffset since, FunctionContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return [.. await store.GetFulfillmentsSinceAsync(since, context.CancellationToken).ConfigureAwait(false)];
    }

    [Function(WorkflowActivityNames.RecordReconciliationRun)]
    public async Task RecordReconciliationRun([ActivityTrigger] ReconciliationSummary summary, FunctionContext context)
    {
        ArgumentNullException.ThrowIfNull(summary);
        ArgumentNullException.ThrowIfNull(context);
        await store.UpsertReconciliationRunAsync(summary, context.CancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Emits hello.workflow.completed{workflow,outcome} and hello.workflow.duration{workflow} (ms). Runs as an activity,
    /// never in orchestrator code, so orchestrator replays cannot double count. Deliberately does no I/O and cannot
    /// fail after recording, so durable activity retries do not double count either.
    /// </summary>
    [Function(WorkflowActivityNames.RecordWorkflowOutcome)]
    public void RecordWorkflowOutcome([ActivityTrigger] WorkflowOutcome outcome)
    {
        ArgumentNullException.ThrowIfNull(outcome);
        Record(metrics, outcome);
        LogOutcome(logger, outcome.Workflow, outcome.Outcome, outcome.DurationMs);
    }

    internal static void Record(HelloMetrics metrics, WorkflowOutcome outcome)
    {
        var workflow = new KeyValuePair<string, object?>("workflow", outcome.Workflow);
        metrics.WorkflowCompleted.Add(1, workflow, new KeyValuePair<string, object?>("outcome", outcome.Outcome));
        metrics.WorkflowDuration.Record(Math.Max(0, outcome.DurationMs), workflow);
    }

    [LoggerMessage(EventId = 7402, Level = LogLevel.Information, Message = "Workflow {workflow} finished: {workflow_outcome} in {duration_ms} ms")]
    private static partial void LogOutcome(ILogger logger, string workflow, string workflow_outcome, double duration_ms);

    [LoggerMessage(EventId = 7401, Level = LogLevel.Warning, Message = "Compensation: released reservation for {order_id}")]
    private static partial void LogCompensated(ILogger logger, Guid order_id);
}
