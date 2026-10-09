namespace Hello.OrdersApi;

/// <summary>Runtime settings, resolved from environment configuration when first needed.</summary>
public sealed record OrdersSettings(
    string StorageMode,
    string? SqlConnectionString,
    bool SqlUseAzureCredential,
    string MessagingMode,
    string? ServiceBusFqdn,
    string? ServiceBusConnectionString,
    string Topic,
    Uri? CatalogApiUrl,
    bool PriceFallback)
{
    public static OrdersSettings From(IConfiguration c)
    {
        ArgumentNullException.ThrowIfNull(c);
        var storage = (c["STORAGE_MODE"] ?? (string.IsNullOrWhiteSpace(c["SQL_CONNECTION_STRING"]) ? "memory" : "sql")).Trim().ToLowerInvariant();
        var messaging = (c["MESSAGING_MODE"] ?? "servicebus").Trim().ToLowerInvariant();
        return new OrdersSettings(
            storage,
            c["SQL_CONNECTION_STRING"],
            string.Equals(c["SQL_USE_AZURE_CREDENTIAL"], "true", StringComparison.OrdinalIgnoreCase),
            messaging,
            c["SERVICEBUS_FQDN"],
            c["SERVICEBUS_CONNECTION_STRING"],
            string.IsNullOrWhiteSpace(c["SERVICEBUS_TOPIC"]) ? "order-events" : c["SERVICEBUS_TOPIC"]!,
            Uri.TryCreate(c["CATALOG_API_URL"], UriKind.Absolute, out var catalog) ? catalog : null,
            string.Equals(c["PRICE_FALLBACK"], "true", StringComparison.OrdinalIgnoreCase));
    }
}
