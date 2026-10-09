using System.Collections.Concurrent;
using System.Data;
using System.Text.Json;
using Azure.Core;
using Hello.Common.Azure;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;

namespace Hello.Durable.Services;

/// <summary>STORAGE_MODE=memory (tests/local smoke).</summary>
public sealed class InMemoryFulfillmentStore : IFulfillmentStore
{
    public ConcurrentDictionary<Guid, FulfillmentRecord> Fulfillments { get; } = new();

    public ConcurrentDictionary<string, BatchSummary> BatchRuns { get; } = new(StringComparer.Ordinal);

    public ConcurrentDictionary<string, ReconciliationSummary> ReconciliationRuns { get; } = new(StringComparer.Ordinal);

    public Task UpsertFulfillmentAsync(FulfillmentRecord record, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(record);
        Fulfillments[record.OrderId] = record;
        return Task.CompletedTask;
    }

    public Task<IReadOnlyList<FulfillmentSnapshot>> GetFulfillmentsSinceAsync(DateTimeOffset since, CancellationToken cancellationToken) =>
        Task.FromResult<IReadOnlyList<FulfillmentSnapshot>>([.. Fulfillments.Values
            .Where(f => f.CompletedAt >= since)
            .Select(f => new FulfillmentSnapshot(f.OrderId, f.Status, f.CompletedAt))]);

    public Task UpsertBatchRunAsync(BatchSummary summary, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(summary);
        BatchRuns[summary.BatchId] = summary;
        return Task.CompletedTask;
    }

    public Task UpsertReconciliationRunAsync(ReconciliationSummary summary, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(summary);
        ReconciliationRuns[summary.RunId] = summary;
        return Task.CompletedTask;
    }
}

/// <summary>
/// SQL `fulfillment` schema. Every write is a MERGE keyed by the natural id, so retried activities are idempotent.
/// The schema migration runs once per process before the first write (idempotent, applock-serialised).
/// </summary>
public sealed class SqlFulfillmentStore : IFulfillmentStore, IDisposable
{
    private static readonly string[] Scopes = ["https://database.windows.net/.default"];
    private readonly string _connectionString;
    private readonly TokenCredential? _credential;
    private readonly SemaphoreSlim _migrationGate = new(1, 1);
    private volatile bool _migrated;

    public SqlFulfillmentStore(DurableSettings settings, IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(settings);
        var builder = new SqlConnectionStringBuilder(settings.SqlConnectionString ?? throw new InvalidOperationException("SQL_CONNECTION_STRING is required when STORAGE_MODE=sql."))
        {
            ApplicationName = "hello-durable",
            ConnectTimeout = 15,
            CommandTimeout = 10,
        };
        _connectionString = builder.ConnectionString;
        if (settings.SqlUseAzureCredential && builder.Authentication == SqlAuthenticationMethod.NotSpecified)
        {
            _credential = AzureCredentialFactory.Create(configuration);
        }
    }

    public async Task UpsertFulfillmentAsync(FulfillmentRecord record, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(record);
        await using var connection = await OpenAsync(cancellationToken).ConfigureAwait(false);
        await using var cmd = new SqlCommand(
            """
            MERGE fulfillment.fulfillments WITH (HOLDLOCK) AS t
            USING (SELECT @order_id AS order_id) AS s ON t.order_id = s.order_id
            WHEN MATCHED THEN UPDATE SET status = @status, reason = @reason, payment_id = COALESCE(@payment_id, t.payment_id),
                workflow_instance_id = @wf, updated_at = @at
            WHEN NOT MATCHED THEN INSERT (order_id, sku, quantity, amount, status, reason, payment_id, workflow_instance_id, created_at, updated_at)
                VALUES (@order_id, @sku, @quantity, @amount, @status, @reason, @payment_id, @wf, @at, @at);
            """,
            connection);
        cmd.Parameters.Add("@order_id", SqlDbType.UniqueIdentifier).Value = record.OrderId;
        cmd.Parameters.Add("@sku", SqlDbType.NVarChar, 64).Value = record.Sku;
        cmd.Parameters.Add("@quantity", SqlDbType.Int).Value = record.Quantity;
        cmd.Parameters.Add(new SqlParameter("@amount", SqlDbType.Decimal) { Precision = 18, Scale = 2, Value = record.Amount });
        cmd.Parameters.Add("@status", SqlDbType.NVarChar, 32).Value = record.Status;
        cmd.Parameters.Add("@reason", SqlDbType.NVarChar, 512).Value = (object?)record.Reason ?? DBNull.Value;
        cmd.Parameters.Add("@payment_id", SqlDbType.NVarChar, 128).Value = (object?)record.PaymentId ?? DBNull.Value;
        cmd.Parameters.Add("@wf", SqlDbType.NVarChar, 128).Value = record.WorkflowInstanceId;
        cmd.Parameters.Add("@at", SqlDbType.DateTimeOffset).Value = record.CompletedAt;
        await cmd.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<FulfillmentSnapshot>> GetFulfillmentsSinceAsync(DateTimeOffset since, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken).ConfigureAwait(false);
        await using var cmd = new SqlCommand("SELECT TOP (5000) order_id, status, updated_at FROM fulfillment.fulfillments WHERE updated_at >= @since", connection);
        cmd.Parameters.Add("@since", SqlDbType.DateTimeOffset).Value = since;
        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        var list = new List<FulfillmentSnapshot>();
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            list.Add(new FulfillmentSnapshot(reader.GetGuid(0), reader.GetString(1), reader.GetDateTimeOffset(2)));
        }

