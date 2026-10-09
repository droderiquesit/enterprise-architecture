using Hello.Common.Faults;
using Hello.Common.Idempotency;
using Hello.Common.Problems;
using Hello.Common.Telemetry;
using Hello.OrdersApi.Catalog;
using Hello.OrdersApi.Data;
using Hello.OrdersApi.Messaging;

namespace Hello.OrdersApi;

public sealed record CreateOrderOutcome(Order Order, bool Replayed);

/// <summary>Order use cases: create (idempotent), status transitions, republish.</summary>
public sealed partial class OrderService(
    IOrderRepository repository,
    ICatalogClient catalog,
    IOrderEventPublisher publisher,
    FaultState faults,
    HelloMetrics metrics,
    TimeProvider time,
    ILogger<OrderService> logger)
{
    public async Task<CreateOrderOutcome> CreateAsync(CreateOrderRequest request, string idempotencyKey, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var sku = request.Sku!.Trim();
        var customerRef = request.CustomerRef!.Trim();
        var quantity = request.Quantity!.Value;
        var hash = IdempotencyKey.Fingerprint($"{sku}\n{quantity}\n{customerRef}");

        faults.ThrowIfInjected(FaultTypes.DbError);
        var existing = await repository.FindIdempotencyAsync(idempotencyKey, cancellationToken).ConfigureAwait(false);
        if (existing is not null)
        {
            return await ReplayAsync(existing, hash, cancellationToken).ConfigureAwait(false);
        }

        var unitPrice = await catalog.GetUnitPriceAsync(sku, cancellationToken).ConfigureAwait(false);
        var now = time.GetUtcNow();
        var order = new Order(Guid.NewGuid(), sku, quantity, unitPrice, unitPrice * quantity, OrderStatus.Pending, customerRef, now, now);

        var result = await repository.CreateAsync(order, idempotencyKey, hash, cancellationToken).ConfigureAwait(false);
        switch (result.Outcome)
        {
            case CreateOutcome.KeyConflict:
                throw KeyConflict();
            case CreateOutcome.Replayed:
                metrics.IdempotentReplays.Add(1);
                return new CreateOrderOutcome(result.Order!, true);
        }

        LogCreated(logger, order.Id, order.Sku, order.Quantity, order.Amount);
        var published = await TryPublishAsync(order, cancellationToken).ConfigureAwait(false);
        metrics.OrdersCreated.Add(1, new KeyValuePair<string, object?>("order.status", published.Status));
        return new CreateOrderOutcome(published, false);
    }

    public async Task<Order> RepublishAsync(Guid id, CancellationToken cancellationToken)
    {
        faults.ThrowIfInjected(FaultTypes.DbError);
        var order = await repository.GetAsync(id, cancellationToken).ConfigureAwait(false)
            ?? throw new HelloProblemException(StatusCodes.Status404NotFound, "order-not-found", "Order not found");
        if (order.Status is not (OrderStatus.PublishFailed or OrderStatus.Pending))
        {
            throw new HelloProblemException(StatusCodes.Status409Conflict, "invalid-state", "Order already processed", $"Order is {order.Status}; only Pending/PublishFailed orders can be republished.");
        }

        return await TryPublishAsync(order, cancellationToken).ConfigureAwait(false);
    }

    public async Task<Order> UpdateStatusAsync(Guid id, UpdateOrderStatusRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        faults.ThrowIfInjected(FaultTypes.DbError);
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var current = await repository.GetAsync(id, cancellationToken).ConfigureAwait(false)
                ?? throw new HelloProblemException(StatusCodes.Status404NotFound, "order-not-found", "Order not found");
            var target = request.Status!;
            if (current.Status == target)
            {
                return current; // idempotent replay from a retried activity
            }

            if (OrderStatus.IsTerminal(current.Status) || OrderStatus.Rank(target) < OrderStatus.Rank(current.Status))
            {
                throw new HelloProblemException(StatusCodes.Status409Conflict, "invalid-transition", "Invalid status transition", $"{current.Status} -> {target} is not allowed.");
            }

            var updated = await repository.UpdateStatusAsync(id, current.Status, target, request.Reason, request.WorkflowInstanceId, time.GetUtcNow(), cancellationToken).ConfigureAwait(false);
            if (updated is not null)
            {
                metrics.OrderStatusTransitions.Add(1, new KeyValuePair<string, object?>("order.status", target));
                LogStatus(logger, id, current.Status, target, request.WorkflowInstanceId);
                return updated;
            }
        }

        throw new HelloProblemException(StatusCodes.Status409Conflict, "concurrent-update", "Concurrent update", "The order changed concurrently; retry.");
    }

    private async Task<CreateOrderOutcome> ReplayAsync(IdempotencyRecord existing, string hash, CancellationToken cancellationToken)
    {
        if (existing.RequestHash != hash)
        {
            throw KeyConflict();
        }

        var order = await repository.GetAsync(existing.OrderId, cancellationToken).ConfigureAwait(false)
            ?? throw new HelloProblemException(StatusCodes.Status409Conflict, "idempotency-in-progress", "Request in progress", "Retry later.");
        metrics.IdempotentReplays.Add(1);
        return new CreateOrderOutcome(order, true);
    }

    private async Task<Order> TryPublishAsync(Order order, CancellationToken cancellationToken)
    {
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            cts.CancelAfter(TimeSpan.FromSeconds(15));
            await publisher.PublishAsync(OrderCreatedEvent.From(order), cts.Token).ConfigureAwait(false);
            if (order.Status == OrderStatus.PublishFailed)
            {
                return await repository.UpdateStatusAsync(order.Id, OrderStatus.PublishFailed, OrderStatus.Pending, "republished", null, time.GetUtcNow(), cancellationToken).ConfigureAwait(false) ?? order;
            }

            return order;
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            metrics.OrdersPublishFailed.Add(1);
            LogPublishFailed(logger, ex, order.Id);
            if (order.Status == OrderStatus.PublishFailed)
            {
                return order;
            }

            return await repository.UpdateStatusAsync(order.Id, order.Status, OrderStatus.PublishFailed, "event publish failed", null, time.GetUtcNow(), cancellationToken).ConfigureAwait(false)
                ?? order with { Status = OrderStatus.PublishFailed };
        }
    }

    private static HelloProblemException KeyConflict() =>
        new(StatusCodes.Status409Conflict, "idempotency-key-reused", "Idempotency-Key reused", "The Idempotency-Key was already used with a different request body.");

    [LoggerMessage(EventId = 1001, Level = LogLevel.Information, Message = "Order {order_id} created sku={sku} quantity={quantity} amount={amount}")]
    private static partial void LogCreated(ILogger logger, Guid order_id, string sku, int quantity, decimal amount);

    [LoggerMessage(EventId = 1002, Level = LogLevel.Information, Message = "Order {order_id} status {from_status} -> {to_status} (workflow {workflow_instance_id})")]
    private static partial void LogStatus(ILogger logger, Guid order_id, string from_status, string to_status, string? workflow_instance_id);

    [LoggerMessage(EventId = 1003, Level = LogLevel.Error, Message = "Publishing OrderCreated failed for {order_id}; status PublishFailed (retry via POST /orders/{order_id}/republish)")]
    private static partial void LogPublishFailed(ILogger logger, Exception ex, Guid order_id);
}
