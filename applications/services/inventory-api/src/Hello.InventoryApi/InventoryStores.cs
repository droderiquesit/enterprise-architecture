using System.Net;
using System.Text.Json;
using Hello.Common.Azure;
using Hello.Common.Faults;
using Hello.Common.Problems;
using Microsoft.Azure.Cosmos;

namespace Hello.InventoryApi;

public interface IInventoryStore
{
    Task<InventoryItem?> GetAsync(string sku, CancellationToken cancellationToken);

    Task<InventoryItem> SetQuantityAsync(string sku, int quantity, CancellationToken cancellationToken);

    /// <summary>Idempotent by order id: a second call for the same order returns the original reservation.</summary>
    Task<ReservationResult> ReserveAsync(string sku, Guid orderId, int quantity, CancellationToken cancellationToken);

    /// <summary>Compensation: returns reserved stock; idempotent.</summary>
    Task<ReservationResult> ReleaseAsync(string sku, Guid orderId, CancellationToken cancellationToken);

    Task<int> SeedAsync(CancellationToken cancellationToken);

    Task PingAsync(CancellationToken cancellationToken);
}

/// <summary>STORAGE_MODE=memory.</summary>
public sealed class InMemoryInventoryStore(TimeProvider time) : IInventoryStore
{
    private readonly Dictionary<string, InventoryItem> _items = new(StringComparer.Ordinal);
    private readonly Dictionary<Guid, ReservationDoc> _reservations = [];
    private readonly Lock _gate = new();

    public Task<InventoryItem?> GetAsync(string sku, CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            return Task.FromResult(_items.TryGetValue(sku, out var i) ? i : null);
        }
    }

    public Task<InventoryItem> SetQuantityAsync(string sku, int quantity, CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            var reserved = _items.TryGetValue(sku, out var existing) ? existing.Reserved : 0;
            var item = InventoryItem.Create(sku, quantity, reserved, time.GetUtcNow());
            _items[sku] = item;
            return Task.FromResult(item);
        }
    }

    public Task<ReservationResult> ReserveAsync(string sku, Guid orderId, int quantity, CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            if (!_items.TryGetValue(sku, out var item))
            {
                return Task.FromResult(new ReservationResult(ReservationOutcome.UnknownSku, sku, orderId, quantity, 0));
            }

            if (_reservations.TryGetValue(orderId, out var existing))
            {
                var outcome = existing.Status == "reserved" ? ReservationOutcome.Replayed : ReservationOutcome.AlreadyReleased;
                return Task.FromResult(new ReservationResult(outcome, sku, orderId, existing.Quantity, item.Quantity));
            }

            if (item.Quantity < quantity)
            {
                return Task.FromResult(new ReservationResult(ReservationOutcome.Insufficient, sku, orderId, quantity, item.Quantity));
            }

            var now = time.GetUtcNow();
            _items[sku] = item with { Quantity = item.Quantity - quantity, Reserved = item.Reserved + quantity, UpdatedAt = now };
            _reservations[orderId] = new ReservationDoc(ReservationDoc.IdFor(orderId), sku, ReservationDoc.ReservationType, orderId, quantity, "reserved", now, now);
            return Task.FromResult(new ReservationResult(ReservationOutcome.Reserved, sku, orderId, quantity, item.Quantity - quantity));
        }
    }

    public Task<ReservationResult> ReleaseAsync(string sku, Guid orderId, CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            if (!_reservations.TryGetValue(orderId, out var r) || r.Sku != sku || !_items.TryGetValue(sku, out var item))
            {
                return Task.FromResult(new ReservationResult(ReservationOutcome.NotFound, sku, orderId, 0, 0));
            }

            if (r.Status == "released")
            {
                return Task.FromResult(new ReservationResult(ReservationOutcome.AlreadyReleased, sku, orderId, r.Quantity, item.Quantity));
            }

            var now = time.GetUtcNow();
            _reservations[orderId] = r with { Status = "released", UpdatedAt = now };
            _items[sku] = item with { Quantity = item.Quantity + r.Quantity, Reserved = Math.Max(0, item.Reserved - r.Quantity), UpdatedAt = now };
            return Task.FromResult(new ReservationResult(ReservationOutcome.Released, sku, orderId, r.Quantity, item.Quantity + r.Quantity));
        }
    }

    public async Task<int> SeedAsync(CancellationToken cancellationToken)
    {
        var n = 0;
        foreach (var (sku, qty) in Seed.Items())
        {
            lock (_gate)
            {
                _items[sku] = InventoryItem.Create(sku, qty, 0, time.GetUtcNow());
            }

            n++;
        }

        return await Task.FromResult(n).ConfigureAwait(false);
    }

    public Task PingAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}