        return list;
    }

    public async Task UpsertBatchRunAsync(BatchSummary summary, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(summary);
        await using var connection = await OpenAsync(cancellationToken).ConfigureAwait(false);
        await using var cmd = new SqlCommand(
            """
            MERGE fulfillment.batch_runs WITH (HOLDLOCK) AS t
            USING (SELECT @id AS batch_id) AS s ON t.batch_id = s.batch_id
            WHEN MATCHED THEN UPDATE SET items = @items, succeeded = @ok, failed = @failed, total_value = @value, started_at = @started, completed_at = @completed
            WHEN NOT MATCHED THEN INSERT (batch_id, items, succeeded, failed, total_value, started_at, completed_at)
                VALUES (@id, @items, @ok, @failed, @value, @started, @completed);
            """,
            connection);
        cmd.Parameters.Add("@id", SqlDbType.NVarChar, 128).Value = summary.BatchId;
        cmd.Parameters.Add("@items", SqlDbType.Int).Value = summary.Items;
        cmd.Parameters.Add("@ok", SqlDbType.Int).Value = summary.Succeeded;
        cmd.Parameters.Add("@failed", SqlDbType.Int).Value = summary.Failed;
        cmd.Parameters.Add(new SqlParameter("@value", SqlDbType.Decimal) { Precision = 18, Scale = 2, Value = summary.TotalValue });
        cmd.Parameters.Add("@started", SqlDbType.DateTimeOffset).Value = summary.StartedAt;
        cmd.Parameters.Add("@completed", SqlDbType.DateTimeOffset).Value = summary.CompletedAt;
        await cmd.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task UpsertReconciliationRunAsync(ReconciliationSummary summary, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(summary);
        await using var connection = await OpenAsync(cancellationToken).ConfigureAwait(false);
        await using var cmd = new SqlCommand(
            """
            MERGE fulfillment.reconciliation_runs WITH (HOLDLOCK) AS t
            USING (SELECT @id AS run_id) AS s ON t.run_id = s.run_id
            WHEN MATCHED THEN UPDATE SET since = @since, completed_at = @completed, orders_checked = @orders, fulfillments_checked = @fulfillments,
                matched = @matched, missing_fulfillment = @missing, status_mismatch = @mismatch, orphan_fulfillment = @orphan, stuck_orders = @stuck, samples = @samples
            WHEN NOT MATCHED THEN INSERT (run_id, since, completed_at, orders_checked, fulfillments_checked, matched, missing_fulfillment, status_mismatch, orphan_fulfillment, stuck_orders, samples)
                VALUES (@id, @since, @completed, @orders, @fulfillments, @matched, @missing, @mismatch, @orphan, @stuck, @samples);
            """,
            connection);
        cmd.Parameters.Add("@id", SqlDbType.NVarChar, 128).Value = summary.RunId;
        cmd.Parameters.Add("@since", SqlDbType.DateTimeOffset).Value = summary.Since;
        cmd.Parameters.Add("@completed", SqlDbType.DateTimeOffset).Value = summary.CompletedAt;
        cmd.Parameters.Add("@orders", SqlDbType.Int).Value = summary.OrdersChecked;
        cmd.Parameters.Add("@fulfillments", SqlDbType.Int).Value = summary.FulfillmentsChecked;
        cmd.Parameters.Add("@matched", SqlDbType.Int).Value = summary.Matched;
        cmd.Parameters.Add("@missing", SqlDbType.Int).Value = summary.MissingFulfillment;
        cmd.Parameters.Add("@mismatch", SqlDbType.Int).Value = summary.StatusMismatch;
        cmd.Parameters.Add("@orphan", SqlDbType.Int).Value = summary.OrphanFulfillment;
        cmd.Parameters.Add("@stuck", SqlDbType.Int).Value = summary.StuckOrders;
        cmd.Parameters.Add("@samples", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(summary.Samples);
        await cmd.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    public void Dispose() => _migrationGate.Dispose();

    private async Task<SqlConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connection = new SqlConnection(_connectionString);
        if (_credential is not null)
        {
            var credential = _credential;
            connection.AccessTokenCallback = async (_, ct) =>
            {
                var token = await credential.GetTokenAsync(new TokenRequestContext(Scopes), ct).ConfigureAwait(false);
                return new SqlAuthenticationToken(token.Token, token.ExpiresOn);
            };
        }

        try
        {
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
            if (!_migrated)
            {
                await MigrateAsync(connection, cancellationToken).ConfigureAwait(false);
            }

            return connection;
        }
        catch
        {
            await connection.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    private async Task MigrateAsync(SqlConnection connection, CancellationToken cancellationToken)
    {
        await _migrationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_migrated)
            {
                return;
            }

            var asm = typeof(SqlFulfillmentStore).Assembly;
            foreach (var name in asm.GetManifestResourceNames().Where(n => n.EndsWith(".sql", StringComparison.Ordinal)).Order(StringComparer.Ordinal))
            {
                await using var stream = asm.GetManifestResourceStream(name)!;
                using var reader = new StreamReader(stream);
                await using var cmd = new SqlCommand(await reader.ReadToEndAsync(cancellationToken).ConfigureAwait(false), connection) { CommandTimeout = 60 };
                await cmd.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
            }

            _migrated = true;
        }
        finally
        {
            _migrationGate.Release();
        }
    }
}
