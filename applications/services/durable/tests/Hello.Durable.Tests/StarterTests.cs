using System.Diagnostics;
using Hello.Common.Telemetry;
using Hello.Durable.Triggers;
using Microsoft.DurableTask;
using Microsoft.DurableTask.Client;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;

namespace Hello.Durable.Tests;

internal sealed class FakeDurableClient() : DurableTaskClient("fake")
{
    public Dictionary<string, (TaskName Name, object? Input)> Scheduled { get; } = [];

    public override Task<string> ScheduleNewOrchestrationInstanceAsync(TaskName orchestratorName, object? input = null, StartOrchestrationOptions? options = null, CancellationToken cancellation = default)
    {
        var id = options?.InstanceId ?? Guid.NewGuid().ToString();
        if (Scheduled.ContainsKey(id))
        {
            throw new InvalidOperationException("already exists");
        }

        Scheduled[id] = (orchestratorName, input);
        return Task.FromResult(id);
    }

    public override Task<OrchestrationMetadata?> GetInstancesAsync(string instanceId, bool getInputsAndOutputs = false, CancellationToken cancellation = default) =>
        Task.FromResult(Scheduled.ContainsKey(instanceId) ? new OrchestrationMetadata("OrderProcessing", instanceId) : null);

    public override AsyncPageable<OrchestrationMetadata> GetAllInstancesAsync(OrchestrationQuery? filter = null) => throw new NotSupportedException();

    public override Task RaiseEventAsync(string instanceId, string eventName, object? eventPayload = null, CancellationToken cancellation = default) => throw new NotSupportedException();

    public override Task<OrchestrationMetadata> WaitForInstanceStartAsync(string instanceId, bool getInputsAndOutputs = false, CancellationToken cancellation = default) => throw new NotSupportedException();

    public override Task<OrchestrationMetadata> WaitForInstanceCompletionAsync(string instanceId, bool getInputsAndOutputs = false, CancellationToken cancellation = default) => throw new NotSupportedException();

    public override Task SuspendInstanceAsync(string instanceId, string? reason = null, CancellationToken cancellation = default) => throw new NotSupportedException();

    public override Task ResumeInstanceAsync(string instanceId, string? reason = null, CancellationToken cancellation = default) => throw new NotSupportedException();

    public override ValueTask DisposeAsync() => ValueTask.CompletedTask;
}

public sealed class StarterTests
{
    private const string ProducerTraceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";

    private static OrderEventStarter Starter() =>
        new(DurableSettings.From(new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["PAYMENT_TIMEOUT_SECONDS"] = "12" }).Build()), NullLogger<OrderEventStarter>.Instance);

    private static string Body(Guid id) =>
        $$"""{"event":"OrderCreated","order_id":"{{id}}","sku":"SKU-0004","quantity":3,"amount":37.50,"created_at":"2026-10-09T12:00:00Z"}""";

    [Fact]
    public async Task StartsOrchestration_WithDeterministicInstanceId_AndSkipsDuplicates()
    {
        var client = new FakeDurableClient();
        var id = Guid.NewGuid();
        var props = new Dictionary<string, object> { ["traceparent"] = ProducerTraceparent };

        var started = await Starter().StartAsync(client, Body(id), props, id.ToString(), TestContext.Current.CancellationToken);
        Assert.Equal($"order-{id:D}", started);
        var (name, input) = client.Scheduled[started!];
        Assert.Equal("OrderProcessing", name.Name);
        var workflowInput = Assert.IsType<OrderWorkflowInput>(input);
        Assert.Equal(3, workflowInput.Quantity);
        Assert.Equal(37.50m, workflowInput.Amount);
        Assert.Equal(12, workflowInput.PaymentTimeoutSeconds);

        var duplicate = await Starter().StartAsync(client, Body(id), props, id.ToString(), TestContext.Current.CancellationToken);
        Assert.Null(duplicate);
        Assert.Single(client.Scheduled);
    }

    [Fact]
    public async Task InvalidPayload_IsIgnored()
    {
        var client = new FakeDurableClient();
        Assert.Null(await Starter().StartAsync(client, "{not json", new Dictionary<string, object>(), "m1", TestContext.Current.CancellationToken));
        Assert.Null(await Starter().StartAsync(client, """{"event":"Other","order_id":"00000000-0000-0000-0000-000000000001","sku":"x"}""", new Dictionary<string, object>(), "m2", TestContext.Current.CancellationToken));
        Assert.Empty(client.Scheduled);
    }

    [Fact]
    public void ConsumerSpan_LinksToProducer_NotParent()
    {
        using var listener = new ActivityListener
        {
            ShouldListenTo = s => s.Name == HelloTelemetry.ActivitySourceName,
            Sample = (ref ActivityCreationOptions<ActivityContext> _) => ActivitySamplingResult.AllDataAndRecorded,
        };
        ActivitySource.AddActivityListener(listener);

        using var invocation = new Activity("function-invocation").Start();
        using var consumer = OrderEventStarter.StartConsumerActivity(ProducerTraceparent, "dd=s:1", "msg-1");

        Assert.NotNull(consumer);
        Assert.Equal(ActivityKind.Consumer, consumer.Kind);
        Assert.Equal(invocation.TraceId, consumer.TraceId); // parent = current invocation span
        Assert.NotEqual("4bf92f3577b34da6a3ce929d0e0e4736", consumer.TraceId.ToHexString());
        var link = Assert.Single(consumer.Links);
        Assert.Equal("4bf92f3577b34da6a3ce929d0e0e4736", link.Context.TraceId.ToHexString());
        Assert.Equal("00f067aa0ba902b7", link.Context.SpanId.ToHexString());
        Assert.Equal("dd=s:1", link.Context.TraceState);
    }
}
