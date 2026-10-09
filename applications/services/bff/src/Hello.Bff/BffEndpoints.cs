using System.Net.Http.Json;
using Hello.Common.Idempotency;
using Hello.Common.Operational;
using Hello.Common.Problems;

namespace Hello.Bff;

public static class BffEndpoints
{
    public const string ApiPolicy = "api";

    public static IEndpointRouteBuilder MapBffEndpoints(this IEndpointRouteBuilder app)
    {
        // Unauthenticated operational endpoints under /api for the browser and edge probes.
        app.MapHelloOperationalEndpoints("/api");

        var api = app.MapGroup("/api").RequireAuthorization(ApiPolicy);

        api.MapGet("/catalog/products", (CatalogApi catalog, CancellationToken ct) =>
            Forward(catalog, "hello-catalog-api", HttpMethod.Get, "products", ct));

        api.MapGet("/catalog/products/{sku}", (string sku, CatalogApi catalog, CancellationToken ct) =>
            Forward(catalog, "hello-catalog-api", HttpMethod.Get, $"products/{Uri.EscapeDataString(sku)}", ct));

        api.MapPost("/orders", async (HttpContext ctx, OrdersApi orders, CancellationToken ct) =>
        {
            var key = ctx.Request.Headers[IdempotencyKey.HeaderName].ToString();
            if (string.IsNullOrEmpty(key))
            {
                // Browsers should send one; generate one so a downstream retry cannot double-create.
                key = Guid.NewGuid().ToString("D");
            }
            else if (!IdempotencyKey.IsValid(key, out var error))
            {
                return Results.ValidationProblem(new Dictionary<string, string[]> { [IdempotencyKey.HeaderName] = [error!] }, type: HelloProblems.TypeUri("validation"));
            }

            if (!orders.Configured)
            {
                return NotConfigured("hello-orders-api");
            }

            using var body = new StreamContent(ctx.Request.Body);
            body.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json");
            using var req = Proxy.Build(HttpMethod.Post, "orders", body, key);
            return await Proxy.SendAsync(orders.Http, req, ct).ConfigureAwait(false);
        });

        api.MapGet("/orders", (int? limit, OrdersApi orders, CancellationToken ct) =>
            Forward(orders, "hello-orders-api", HttpMethod.Get, $"orders?limit={Math.Clamp(limit ?? 20, 1, 100)}", ct));

        api.MapGet("/orders/{id:guid}", (Guid id, OrdersApi orders, CancellationToken ct) =>
            Forward(orders, "hello-orders-api", HttpMethod.Get, $"orders/{id:D}", ct));

        api.MapGet("/inventory/{sku}", (string sku, InventoryApi inventory, CancellationToken ct) =>
            Forward(inventory, "hello-inventory-api", HttpMethod.Get, $"inventory/{Uri.EscapeDataString(sku)}", ct));

        api.MapGet("/adapters", (BffSettings settings) =>
            Results.Ok(settings.Adapters.Select(a => new { family = a.Family, roundtrip_path = $"/api/adapters/{a.Family}/roundtrip" })));

        api.MapPost("/adapters/{family}/roundtrip", async (string family, BffSettings settings, AdaptersApi adapters, CancellationToken ct) =>
        {
            var target = settings.Adapters.FirstOrDefault(a => string.Equals(a.Family, family, StringComparison.OrdinalIgnoreCase));
            if (target is null)
            {
                return HelloProblems.Result(StatusCodes.Status404NotFound, "unknown-adapter", "Unknown adapter", $"No adapter configured for family '{family}'.");
            }

            using var req = new HttpRequestMessage(HttpMethod.Post, new Uri(target.Url, "roundtrip")) { Content = JsonContent.Create(new { }) };
            return await Proxy.SendAsync(adapters.Http, req, ct).ConfigureAwait(false);
        });

        return app;
    }

    private static async Task<IResult> Forward(IDownstream downstream, string name, HttpMethod method, string relative, CancellationToken ct)
    {
        if (!downstream.Configured)
        {
            return NotConfigured(name);
        }

        using var req = Proxy.Build(method, relative);
        return await Proxy.SendAsync(downstream.Http, req, ct).ConfigureAwait(false);
    }

    private static IResult NotConfigured(string name) =>
        HelloProblems.Result(StatusCodes.Status503ServiceUnavailable, "dependency-not-configured", "Dependency not configured", $"{name} URL is not configured.");
}
