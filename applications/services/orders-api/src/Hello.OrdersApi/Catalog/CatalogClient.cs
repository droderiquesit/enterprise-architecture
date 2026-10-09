using System.Globalization;
using System.Net;
using System.Text.Json;
using Hello.Common.Problems;

namespace Hello.OrdersApi.Catalog;

public interface ICatalogClient
{
    Task<decimal> GetUnitPriceAsync(string sku, CancellationToken cancellationToken);
}

/// <summary>
/// Prices come from hello-catalog-api GET /products/{sku} (field `price`, or `unit_price`).
/// When CATALOG_API_URL is unset and PRICE_FALLBACK=true (local tests only) a deterministic price is used.
/// </summary>
public sealed class CatalogClient(HttpClient http, OrdersSettings settings) : ICatalogClient
{
    public async Task<decimal> GetUnitPriceAsync(string sku, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sku);
        if (settings.CatalogApiUrl is null)
        {
            if (settings.PriceFallback)
            {
                return FallbackPrice(sku);
            }

            throw new HelloProblemException(StatusCodes.Status503ServiceUnavailable, "catalog-not-configured", "Catalog unavailable", "CATALOG_API_URL is not configured.");
        }

        using var response = await http.GetAsync(new Uri($"products/{Uri.EscapeDataString(sku)}", UriKind.Relative), cancellationToken).ConfigureAwait(false);
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            throw new HelloProblemException(StatusCodes.Status422UnprocessableEntity, "unknown-sku", "Unknown SKU", $"SKU '{sku}' does not exist in the catalog.");
        }

        if (!response.IsSuccessStatusCode)
        {
            throw new HelloProblemException(StatusCodes.Status502BadGateway, "catalog-error", "Catalog error", $"hello-catalog-api returned {(int)response.StatusCode}.");
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken).ConfigureAwait(false);
        foreach (var name in new[] { "price", "unit_price", "unitPrice" })
        {
            if (doc.RootElement.TryGetProperty(name, out var p))
            {
                if (p.ValueKind == JsonValueKind.Number && p.TryGetDecimal(out var d))
                {
                    return d;
                }

                if (p.ValueKind == JsonValueKind.String && decimal.TryParse(p.GetString(), NumberStyles.Number, CultureInfo.InvariantCulture, out var s))
                {
                    return s;
                }
            }
        }

        throw new HelloProblemException(StatusCodes.Status502BadGateway, "catalog-error", "Catalog error", "Catalog response has no price.");
    }

    /// <summary>Deterministic local price: 5.00 + 2.50 × (numeric part of the SKU mod 20).</summary>
    public static decimal FallbackPrice(string sku)
    {
        ArgumentNullException.ThrowIfNull(sku);
        var digits = new string([.. sku.Where(char.IsAsciiDigit)]);
        var n = digits.Length > 0 && int.TryParse(digits[^Math.Min(6, digits.Length)..], NumberStyles.None, CultureInfo.InvariantCulture, out var v) ? v : sku.Length;
        return 5.00m + (2.50m * (n % 20));
    }
}
