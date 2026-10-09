using Hello.Durable.Orchestrations;
using Microsoft.DurableTask;

namespace Hello.Durable.Tests;

public sealed class OrderProcessingTests
{
    private static readonly Guid OrderId = Guid.Parse("11111111-2222-3333-4444-555555555555");

    private static OrderWorkflowInput Input(int timeout = 10) =>
        new(OrderId, "SKU-0001", 2, 25.00m, new DateTimeOffset(2026, 10, 9, 11, 59, 0, TimeSpan.Zero), timeout);

    private static FakeOrchestrationContext HappyContext() => new FakeOrchestrationContext(Input(), "order-" + OrderId)
        .On(WorkflowActivityNames.ReserveInventory, _ => new ReserveResult(true, "reserved", false))
        .On(WorkflowActivityNames.ChargePayment, _ => new PaymentResult("pay-1", "approved"))
        .On(WorkflowActivityNames.UpdateOrderStatus, _ => null)
        .On(WorkflowActivityNames.RecordFulfillment, _ => null)
        .On(WorkflowActivityNames.ReleaseInventory, _ => null);

    private static List<string> Statuses(FakeOrchestrationContext ctx) =>
        [.. ctx.Calls.Where(c => c.Name == WorkflowActivityNames.UpdateOrderStatus).Select(c => ((StatusUpdateInput)c.Input!).Status)];

    [Fact]
    public async Task HappyPath_ReservesChargesRecordsAndFulfills()
    {
        var ctx = HappyContext();
        var result = await OrderProcessing.RunAsync(ctx);

        Assert.Equal(WorkflowStatus.Fulfilled, result.Status);
        Assert.Equal("pay-1", result.PaymentId);
        Assert.Equal(["Reserved", "Charged", "Fulfilled"], Statuses(ctx));
        var record = (FulfillmentRecord)ctx.Calls.Single(c => c.Name == WorkflowActivityNames.RecordFulfillment).Input!;
        Assert.Equal(WorkflowStatus.Fulfilled, record.Status);
        Assert.Equal("order-" + OrderId, record.WorkflowInstanceId);
        Assert.Equal(ctx.Now, record.CompletedAt.UtcDateTime); // deterministic time from the context
        Assert.Equal(0, ctx.CallCount(WorkflowActivityNames.ReleaseInventory));
        // Ordering: ReserveInventory -> ChargePayment -> RecordFulfillment -> final UpdateOrderStatus
        var names = ctx.Calls.Select(c => c.Name).ToList();
        Assert.True(names.IndexOf(WorkflowActivityNames.ReserveInventory) < names.IndexOf(WorkflowActivityNames.ChargePayment));
        Assert.True(names.IndexOf(WorkflowActivityNames.ChargePayment) < names.IndexOf(WorkflowActivityNames.RecordFulfillment));
        Assert.Equal(WorkflowActivityNames.UpdateOrderStatus, names[^1]);
    }

    [Fact]
    public async Task PaymentDeclined_CompensatesAndFails()
    {
        var ctx = HappyContext().On(WorkflowActivityNames.ChargePayment, _ => new PaymentResult("pay-2", "declined"));
        var result = await OrderProcessing.RunAsync(ctx);

        Assert.Equal(WorkflowStatus.Failed, result.Status);
        Assert.Equal("payment_declined", result.Reason);
        Assert.Equal(1, ctx.CallCount(WorkflowActivityNames.ReleaseInventory));
        Assert.Equal(["Reserved", "Failed"], Statuses(ctx));
        var failed = (StatusUpdateInput)ctx.Calls.Last(c => c.Name == WorkflowActivityNames.UpdateOrderStatus).Input!;
        Assert.Equal("payment_declined", failed.Reason);
        var record = (FulfillmentRecord)ctx.Calls.Single(c => c.Name == WorkflowActivityNames.RecordFulfillment).Input!;
        Assert.Equal(WorkflowStatus.Failed, record.Status);
    }