/// <summary>
/// STORAGE_MODE=cosmos — Azure Cosmos DB for NoSQL, database COSMOS_DATABASE (default `inventory`), container
/// COSMOS_CONTAINER (default `items`, partition key /sku). Managed identity (no keys). Reservation + stock update are
/// one transactional batch in the SKU partition with optimistic concurrency (ETag).
/// </summary>
public sealed class CosmosInventoryStore : IInventoryStore, IDisposable
{
    private const int MaxConcurrencyRetries = 5;
    private readonly CosmosClient _client;
    private readonly Container _container;
    private readonly TimeProvider _time;

    public CosmosInventoryStore(IConfiguration configuration, TimeProvider time, Hello.Common.HelloServiceInfo info)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ArgumentNullException.ThrowIfNull(info);
        _time = time;
        var options = new CosmosClientOptions
        {
            ApplicationName = info.Service,
            ConnectionMode = string.Equals(configuration["COSMOS_CONNECTION_MODE"], "gateway", StringComparison.OrdinalIgnoreCase)
                ? ConnectionMode.Gateway
                : ConnectionMode.Direct,
            RequestTimeout = TimeSpan.FromSeconds(5),
            MaxRetryAttemptsOnRateLimitedRequests = 3,
            MaxRetryWaitTimeOnRateLimitedRequests = TimeSpan.FromSeconds(5),
            UseSystemTextJsonSerializerWithOptions = new JsonSerializerOptions(JsonSerializerDefaults.Web)
            {
                PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
            },
            CosmosClientTelemetryOptions = new CosmosClientTelemetryOptions { DisableDistributedTracing = false },
        };

        var connectionString = configuration["COSMOS_CONNECTION_STRING"]; // emulator / local only
        if (!string.IsNullOrWhiteSpace(connectionString))
        {
            _client = new CosmosClient(connectionString, options);
        }
        else
        {
            var endpoint = configuration["COSMOS_ENDPOINT"];
            if (string.IsNullOrWhiteSpace(endpoint))
            {
                throw new InvalidOperationException("STORAGE_MODE=cosmos requires COSMOS_ENDPOINT.");
            }

            _client = new CosmosClient(endpoint, AzureCredentialFactory.Create(configuration), options);
        }

