using Microsoft.Extensions.Configuration;

namespace Hello.Durable;

public sealed record DurableSettings(
    Uri? OrdersApiUrl,
    Uri? InventoryApiUrl,
    Uri? PartnerApiUrl,
    string? SqlConnectionString,
    bool SqlUseAzureCredential,
    string StorageMode,
    int PaymentTimeoutSeconds,
    int HistoryRetentionDays,
    int ReconcileWindowHours,
    double ActivityFailureRate,
    string? ServiceBusFqdn,
    string? ServiceBusConnectionString,
    string BatchQueue)
{
    public static DurableSettings From(IConfiguration c)
    {
        ArgumentNullException.ThrowIfNull(c);
        var sql = c["SQL_CONNECTION_STRING"];
        return new DurableSettings(
            BaseUri(c["ORDERS_API_URL"]),
            BaseUri(c["INVENTORY_API_URL"]),
            BaseUri(c["PARTNER_API_URL"]),
            sql,
            string.Equals(c["SQL_USE_AZURE_CREDENTIAL"], "true", StringComparison.OrdinalIgnoreCase),
            (c["STORAGE_MODE"] ?? (string.IsNullOrWhiteSpace(sql) ? "memory" : "sql")).Trim().ToLowerInvariant(),
            Int(c["PAYMENT_TIMEOUT_SECONDS"], 10, 1, 120),
            Int(c["DURABLE_HISTORY_RETENTION_DAYS"], 7, 1, 365),
            Int(c["RECONCILE_WINDOW_HOURS"], 24, 1, 24 * 14),
            double.TryParse(c["FAULT_ACTIVITY_FAILURE_RATE"], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var rate)
                ? Math.Clamp(rate, 0, 1)
                : 0,
            c["SERVICEBUS_FQDN"] ?? c["ServiceBusConnection__fullyQualifiedNamespace"],
            c["SERVICEBUS_CONNECTION_STRING"],
            string.IsNullOrWhiteSpace(c["BATCH_ITEMS_QUEUE"]) ? "batch-items" : c["BATCH_ITEMS_QUEUE"]!);
    }

    private static Uri? BaseUri(string? value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var u) ? new Uri(u.ToString().TrimEnd('/') + "/") : null;

    private static int Int(string? value, int fallback, int min, int max) =>
        int.TryParse(value, out var v) ? Math.Clamp(v, min, max) : fallback;
}
