namespace Hello.Durable.Services;

/// <summary>hello-inventory-api reserve/release (simulated when INVENTORY_API_URL is unset).</summary>
public interface IInventoryService
{
    Task<ReserveResult> ReserveAsync(ReserveInput input, CancellationToken cancellationToken);

    Task ReleaseAsync(ReleaseInput input, CancellationToken cancellationToken);
}

/// <summary>hello-partner-sim POST /payments (simulated approval when PARTNER_API_URL is unset).</summary>
public interface IPaymentService
{
    Task<PaymentResult> ChargeAsync(ChargeInput input, CancellationToken cancellationToken);
}

/// <summary>hello-orders-api PATCH /orders/{id}/status and GET /orders?since.</summary>
public interface IOrdersService
{
    Task UpdateStatusAsync(StatusUpdateInput input, CancellationToken cancellationToken);

    Task<IReadOnlyList<OrderSnapshot>> GetOrdersSinceAsync(DateTimeOffset since, CancellationToken cancellationToken);
}

/// <summary>Owned data boundary: SQL schema `fulfillment` (separate from the Durable runtime storage).</summary>
public interface IFulfillmentStore
{
    Task UpsertFulfillmentAsync(FulfillmentRecord record, CancellationToken cancellationToken);

    Task<IReadOnlyList<FulfillmentSnapshot>> GetFulfillmentsSinceAsync(DateTimeOffset since, CancellationToken cancellationToken);

    Task UpsertBatchRunAsync(BatchSummary summary, CancellationToken cancellationToken);

    Task UpsertReconciliationRunAsync(ReconciliationSummary summary, CancellationToken cancellationToken);
}

/// <summary>Service Bus queue `batch-items` (logged only when Service Bus is not configured).</summary>
public interface IBatchItemPublisher
{
    Task EnqueueAsync(EnqueueInput input, CancellationToken cancellationToken);
}