    [Fact]
    public async Task PaymentErrors_AfterRetriesExhausted_CompensatesAndFails()
    {
        var ctx = HappyContext().On(WorkflowActivityNames.ChargePayment, (_, _) => throw new HttpRequestException("partner 503"));
        var result = await OrderProcessing.RunAsync(ctx);

        Assert.Equal(WorkflowStatus.Failed, result.Status);
        Assert.Equal("payment_error", result.Reason);
        Assert.Equal(3, ctx.Attempts[WorkflowActivityNames.ChargePayment]); // RetryPolicy: 3 attempts
        Assert.Equal(1, ctx.CallCount(WorkflowActivityNames.ReleaseInventory));
        Assert.Contains("Failed", Statuses(ctx));
    }

    [Fact]
    public async Task PaymentRetry_ThenSuccess_Fulfills()
    {
        var ctx = HappyContext().On(WorkflowActivityNames.ChargePayment, (_, attempt) =>
            attempt < 3 ? throw new HttpRequestException("transient") : Task.FromResult<object?>(new PaymentResult("pay-3", "approved")));
        var result = await OrderProcessing.RunAsync(ctx);

        Assert.Equal(WorkflowStatus.Fulfilled, result.Status);
        Assert.Equal(3, ctx.Attempts[WorkflowActivityNames.ChargePayment]);
        Assert.Equal(0, ctx.CallCount(WorkflowActivityNames.ReleaseInventory));
        Assert.Equal(3, OrderProcessing.PaymentRetry.Retry!.Policy!.MaxNumberOfAttempts);
    }

    [Fact]
    public async Task PaymentTimeout_TimerWins_CompensatesAndFails()
    {
        var never = new TaskCompletionSource<object?>();
        var ctx = HappyContext().On(WorkflowActivityNames.ChargePayment, (_, _) => never.Task);
        ctx.TimersFireImmediately = true;
        var result = await OrderProcessing.RunAsync(ctx);

        Assert.Equal(WorkflowStatus.Failed, result.Status);
        Assert.Equal("payment_timeout", result.Reason);
        Assert.Equal(1, ctx.CallCount(WorkflowActivityNames.ReleaseInventory));
        Assert.Equal(["Reserved", "Failed"], Statuses(ctx));
    }

    [Fact]
    public async Task InsufficientInventory_FailsWithoutCompensation()
    {
        var ctx = HappyContext().On(WorkflowActivityNames.ReserveInventory, _ => new ReserveResult(false, "insufficient", false));
        var result = await OrderProcessing.RunAsync(ctx);

        Assert.Equal(WorkflowStatus.Failed, result.Status);
        Assert.Equal("inventory_insufficient", result.Reason);
        Assert.Equal(0, ctx.CallCount(WorkflowActivityNames.ChargePayment));
        Assert.Equal(0, ctx.CallCount(WorkflowActivityNames.ReleaseInventory));
        Assert.Equal(["Failed"], Statuses(ctx));
    }

    [Fact]
    public async Task ReserveActivityFailure_FailsGracefully()
    {
        var ctx = HappyContext().On(WorkflowActivityNames.ReserveInventory, (_, _) => throw new InvalidOperationException("boom"));
        var result = await OrderProcessing.RunAsync(ctx);
        Assert.Equal(WorkflowStatus.Failed, result.Status);
        Assert.Equal("activity_failed:ReserveInventory", result.Reason);
        Assert.Equal(3, ctx.Attempts[WorkflowActivityNames.ReserveInventory]);
        Assert.Equal(0, ctx.CallCount(WorkflowActivityNames.ReleaseInventory));
    }
}

public sealed class BatchProcessingTests
{
    [Fact]
    public async Task FanOutFanIn_AggregatesResults_AndRecordsRun()
    {
        var ctx = new FakeOrchestrationContext(new BatchInput(10, Enqueue: true), "batch-1")
            .On(WorkflowActivityNames.ProcessItem, i =>
            {
                var item = (ItemInput)i!;
                return item.Index == 7 ? throw new InvalidOperationException("bad item") : new ItemResult(item.Index, true, 2m, null);
            })
            .On(WorkflowActivityNames.RecordBatchRun, _ => null)
            .On(WorkflowActivityNames.EnqueueBatchItems, _ => null);

        var summary = await BatchProcessing.RunAsync(ctx);

        Assert.Equal("batch-1", summary.BatchId);
        Assert.Equal(10, summary.Items);
        Assert.Equal(9, summary.Succeeded);
        Assert.Equal(1, summary.Failed);
        Assert.Equal(18m, summary.TotalValue);
        Assert.Equal(10 + 2, ctx.Calls.Count(c => c.Name == WorkflowActivityNames.ProcessItem)); // item 7 retried 3x
        var recorded = (BatchSummary)ctx.Calls.Single(c => c.Name == WorkflowActivityNames.RecordBatchRun).Input!;
        Assert.Equal(summary, recorded);
        var enqueued = (EnqueueInput)ctx.Calls.Single(c => c.Name == WorkflowActivityNames.EnqueueBatchItems).Input!;
        Assert.Equal(9, enqueued.ItemIds.Count);
        Assert.DoesNotContain("batch-1:7", enqueued.ItemIds);
    }

