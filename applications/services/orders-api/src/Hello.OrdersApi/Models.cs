namespace Hello.OrdersApi;

public static class OrderStatus
{
    public const string Pending = "Pending";
    public const string PublishFailed = "PublishFailed";
    public const string Reserved = "Reserved";
    public const string Charged = "Charged";
    public const string Fulfilled = "Fulfilled";
    public const string Failed = "Failed";

    /// <summary>Statuses accepted by PATCH /orders/{id}/status (set by hello-durable).</summary>
    public static readonly IReadOnlyList<string> Patchable = [Reserved, Charged, Fulfilled, Failed];

    public static bool IsTerminal(string status) => status is Fulfilled or Failed;

    public static int Rank(string status) => status switch
    {
        Pending or PublishFailed => 0,
        Reserved => 1,
        Charged => 2,
        Fulfilled or Failed => 3,
        _ => -1,
    };
}

public sealed record Order(
    Guid Id,
    string Sku,
    int Quantity,
    decimal UnitPrice,
    decimal Amount,
    string Status,
    string CustomerRef,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    string? StatusReason = null,
    string? WorkflowInstanceId = null);

public sealed record CreateOrderRequest(string? Sku, int? Quantity, string? CustomerRef);

public sealed record UpdateOrderStatusRequest(string? Status, string? Reason, string? WorkflowInstanceId);

public sealed record OrderList(IReadOnlyList<Order> Items, int Count);

/// <summary>Service Bus topic `order-events` payload (snake_case on the wire).</summary>
public sealed record OrderCreatedEvent(string Event, Guid OrderId, string Sku, int Quantity, decimal Amount, DateTimeOffset CreatedAt)
{
    public const string EventName = "OrderCreated";

    public static OrderCreatedEvent From(Order order) =>
        new(EventName, order.Id, order.Sku, order.Quantity, order.Amount, order.CreatedAt);
}

public sealed record IdempotencyRecord(string Key, string RequestHash, Guid OrderId);
