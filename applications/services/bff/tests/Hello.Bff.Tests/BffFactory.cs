using System.Collections.Concurrent;
using System.Net;
using System.Text;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;

namespace Hello.Bff.Tests;

/// <summary>Records downstream requests and answers from a scripted queue (default 200 {}).</summary>
public sealed class StubDownstream : HttpMessageHandler
{
    public ConcurrentQueue<HttpRequestMessage> Requests { get; } = new();

    public ConcurrentQueue<Func<HttpRequestMessage, HttpResponseMessage>> Script { get; } = new();

    public Dictionary<string, string> RequestBodies { get; } = [];

    /// <summary>Trace id of the client span active when the request left the BFF (SocketsHttpHandler injects it as traceparent).</summary>
    public ConcurrentQueue<string?> TraceIds { get; } = new();

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (request.Content is not null)
        {
            RequestBodies[request.RequestUri!.ToString()] = await request.Content.ReadAsStringAsync(cancellationToken);
        }

        TraceIds.Enqueue(System.Diagnostics.Activity.Current?.TraceId.ToHexString());
        Requests.Enqueue(request);
        if (Script.TryDequeue(out var next))
        {
            return next(request);
        }

        return Json(HttpStatusCode.OK, "{}");
    }

    public static HttpResponseMessage Json(HttpStatusCode status, string json) =>
        new(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
}

public sealed class BffFactory : WebApplicationFactory<Program>
{
    public StubDownstream Stub { get; } = new();

    public Dictionary<string, string?> Settings { get; } = new()
    {
        ["DD_SERVICE"] = "hello-bff",
        ["LOG_LEVEL"] = "warning",
        ["CATALOG_API_URL"] = "http://catalog.test",
        ["ORDERS_API_URL"] = "http://orders.test/",
        ["CORS_ALLOWED_ORIGINS"] = "https://app.example.test, https://other.example.test",
        ["ADAPTERS_JSON"] = "[{\"family\":\"sql\",\"url\":\"http://dbadapter-sql.test\"},{\"family\":\"redis\",\"url\":\"http://dbadapter-redis.test\"}]",
        ["FAULTS_ENABLED"] = "true",
        ["FAULT_TOKEN"] = "tok",
    };

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        foreach (var (k, v) in Settings)
        {
            builder.UseSetting(k, v);
        }

        builder.ConfigureTestServices(s =>
        {
            s.AddHttpClient<CatalogApi, CatalogApi>().ConfigurePrimaryHttpMessageHandler(() => Stub);
            s.AddHttpClient<OrdersApi, OrdersApi>().ConfigurePrimaryHttpMessageHandler(() => Stub);
            s.AddHttpClient<InventoryApi, InventoryApi>().ConfigurePrimaryHttpMessageHandler(() => Stub);
            s.AddHttpClient<AdaptersApi, AdaptersApi>().ConfigurePrimaryHttpMessageHandler(() => Stub);
        });
    }
}