        _container = _client.GetContainer(
            string.IsNullOrWhiteSpace(configuration["COSMOS_DATABASE"]) ? "inventory" : configuration["COSMOS_DATABASE"],
            string.IsNullOrWhiteSpace(configuration["COSMOS_CONTAINER"]) ? "items" : configuration["COSMOS_CONTAINER"]);
    }

    public async Task<InventoryItem?> GetAsync(string sku, CancellationToken cancellationToken) =>
        (await ReadItemAsync(sku, cancellationToken).ConfigureAwait(false))?.Resource;

    public async Task<InventoryItem> SetQuantityAsync(string sku, int quantity, CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < MaxConcurrencyRetries; attempt++)
        {
            var existing = await ReadItemAsync(sku, cancellationToken).ConfigureAwait(false);
            var item = InventoryItem.Create(sku, quantity, existing?.Resource.Reserved ?? 0, _time.GetUtcNow());
            try
            {
                var options = existing is null ? null : new ItemRequestOptions { IfMatchEtag = existing.ETag };
                var response = existing is null
                    ? await Run(() => _container.CreateItemAsync(item, new PartitionKey(sku), cancellationToken: cancellationToken)).ConfigureAwait(false)
                    : await Run(() => _container.ReplaceItemAsync(item, sku, new PartitionKey(sku), options, cancellationToken)).ConfigureAwait(false);
                return response.Resource;
            }
            catch (CosmosException ex) when (ex.StatusCode is HttpStatusCode.PreconditionFailed or HttpStatusCode.Conflict)
            {
                // concurrent writer; retry
            }
        }

        throw new HelloProblemException(StatusCodes.Status409Conflict, "concurrent-update", "Concurrent update", "Retry later.");
    }

    public async Task<ReservationResult> ReserveAsync(string sku, Guid orderId, int quantity, CancellationToken cancellationToken)
    {
        var pk = new PartitionKey(sku);
        for (var attempt = 0; attempt < MaxConcurrencyRetries; attempt++)
        {
            var item = await ReadItemAsync(sku, cancellationToken).ConfigureAwait(false);
            if (item is null)
            {
                return new ReservationResult(ReservationOutcome.UnknownSku, sku, orderId, quantity, 0);
            }

            var existing = await ReadReservationAsync(sku, orderId, cancellationToken).ConfigureAwait(false);
            if (existing is not null)
            {
                var outcome = existing.Resource.Status == "reserved" ? ReservationOutcome.Replayed : ReservationOutcome.AlreadyReleased;
                return new ReservationResult(outcome, sku, orderId, existing.Resource.Quantity, item.Resource.Quantity);
            }

            if (item.Resource.Quantity < quantity)
            {
                return new ReservationResult(ReservationOutcome.Insufficient, sku, orderId, quantity, item.Resource.Quantity);
            }

            var now = _time.GetUtcNow();
            var updated = item.Resource with { Quantity = item.Resource.Quantity - quantity, Reserved = item.Resource.Reserved + quantity, UpdatedAt = now };
            var reservation = new ReservationDoc(ReservationDoc.IdFor(orderId), sku, ReservationDoc.ReservationType, orderId, quantity, "reserved", now, now);
            using var batch = await Run(() => _container.CreateTransactionalBatch(pk)
                .CreateItem(reservation)
                .ReplaceItem(sku, updated, new TransactionalBatchItemRequestOptions { IfMatchEtag = item.ETag })
                .ExecuteAsync(cancellationToken)).ConfigureAwait(false);
            if (batch.IsSuccessStatusCode)
            {
                return new ReservationResult(ReservationOutcome.Reserved, sku, orderId, quantity, updated.Quantity);
            }

            if (batch.StatusCode is not (HttpStatusCode.Conflict or HttpStatusCode.PreconditionFailed))
            {
                throw new DataStoreUnavailableException($"Cosmos batch failed with {(int)batch.StatusCode}.");
            }
        }

        throw new HelloProblemException(StatusCodes.Status409Conflict, "concurrent-update", "Concurrent update", "Retry later.");
    }

    public async Task<ReservationResult> ReleaseAsync(string sku, Guid orderId, CancellationToken cancellationToken)
    {
        var pk = new PartitionKey(sku);
        for (var attempt = 0; attempt < MaxConcurrencyRetries; attempt++)
        {
            var reservation = await ReadReservationAsync(sku, orderId, cancellationToken).ConfigureAwait(false);
            var item = await ReadItemAsync(sku, cancellationToken).ConfigureAwait(false);
            if (reservation is null || item is null)
            {
                return new ReservationResult(ReservationOutcome.NotFound, sku, orderId, 0, item?.Resource.Quantity ?? 0);
            }

            if (reservation.Resource.Status == "released")
            {
                return new ReservationResult(ReservationOutcome.AlreadyReleased, sku, orderId, reservation.Resource.Quantity, item.Resource.Quantity);
            }

            var now = _time.GetUtcNow();
            var q = reservation.Resource.Quantity;
            var updatedItem = item.Resource with { Quantity = item.Resource.Quantity + q, Reserved = Math.Max(0, item.Resource.Reserved - q), UpdatedAt = now };
            using var batch = await Run(() => _container.CreateTransactionalBatch(pk)
                .ReplaceItem(reservation.Resource.Id, reservation.Resource with { Status = "released", UpdatedAt = now }, new TransactionalBatchItemRequestOptions { IfMatchEtag = reservation.ETag })
                .ReplaceItem(sku, updatedItem, new TransactionalBatchItemRequestOptions { IfMatchEtag = item.ETag })
                .ExecuteAsync(cancellationToken)).ConfigureAwait(false);
            if (batch.IsSuccessStatusCode)
            {
                return new ReservationResult(ReservationOutcome.Released, sku, orderId, q, updatedItem.Quantity);
            }

            if (batch.StatusCode != HttpStatusCode.PreconditionFailed)
            {
                throw new DataStoreUnavailableException($"Cosmos batch failed with {(int)batch.StatusCode}.");
            }
        }

        throw new HelloProblemException(StatusCodes.Status409Conflict, "concurrent-update", "Concurrent update", "Retry later.");
    }

    public async Task<int> SeedAsync(CancellationToken cancellationToken)
    {
        var n = 0;
        foreach (var (sku, qty) in Seed.Items())
        {
            var item = InventoryItem.Create(sku, qty, 0, _time.GetUtcNow());
            await Run(() => _container.UpsertItemAsync(item, new PartitionKey(sku), cancellationToken: cancellationToken)).ConfigureAwait(false);
            n++;
        }

        return n;
    }

    public async Task PingAsync(CancellationToken cancellationToken) =>
        await Run(() => _container.ReadContainerAsync(cancellationToken: cancellationToken)).ConfigureAwait(false);

    public void Dispose() => _client.Dispose();

    private async Task<ItemResponse<InventoryItem>?> ReadItemAsync(string sku, CancellationToken ct)
    {
        try
        {
            return await Run(() => _container.ReadItemAsync<InventoryItem>(sku, new PartitionKey(sku), cancellationToken: ct)).ConfigureAwait(false);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }
    }

    private async Task<ItemResponse<ReservationDoc>?> ReadReservationAsync(string sku, Guid orderId, CancellationToken ct)
    {
        try
        {
            return await Run(() => _container.ReadItemAsync<ReservationDoc>(ReservationDoc.IdFor(orderId), new PartitionKey(sku), cancellationToken: ct)).ConfigureAwait(false);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }
    }

    /// <summary>Maps transport/availability failures (not 404/409/412) to 503 problem responses.</summary>
    private static async Task<T> Run<T>(Func<Task<T>> operation)
    {
        try
        {
            return await operation().ConfigureAwait(false);
        }
        catch (CosmosException ex) when (ex.StatusCode is HttpStatusCode.ServiceUnavailable or HttpStatusCode.RequestTimeout or HttpStatusCode.Forbidden or HttpStatusCode.Unauthorized or (HttpStatusCode)429)
        {
            throw new DataStoreUnavailableException($"Cosmos DB unavailable ({(int)ex.StatusCode}).", ex);
        }
    }
}

