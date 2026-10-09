using System.Data;
using Hello.Common.Problems;
using Microsoft.Data.SqlClient;

namespace Hello.OrdersApi.Data;

/// <summary>Azure SQL implementation (parameterised commands only; pooled connections; 10 s command timeout).</summary>
public sealed class SqlOrderRepository(SqlConnectionFactory factory) : IOrderRepository
{
    private const string Columns =
        "id, sku, quantity, unit_price, amount, status, customer_ref, created_at, updated_at, status_reason, workflow_instance_id";

    public async Task<CreateResult> CreateAsync(Order order, string idempotencyKey, string requestHash, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(order);
        await using var connection = await OpenAsync(cancellationToken).ConfigureAwait(false);
        await using var tx = (SqlTransaction)await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, cancellationToken).ConfigureAwait(false);
        try
        {
            await using (var cmd = new SqlCommand(
                "INSERT INTO orders.idempotency (idempotency_key, request_hash, order_id, created_at) VALUES (@key, @hash, @id, @created);" +
                $"INSERT INTO orders.orders ({Columns}, idempotency_key) VALUES (@id, @sku, @qty, @price, @amount, @status, @customer, @created, @updated, NULL, NULL, @key);",
                connection,
                tx))
            {
                cmd.Parameters.Add("@key", SqlDbType.NVarChar, 128).Value = idempotencyKey;
                cmd.Parameters.Add("@hash", SqlDbType.Char, 64).Value = requestHash;
                cmd.Parameters.Add("@id", SqlDbType.UniqueIdentifier).Value = order.Id;
                cmd.Parameters.Add("@sku", SqlDbType.NVarChar, 64).Value = order.Sku;
                cmd.Parameters.Add("@qty", SqlDbType.Int).Value = order.Quantity;
                cmd.Parameters.Add(new SqlParameter("@price", SqlDbType.Decimal) { Precision = 18, Scale = 2, Value = order.UnitPrice });
                cmd.Parameters.Add(new SqlParameter("@amount", SqlDbType.Decimal) { Precision = 18, Scale = 2, Value = order.Amount });
                cmd.Parameters.Add("@status", SqlDbType.NVarChar, 32).Value = order.Status;
                cmd.Parameters.Add("@customer", SqlDbType.NVarChar, 128).Value = order.CustomerRef;
                cmd.Parameters.Add("@created", SqlDbType.DateTimeOffset).Value = order.CreatedAt;
                cmd.Parameters.Add("@updated", SqlDbType.DateTimeOffset).Value = order.UpdatedAt;
                await cmd.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
            }

            await tx.CommitAsync(cancellationToken).ConfigureAwait(false);
            return new CreateResult(CreateOutcome.Created, order);
        }
        catch (SqlException ex) when (ex.Number is 2627 or 2601)
        {
            // Concurrent request with the same Idempotency-Key won the race.
            await tx.RollbackAsync(cancellationToken).ConfigureAwait(false);
            var existing = await FindIdempotencyAsync(idempotencyKey, cancellationToken).ConfigureAwait(false);
            if (existing is null)
            {
                throw;
            }

            if (existing.RequestHash != requestHash)
            {
                return new CreateResult(CreateOutcome.KeyConflict, null);
            }

            return new CreateResult(CreateOutcome.Replayed, await GetAsync(existing.OrderId, cancellationToken).ConfigureAwait(false));
        }
    }

    public async Task<IdempotencyRecord?> FindIdempotencyAsync(string idempotencyKey, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken).ConfigureAwait(false);
        await using var cmd = new SqlCommand("SELECT idempotency_key, request_hash, order_id FROM orders.idempotency WHERE idempotency_key = @key", connection);
        cmd.Parameters.Add("@key", SqlDbType.NVarChar, 128).Value = idempotencyKey;
        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        return await reader.ReadAsync(cancellationToken).ConfigureAwait(false)
            ? new IdempotencyRecord(reader.GetString(0), reader.GetString(1).Trim(), reader.GetGuid(2))
            : null;
    }

    public async Task<Order?> GetAsync(Guid id, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken).ConfigureAwait(false);
        await using var cmd = new SqlCommand($"SELECT {Columns} FROM orders.orders WHERE id = @id", connection);
        cmd.Parameters.Add("@id", SqlDbType.UniqueIdentifier).Value = id;
        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        return await reader.ReadAsync(cancellationToken).ConfigureAwait(false) ? Map(reader) : null;
    }

    public async Task<IReadOnlyList<Order>> ListAsync(int limit, DateTimeOffset? since, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken).ConfigureAwait(false);
        await using var cmd = new SqlCommand(
            $"SELECT TOP (@limit) {Columns} FROM orders.orders WHERE (@since IS NULL OR created_at >= @since) ORDER BY created_at DESC",
            connection);
        cmd.Parameters.Add("@limit", SqlDbType.Int).Value = limit;
        cmd.Parameters.Add("@since", SqlDbType.DateTimeOffset).Value = since.HasValue ? since.Value : DBNull.Value;
        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        var list = new List<Order>();
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            list.Add(Map(reader));
        }

        return list;
    }

    public async Task<Order?> UpdateStatusAsync(Guid id, string expectedStatus, string newStatus, string? reason, string? workflowInstanceId, DateTimeOffset now, CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken).ConfigureAwait(false);
        await using var cmd = new SqlCommand(
            "UPDATE orders.orders SET status = @status, status_reason = COALESCE(@reason, status_reason), " +
            "workflow_instance_id = COALESCE(@wf, workflow_instance_id), updated_at = @now " +
            $"OUTPUT {string.Join(", ", Columns.Split(", ").Select(c => "inserted." + c))} " +
            "WHERE id = @id AND status = @expected",
            connection);
        cmd.Parameters.Add("@status", SqlDbType.NVarChar, 32).Value = newStatus;
        cmd.Parameters.Add("@reason", SqlDbType.NVarChar, 512).Value = (object?)Truncate(reason, 512) ?? DBNull.Value;
        cmd.Parameters.Add("@wf", SqlDbType.NVarChar, 128).Value = (object?)workflowInstanceId ?? DBNull.Value;
        cmd.Parameters.Add("@now", SqlDbType.DateTimeOffset).Value = now;
        cmd.Parameters.Add("@id", SqlDbType.UniqueIdentifier).Value = id;
        cmd.Parameters.Add("@expected", SqlDbType.NVarChar, 32).Value = expectedStatus;
        await using var reader = await cmd.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        return await reader.ReadAsync(cancellationToken).ConfigureAwait(false) ? Map(reader) : null;
    }

    public async Task PingAsync(CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken).ConfigureAwait(false);
        await using var cmd = new SqlCommand("SELECT 1", connection) { CommandTimeout = 2 };
        await cmd.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task<SqlConnection> OpenAsync(CancellationToken cancellationToken)
    {
        try
        {
            return await factory.OpenAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (SqlException ex)
        {
            throw new DataStoreUnavailableException("The orders database is unavailable.", ex);
        }
    }

    private static string? Truncate(string? value, int max) => value is null || value.Length <= max ? value : value[..max];

    private static Order Map(SqlDataReader r) => new(
        r.GetGuid(0),
        r.GetString(1),
        r.GetInt32(2),
        r.GetDecimal(3),
        r.GetDecimal(4),
        r.GetString(5),
        r.GetString(6),
        r.GetDateTimeOffset(7),
        r.GetDateTimeOffset(8),
        r.IsDBNull(9) ? null : r.GetString(9),
        r.IsDBNull(10) ? null : r.GetString(10));
}
