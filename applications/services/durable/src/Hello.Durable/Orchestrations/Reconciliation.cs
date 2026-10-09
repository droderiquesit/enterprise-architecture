using Microsoft.Azure.Functions.Worker;
using Microsoft.DurableTask;
using Microsoft.Extensions.Logging;

namespace Hello.Durable.Orchestrations;

/// <summary>Compares orders-api orders (GET /orders?since) with SQL fulfillment records and persists a run summary.</summary>
public static partial class Reconciliation
{
    public const string Name = nameof(Reconciliation);
    private const int MaxSamples = 50;

    [Function(Name)]
    public static async Task<ReconciliationSummary> RunAsync([OrchestrationTrigger] TaskOrchestrationContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var input = context.GetInput<ReconcileInput>() ?? new ReconcileInput(new DateTimeOffset(context.CurrentUtcDateTime.AddHours(-24), TimeSpan.Zero));
        var log = context.CreateReplaySafeLogger(Name);
        var startedAt = context.CurrentUtcDateTime;

        ReconciliationSummary summary;
        try
        {
            var orders = await context.CallActivityAsync<List<OrderSnapshot>>(WorkflowActivityNames.GetOrdersSince, input.Since, OrderProcessing.DefaultRetry);
            var fulfillments = await context.CallActivityAsync<List<FulfillmentSnapshot>>(WorkflowActivityNames.GetFulfillmentRecordsSince, input.Since, OrderProcessing.DefaultRetry);
            summary = Diff(context.InstanceId, input, orders ?? [], fulfillments ?? [], new DateTimeOffset(context.CurrentUtcDateTime, TimeSpan.Zero));
            await context.CallActivityAsync(WorkflowActivityNames.RecordReconciliationRun, summary, OrderProcessing.DefaultRetry);
        }
        catch (TaskFailedException)
        {
            await OrderProcessing.RecordOutcomeAsync(context, Name, WorkflowOutcome.Failed, startedAt);
            throw;
        }

        // "succeeded" = the run completed; drift counts are in the run summary, not the outcome attribute.
        await OrderProcessing.RecordOutcomeAsync(context, Name, WorkflowOutcome.Succeeded, startedAt);
        LogDone(log, summary.RunId, summary.OrdersChecked, summary.MissingFulfillment, summary.StatusMismatch, summary.StuckOrders);
        return summary;
    }

    /// <summary>
    /// Pure diff (unit-tested):
    /// matched — terminal order with a fulfillment row in the same status;
    /// missing_fulfillment — order Fulfilled/Failed without a fulfillment row;
    /// status_mismatch — both exist but statuses differ;
    /// orphan_fulfillment — fulfillment row whose order is not in the orders window;
    /// stuck — non-terminal order older than StuckAfterMinutes with no fulfillment row.
    /// </summary>
    public static ReconciliationSummary Diff(string runId, ReconcileInput input, IReadOnlyList<OrderSnapshot> orders, IReadOnlyList<FulfillmentSnapshot> fulfillments, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(orders);
        ArgumentNullException.ThrowIfNull(fulfillments);
        var byOrder = fulfillments.GroupBy(f => f.OrderId).ToDictionary(g => g.Key, g => g.OrderByDescending(f => f.UpdatedAt).First());
        var orderIds = orders.Select(o => o.Id).ToHashSet();
        int matched = 0, missing = 0, mismatch = 0, stuck = 0;
        var samples = new List<string>();

        foreach (var order in orders)
        {
            var terminal = order.Status is "Fulfilled" or "Failed";
            if (byOrder.TryGetValue(order.Id, out var f))
            {
                if (string.Equals(f.Status, order.Status, StringComparison.Ordinal))
                {
                    matched++;
                }
                else if (terminal || f.Status is "Fulfilled" or "Failed")
                {
                    mismatch++;
                    AddSample(samples, $"status_mismatch:{order.Id:D}:{order.Status}/{f.Status}");
                }
            }
            else if (terminal)
            {
                missing++;
                AddSample(samples, $"missing_fulfillment:{order.Id:D}");
            }
            else if (now - order.CreatedAt > TimeSpan.FromMinutes(input.StuckAfterMinutes))
            {
                stuck++;
                AddSample(samples, $"stuck:{order.Id:D}:{order.Status}");
            }
        }

        var orphans = byOrder.Keys.Count(id => !orderIds.Contains(id));
        foreach (var id in byOrder.Keys.Where(id => !orderIds.Contains(id)))
        {
            AddSample(samples, $"orphan_fulfillment:{id:D}");
        }

        return new ReconciliationSummary(runId, input.Since, now, orders.Count, fulfillments.Count, matched, missing, mismatch, orphans, stuck, samples);
    }

    private static void AddSample(List<string> samples, string value)
    {
        if (samples.Count < MaxSamples)
        {
            samples.Add(value);
        }
    }

    [LoggerMessage(EventId = 7201, Level = LogLevel.Information, Message = "Reconciliation {run_id}: {orders_checked} orders, {missing_fulfillment} missing, {status_mismatch} mismatched, {stuck_orders} stuck")]
    private static partial void LogDone(ILogger logger, string run_id, int orders_checked, int missing_fulfillment, int status_mismatch, int stuck_orders);
}