/// <summary>Applies the db_error lab fault in front of any store.</summary>
public sealed class FaultingInventoryStore(IInventoryStore inner, FaultState faults) : IInventoryStore
{
    public Task<InventoryItem?> GetAsync(string sku, CancellationToken cancellationToken) => Guard(() => inner.GetAsync(sku, cancellationToken));

    public Task<InventoryItem> SetQuantityAsync(string sku, int quantity, CancellationToken cancellationToken) => Guard(() => inner.SetQuantityAsync(sku, quantity, cancellationToken));

    public Task<ReservationResult> ReserveAsync(string sku, Guid orderId, int quantity, CancellationToken cancellationToken) => Guard(() => inner.ReserveAsync(sku, orderId, quantity, cancellationToken));

    public Task<ReservationResult> ReleaseAsync(string sku, Guid orderId, CancellationToken cancellationToken) => Guard(() => inner.ReleaseAsync(sku, orderId, cancellationToken));

    public Task<int> SeedAsync(CancellationToken cancellationToken) => Guard(() => inner.SeedAsync(cancellationToken));

    public Task PingAsync(CancellationToken cancellationToken) => inner.PingAsync(cancellationToken);

    private Task<T> Guard<T>(Func<Task<T>> call)
    {
        faults.ThrowIfInjected(FaultTypes.DbError);
        return call();
    }
}
