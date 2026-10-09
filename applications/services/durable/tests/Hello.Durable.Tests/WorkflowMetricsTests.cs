using System.Diagnostics.Metrics;
using Hello.Common;
using Hello.Common.Telemetry;
using Hello.Durable.Orchestrations;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;

namespace Hello.Durable.Tests;

/// <summary>Collects hello.workflow.* measurements from the Hello.App meter.</summary>
internal sealed class WorkflowMeasurements : IDisposable
{
    private readonly MeterListener _listener = new();

    public WorkflowMeasurements()
    {
        _listener.InstrumentPublished = (instrument, l) =>
        {
            if (instrument.Meter.Name == HelloMetrics.MeterName && instrument.Name.StartsWith("hello.workflow.", StringComparison.Ordinal))
            {
                l.EnableMeasurementEvents(instrument);
            }
        };
        _listener.SetMeasurementEventCallback<long>((i, v, tags, _) => Add(i.Name, v, tags));
        _listener.SetMeasurementEventCallback<double>((i, v, tags, _) => Add(i.Name, v, tags));
        _listener.Start();
    }

    public List<(string Name, double Value, Dictionary<string, object?> Tags)> Items { get; } = [];

    public void Dispose() => _listener.Dispose();

    private void Add(string name, double value, ReadOnlySpan<KeyValuePair<string, object?>> tags)
    {
        var dict = new Dictionary<string, object?>();
        foreach (var t in tags)
        {
            dict[t.Key] = t.Value;
        }

        lock (Items)
        {
            Items.Add((name, value, dict));
        }
    }
}

public sealed class WorkflowMetricsTests
{
    private static readonly Guid OrderId = Guid.Parse("aaaaaaaa-2222-3333-4444-555555555555");

    private static FakeOrchestrationContext OrderContext() =>
        new FakeOrchestrationContext(new OrderWorkflowInput(OrderId, "SKU-0001", 1, 10m, DateTimeOffset.UnixEpoch), "order-x")
            .On(WorkflowActivityNames.ReserveInventory, _ => new ReserveResult(true, "reserved", false))
            .On(WorkflowActivityNames.ChargePayment, _ => new PaymentResult("p", "approved"));

    private static WorkflowOutcome Outcome(FakeOrchestrationContext ctx) =>
        (WorkflowOutcome)ctx.Calls.Single(c => c.Name == WorkflowActivityNames.RecordWorkflowOutcome).Input!;

    [Fact]
    public async Task OrderProcessing_Succeeded_RecordsOnceWithReplaySafeDuration()
    {
        var ctx = OrderContext();
        ctx.On(WorkflowActivityNames.ChargePayment, _ =>
        {
            ctx.Now = ctx.Now.AddMilliseconds(1500); // time advances between orchestrator steps
            return new PaymentResult("p", "approved");
        });
        await OrderProcessing.RunAsync(ctx);
        var outcome = Outcome(ctx);
        Assert.Equal(new WorkflowOutcome("OrderProcessing", "succeeded", 1500), outcome);
        Assert.Equal(1, ctx.CallCount(WorkflowActivityNames.RecordWorkflowOutcome));
    }

    [Fact]
    public async Task OrderProcessing_PaymentDeclined_IsCompensated()
    {
        var ctx = OrderContext().On(WorkflowActivityNames.ChargePayment, _ => new PaymentResult("p", "declined"));
        await OrderProcessing.RunAsync(ctx);
        Assert.Equal("compensated", Outcome(ctx).Outcome);
    }

    [Fact]
    public async Task OrderProcessing_InsufficientStock_IsFailed()
    {
        var ctx = OrderContext().On(WorkflowActivityNames.ReserveInventory, _ => new ReserveResult(false, "insufficient", false));
        await OrderProcessing.RunAsync(ctx);
        Assert.Equal("failed", Outcome(ctx).Outcome);
    }

