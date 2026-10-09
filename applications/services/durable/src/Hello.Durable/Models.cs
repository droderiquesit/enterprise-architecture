namespace Hello.Durable;

/// <summary>Input of the OrderProcessing orchestration (built by the Service Bus starter; settings captured here so the orchestrator stays deterministic).</summary>
public sealed record OrderWorkflowInput(
    Guid OrderId,
    string Sku,
    int Quantity,
    decimal Amount,
    DateTimeOffset CreatedAt,
    int PaymentTimeoutSeconds = 10);

public sealed record OrderWorkflowResult(Guid OrderId, string Status, string? Reason, string? PaymentId, IReadOnlyList<string> Steps);

public static class WorkflowStatus
{
    public const string Fulfilled = "Fulfilled";
    public const string Failed = "Failed";
}

public sealed record ReserveInput(Guid OrderId, string Sku, int Quantity);

public sealed record ReserveResult(bool Reserved, string Status, bool Simulated);

public sealed record ReleaseInput(Guid OrderId, string Sku);

public sealed record ChargeInput(Guid OrderId, decimal Amount);

public sealed record PaymentResult(string PaymentId, string Status)
{
    public bool Approved => string.Equals(Status, "approved", StringComparison.OrdinalIgnoreCase);
}

public sealed record StatusUpdateInput(Guid OrderId, string Status, string? Reason, string WorkflowInstanceId);

public sealed record FulfillmentRecord(
    Guid OrderId,
    string Sku,
    int Quantity,
    decimal Amount,
    string Status,
    string? Reason,
    string? PaymentId,
    string WorkflowInstanceId,
    DateTimeOffset CompletedAt);

public sealed record BatchInput(int Items, bool Enqueue);

public sealed record ItemInput(string BatchId, int Index);

public sealed record ItemResult(int Index, bool Succeeded, decimal Value, string? Error);

public sealed record BatchSummary(
    string BatchId,
    int Items,
    int Succeeded,
    int Failed,
    decimal TotalValue,
    DateTimeOffset StartedAt,
    DateTimeOffset CompletedAt);

public sealed record EnqueueInput(string BatchId, IReadOnlyList<string> ItemIds);

public sealed record ReconcileInput(DateTimeOffset Since, int StuckAfterMinutes = 30);

/// <summary>Order as seen by orders-api (subset).</summary>
public sealed record OrderSnapshot(Guid Id, string Status, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt);

/// <summary>Fulfillment row as stored in SQL fulfillment.fulfillments (subset).</summary>
public sealed record FulfillmentSnapshot(Guid OrderId, string Status, DateTimeOffset UpdatedAt);

public sealed record ReconciliationSummary(
    string RunId,
    DateTimeOffset Since,
    DateTimeOffset CompletedAt,
    int OrdersChecked,
    int FulfillmentsChecked,
    int Matched,
    int MissingFulfillment,
    int StatusMismatch,
    int OrphanFulfillment,
    int StuckOrders,
    IReadOnlyList<string> Samples);
