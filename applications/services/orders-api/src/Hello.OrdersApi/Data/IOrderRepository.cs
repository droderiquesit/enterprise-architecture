namespace Hello.OrdersApi.Data;

public enum CreateOutcome
{
    Created,
    Replayed,
    KeyConflict,
}

public sealed record CreateResult(CreateOutcome Outcome, Order? Order);

/// <summary>Owned data boundary: Azure SQL database `orders`, schema `orders`.</summary>
public interface IOrderRepository
{
    /// <summary>Atomically stores the idempotency record and the order. Concurrent duplicates resolve to Replayed/KeyConflict.</summary>
    Task<CreateResult> CreateAsync(Order order, string idempotencyKey, string requestHash, CancellationToken cancellationToken);

    Task<IdempotencyRecord?> FindIdempotencyAsync(string idempotencyKey, CancellationToken cancellationToken);

    Task<Order?> GetAsync(Guid id, CancellationToken cancellationToken);

    Task<IReadOnlyList<Order>> ListAsync(int limit, DateTimeOffset? since, CancellationToken cancellationToken);

    /// <summary>Compare-and-set status update; returns null when the row changed concurrently or does not exist.</summary>
    Task<Order?> UpdateStatusAsync(Guid id, string expectedStatus, string newStatus, string? reason, string? workflowInstanceId, DateTimeOffset now, CancellationToken cancellationToken);

    Task PingAsync(CancellationToken cancellationToken);
}
