using System.Collections.Concurrent;

namespace Hello.OrdersApi.Data;

/// <summary>STORAGE_MODE=memory — for tests and local runs without SQL.</summary>
public sealed class InMemoryOrderRepository : IOrderRepository
{
    private readonly ConcurrentDictionary<Guid, Order> _orders = new();
    private readonly ConcurrentDictionary<string, IdempotencyRecord> _keys = new(StringComparer.Ordinal);
    private readonly Lock _gate = new();

    public Task<CreateResult> CreateAsync(Order order, string idempotencyKey, string requestHash, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(order);
        lock (_gate)
        {
            if (_keys.TryGetValue(idempotencyKey, out var existing))
            {
                return Task.FromResult(existing.RequestHash == requestHash
                    ? new CreateResult(CreateOutcome.Replayed, _orders[existing.OrderId])
                    : new CreateResult(CreateOutcome.KeyConflict, null));
            }

            _keys[idempotencyKey] = new IdempotencyRecord(idempotencyKey, requestHash, order.Id);
            _orders[order.Id] = order;
            return Task.FromResult(new CreateResult(CreateOutcome.Created, order));
        }
    }

    public Task<IdempotencyRecord?> FindIdempotencyAsync(string idempotencyKey, CancellationToken cancellationToken) =>
        Task.FromResult(_keys.TryGetValue(idempotencyKey, out var r) ? r : null);

    public Task<Order?> GetAsync(Guid id, CancellationToken cancellationToken) =>
        Task.FromResult(_orders.TryGetValue(id, out var o) ? o : null);

    public Task<IReadOnlyList<Order>> ListAsync(int limit, DateTimeOffset? since, CancellationToken cancellationToken)
    {
        IReadOnlyList<Order> items = [.. _orders.Values
            .Where(o => since is null || o.CreatedAt >= since)
            .OrderByDescending(o => o.CreatedAt)
            .Take(limit)];
        return Task.FromResult(items);
    }

    public Task<Order?> UpdateStatusAsync(Guid id, string expectedStatus, string newStatus, string? reason, string? workflowInstanceId, DateTimeOffset now, CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            if (!_orders.TryGetValue(id, out var current) || current.Status != expectedStatus)
            {
                return Task.FromResult<Order?>(null);
            }

            var updated = current with
            {
                Status = newStatus,
                StatusReason = reason ?? current.StatusReason,
                WorkflowInstanceId = workflowInstanceId ?? current.WorkflowInstanceId,
                UpdatedAt = now,
            };
            _orders[id] = updated;
            return Task.FromResult<Order?>(updated);
        }
    }

    public Task PingAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
