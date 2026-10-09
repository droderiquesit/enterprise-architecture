using System.Diagnostics.Metrics;

namespace Hello.Common.Telemetry;

/// <summary>
/// Application metrics. Attributes are bounded enumerations only — never order ids, customer refs or user ids.
/// </summary>
public sealed class HelloMetrics : IDisposable
{
    public const string MeterName = "Hello.App";

    private static readonly double[] DurationBuckets =
        [0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1, 2.5, 5, 7.5, 10];

    private readonly Meter _meter;

    public HelloMetrics(IMeterFactory meterFactory, HelloServiceInfo info)
    {
        ArgumentNullException.ThrowIfNull(meterFactory);
        ArgumentNullException.ThrowIfNull(info);
        _meter = meterFactory.Create(new MeterOptions(MeterName) { Version = info.Version });

        OrdersCreated = _meter.CreateCounter<long>(
            "hello.orders.created", "{order}", "Orders accepted by hello-orders-api (attribute order.status).");
        OrdersPublishFailed = _meter.CreateCounter<long>(
            "hello.orders.publish_failures", "{message}", "OrderCreated events that could not be published.");
        OrderStatusTransitions = _meter.CreateCounter<long>(
            "hello.orders.status_transitions", "{transition}", "Order status updates (attribute order.status).");
        DependencyDuration = _meter.CreateHistogram(
            "hello.http.dependency.duration",
            "s",
            "Duration of outbound HTTP calls per logical dependency (including retries).",
            advice: new InstrumentAdvice<double> { HistogramBucketBoundaries = DurationBuckets });
        InventoryReservations = _meter.CreateCounter<long>(
            "hello.inventory.reservations", "{reservation}", "Reservation outcomes (attribute result).");
        WorkflowsCompleted = _meter.CreateCounter<long>(
            "hello.workflows.completed", "{workflow}", "Durable workflow outcomes (attributes workflow, outcome).");
        FaultsInjected = _meter.CreateCounter<long>(
            "hello.faults.injected", "{fault}", "Injected lab faults (attribute fault.type).");
        IdempotentReplays = _meter.CreateCounter<long>(
            "hello.idempotency.replays", "{request}", "Requests answered from an idempotency record.");
    }

    public Counter<long> OrdersCreated { get; }

    public Counter<long> OrdersPublishFailed { get; }

    public Counter<long> OrderStatusTransitions { get; }

    public Histogram<double> DependencyDuration { get; }

    public Counter<long> InventoryReservations { get; }

    public Counter<long> WorkflowsCompleted { get; }

    public Counter<long> FaultsInjected { get; }

    public Counter<long> IdempotentReplays { get; }

    public void Dispose() => _meter.Dispose();
}