    [Fact]
    public async Task OrderProcessing_OutcomeActivityFailure_DoesNotChangeResult()
    {
        var ctx = OrderContext().On(WorkflowActivityNames.RecordWorkflowOutcome, _ => throw new InvalidOperationException("metrics down"));
        var result = await OrderProcessing.RunAsync(ctx);
        Assert.Equal(WorkflowStatus.Fulfilled, result.Status);
    }

    [Fact]
    public async Task Batch_WithFailedItem_IsFailed_AllOk_IsSucceeded()
    {
        var failing = new FakeOrchestrationContext(new BatchInput(3, false), "b1")
            .On(WorkflowActivityNames.ProcessItem, i => ((ItemInput)i!).Index == 2 ? throw new InvalidOperationException("x") : new ItemResult(((ItemInput)i!).Index, true, 1m, null));
        await BatchProcessing.RunAsync(failing);
        Assert.Equal(new WorkflowOutcome("BatchProcessing", "failed", 0), Outcome(failing));

        var ok = new FakeOrchestrationContext(new BatchInput(3, false), "b2")
            .On(WorkflowActivityNames.ProcessItem, i => new ItemResult(((ItemInput)i!).Index, true, 1m, null));
        await BatchProcessing.RunAsync(ok);
        Assert.Equal("succeeded", Outcome(ok).Outcome);
    }

    [Fact]
    public async Task Reconciliation_Succeeded_AndFailureRecordedBeforeRethrow()
    {
        var ok = new FakeOrchestrationContext(new ReconcileInput(DateTimeOffset.UnixEpoch), "r1")
            .On(WorkflowActivityNames.GetOrdersSince, _ => new List<OrderSnapshot>())
            .On(WorkflowActivityNames.GetFulfillmentRecordsSince, _ => new List<FulfillmentSnapshot>());
        await Reconciliation.RunAsync(ok);
        Assert.Equal(new WorkflowOutcome("Reconciliation", "succeeded", 0), Outcome(ok));

        var broken = new FakeOrchestrationContext(new ReconcileInput(DateTimeOffset.UnixEpoch), "r2")
            .On(WorkflowActivityNames.GetOrdersSince, _ => throw new HttpRequestException("orders-api down"));
        await Assert.ThrowsAsync<Microsoft.DurableTask.TaskFailedException>(() => Reconciliation.RunAsync(broken));
        Assert.Equal("failed", Outcome(broken).Outcome);
    }

    [Fact]
    public async Task Orchestrators_NeverEmitMetricsThemselves_ReplayCannotDoubleCount()
    {
        using var measurements = new WorkflowMeasurements();
        // Run the same orchestration twice (as a replay would); the fake does not execute RecordWorkflowOutcome.
        await OrderProcessing.RunAsync(OrderContext());
        await OrderProcessing.RunAsync(OrderContext());
        Assert.Empty(measurements.Items);
    }

    [Fact]
    public void RecordWorkflowOutcome_Activity_EmitsCounterAndHistogram()
    {
        using var measurements = new WorkflowMeasurements();
        var services = new ServiceCollection().AddMetrics();
        using var sp = services.BuildServiceProvider();
        using var metrics = new HelloMetrics(sp.GetRequiredService<IMeterFactory>(), new HelloServiceInfo("hello-durable", "test", "1", "c", "b", "r"));
        var activities = new WorkflowActivities(null!, null!, null!, null!, null!, null!, metrics, NullLogger<WorkflowActivities>.Instance);

        activities.RecordWorkflowOutcome(new WorkflowOutcome("OrderProcessing", "compensated", 1234.5));

        var counter = Assert.Single(measurements.Items, m => m.Name == "hello.workflow.completed");
        Assert.Equal(1, counter.Value);
        Assert.Equal("OrderProcessing", counter.Tags["workflow"]);
        Assert.Equal("compensated", counter.Tags["outcome"]);
        var histogram = Assert.Single(measurements.Items, m => m.Name == "hello.workflow.duration");
        Assert.Equal(1234.5, histogram.Value);
        Assert.Equal(["workflow"], histogram.Tags.Keys);
        Assert.Equal("ms", metrics.WorkflowDuration.Unit);
    }
}