    [Fact]
    public async Task ItemCount_IsCappedAt50()
    {
        var ctx = new FakeOrchestrationContext(new BatchInput(500, false), "batch-2")
            .On(WorkflowActivityNames.ProcessItem, i => new ItemResult(((ItemInput)i!).Index, true, 1m, null));
        var summary = await BatchProcessing.RunAsync(ctx);
        Assert.Equal(50, summary.Items);
        Assert.Equal(0, ctx.CallCount(WorkflowActivityNames.EnqueueBatchItems));
    }
}

public sealed class ReconciliationTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 9, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Diff_ClassifiesDrift()
    {
        Guid ok = Guid.NewGuid(), missing = Guid.NewGuid(), mismatch = Guid.NewGuid(), stuck = Guid.NewGuid(), fresh = Guid.NewGuid(), orphan = Guid.NewGuid();
        var orders = new List<OrderSnapshot>
        {
            new(ok, "Fulfilled", Now.AddHours(-2), Now.AddHours(-2)),
            new(missing, "Failed", Now.AddHours(-2), Now.AddHours(-2)),
            new(mismatch, "Charged", Now.AddHours(-2), Now.AddHours(-2)),
            new(stuck, "Pending", Now.AddHours(-3), Now.AddHours(-3)),
            new(fresh, "Pending", Now.AddMinutes(-1), Now.AddMinutes(-1)),
        };
        var fulfillments = new List<FulfillmentSnapshot>
        {
            new(ok, "Fulfilled", Now.AddHours(-2)),
            new(mismatch, "Fulfilled", Now.AddHours(-2)),
            new(orphan, "Fulfilled", Now.AddHours(-1)),
        };

        var s = Reconciliation.Diff("run-1", new ReconcileInput(Now.AddDays(-1)), orders, fulfillments, Now);

        Assert.Equal(5, s.OrdersChecked);
        Assert.Equal(3, s.FulfillmentsChecked);
        Assert.Equal(1, s.Matched);
        Assert.Equal(1, s.MissingFulfillment);
        Assert.Equal(1, s.StatusMismatch);
        Assert.Equal(1, s.OrphanFulfillment);
        Assert.Equal(1, s.StuckOrders);
        Assert.Contains($"missing_fulfillment:{missing:D}", s.Samples);
        Assert.Contains($"stuck:{stuck:D}:Pending", s.Samples);
    }

    [Fact]
    public async Task Orchestrator_PersistsSummary()
    {
        var since = Now.AddHours(-24);
        var id = Guid.NewGuid();
        var ctx = new FakeOrchestrationContext(new ReconcileInput(since), "reconcile-1")
            .On(WorkflowActivityNames.GetOrdersSince, s => new List<OrderSnapshot> { new(id, "Fulfilled", Now, Now) })
            .On(WorkflowActivityNames.GetFulfillmentRecordsSince, s => new List<FulfillmentSnapshot>())
            .On(WorkflowActivityNames.RecordReconciliationRun, _ => null);

        var summary = await Reconciliation.RunAsync(ctx);

        Assert.Equal(1, summary.MissingFulfillment);
        Assert.Equal(since, (DateTimeOffset)ctx.Calls.First(c => c.Name == WorkflowActivityNames.GetOrdersSince).Input!);
        Assert.Same(summary, ctx.Calls.Single(c => c.Name == WorkflowActivityNames.RecordReconciliationRun).Input);
    }
}
