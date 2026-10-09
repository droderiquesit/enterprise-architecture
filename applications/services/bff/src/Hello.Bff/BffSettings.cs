using System.Text.Json;

namespace Hello.Bff;

public sealed record AdapterTarget(string Family, Uri Url);

/// <summary>BFF settings resolved from environment configuration.</summary>
public sealed class BffSettings
{
    private static readonly JsonSerializerOptions AdapterJson = new(JsonSerializerDefaults.Web);

    public Uri? CatalogApiUrl { get; init; }

    public Uri? OrdersApiUrl { get; init; }

    public Uri? InventoryApiUrl { get; init; }

    public IReadOnlyList<AdapterTarget> Adapters { get; init; } = [];

    public IReadOnlyList<string> AllowedOrigins { get; init; } = [];

    public string AuthMode { get; init; } = "none";

    public string? EntraAudience { get; init; }

    public string? EntraTenantId { get; init; }

    public int RateLimitPermits { get; init; } = 100;

    public TimeSpan RateLimitWindow { get; init; } = TimeSpan.FromSeconds(10);

    public bool ForwardedHeaders { get; init; }

    public static BffSettings From(IConfiguration c)
    {
        ArgumentNullException.ThrowIfNull(c);
        return new BffSettings
        {
            CatalogApiUrl = BaseUri(c["CATALOG_API_URL"]),
            OrdersApiUrl = BaseUri(c["ORDERS_API_URL"]),
            InventoryApiUrl = BaseUri(c["INVENTORY_API_URL"]),
            Adapters = ParseAdapters(c["ADAPTERS_JSON"]),
            AllowedOrigins = [.. (c["CORS_ALLOWED_ORIGINS"] ?? string.Empty)
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(o => o.TrimEnd('/'))],
            AuthMode = (c["AUTH_MODE"] ?? "none").Trim().ToLowerInvariant(),
            EntraAudience = c["ENTRA_AUDIENCE"],
            EntraTenantId = c["ENTRA_TENANT_ID"],
            RateLimitPermits = int.TryParse(c["RATE_LIMIT_PERMIT_LIMIT"], out var p) && p > 0 ? p : 100,
            RateLimitWindow = TimeSpan.FromSeconds(int.TryParse(c["RATE_LIMIT_WINDOW_SECONDS"], out var w) && w > 0 ? w : 10),
            ForwardedHeaders = string.Equals(c["FORWARDED_HEADERS_ENABLED"], "true", StringComparison.OrdinalIgnoreCase),
        };
    }

    /// <summary>Normalises a base URL so relative paths append (trailing slash).</summary>
    public static Uri? BaseUri(string? value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var u) ? new Uri(u.ToString().TrimEnd('/') + "/") : null;

    internal static IReadOnlyList<AdapterTarget> ParseAdapters(string? json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return [];
        }

        try
        {
            var raw = JsonSerializer.Deserialize<List<RawAdapter>>(json, AdapterJson) ?? [];
            return [.. raw
                .Where(a => !string.IsNullOrWhiteSpace(a.Family) && BaseUri(a.Url) is not null)
                .Select(a => new AdapterTarget(a.Family!.Trim(), BaseUri(a.Url)!))
                .DistinctBy(a => a.Family, StringComparer.OrdinalIgnoreCase)];
        }
        catch (JsonException)
        {
            return [];
        }
    }

    private sealed record RawAdapter(string? Family, string? Url);
}
