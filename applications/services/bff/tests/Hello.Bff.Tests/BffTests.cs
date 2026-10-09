using System.Net;
using System.Net.Http.Json;
using System.Text.Json;

namespace Hello.Bff.Tests;

public sealed class BffTests : IDisposable
{
    private readonly BffFactory _factory = new();

    public void Dispose() => _factory.Dispose();

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task Operational_Endpoints_IncludingApiPrefix()
    {
        var client = _factory.CreateClient();
        foreach (var path in new[] { "/healthz", "/readyz", "/api/healthz", "/version", "/api/version" })
        {
            Assert.Equal(HttpStatusCode.OK, (await client.GetAsync(path, Ct)).StatusCode);
        }

        var version = await client.GetFromJsonAsync<JsonElement>("/api/version", Ct);
        Assert.Equal("hello-bff", version.GetProperty("service").GetString());
    }

    [Fact]
    public async Task Cors_Preflight_AllowsRumAndTraceHeaders()
    {
        var client = _factory.CreateClient();
        var req = new HttpRequestMessage(HttpMethod.Options, "/api/orders");
        req.Headers.Add("Origin", "https://app.example.test");
        req.Headers.Add("Access-Control-Request-Method", "POST");
        req.Headers.Add("Access-Control-Request-Headers", "traceparent,tracestate,x-datadog-trace-id,x-datadog-parent-id,x-datadog-origin,x-datadog-sampling-priority,content-type,idempotency-key");
        var response = await client.SendAsync(req, Ct);

        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        Assert.Equal("https://app.example.test", response.Headers.GetValues("Access-Control-Allow-Origin").Single());
        var allowed = string.Join(',', response.Headers.GetValues("Access-Control-Allow-Headers")).ToLowerInvariant();
        foreach (var h in new[] { "traceparent", "tracestate", "x-datadog-trace-id", "x-datadog-parent-id", "content-type", "idempotency-key" })
        {
            Assert.Contains(h, allowed, StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task Cors_ExposesTraceparent_AndRejectsUnknownOrigin()
    {
        var client = _factory.CreateClient();
        var ok = new HttpRequestMessage(HttpMethod.Get, "/api/catalog/products");
        ok.Headers.Add("Origin", "https://other.example.test");
        var response = await client.SendAsync(ok, Ct);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Contains("traceparent", string.Join(',', response.Headers.GetValues("Access-Control-Expose-Headers")), StringComparison.OrdinalIgnoreCase);
        Assert.True(response.Headers.Contains("traceparent"));

        var bad = new HttpRequestMessage(HttpMethod.Get, "/api/catalog/products");
        bad.Headers.Add("Origin", "https://evil.example.test");
        var badResponse = await client.SendAsync(bad, Ct);
        Assert.False(badResponse.Headers.Contains("Access-Control-Allow-Origin"));
    }

    [Fact]
    public async Task PostOrder_ForwardsIdempotencyKey_AndTraceparent_Returns202()
    {
        _factory.Stub.Script.Enqueue(_ => StubDownstream.Json(HttpStatusCode.Accepted, "{\"id\":\"abc\",\"status\":\"Pending\"}"));
        var client = _factory.CreateClient();
        var req = new HttpRequestMessage(HttpMethod.Post, "/api/orders") { Content = JsonContent.Create(new { sku = "SKU-0001", quantity = 1, customer_ref = "c1" }) };
        req.Headers.Add("Idempotency-Key", "browser-key-1");
        req.Headers.Add("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
        var response = await client.SendAsync(req, Ct);

        Assert.Equal(HttpStatusCode.Accepted, response.StatusCode);
        Assert.Equal("Pending", (await response.Content.ReadFromJsonAsync<JsonElement>(Ct)).GetProperty("status").GetString());
        var downstream = Assert.Single(_factory.Stub.Requests);
        Assert.Equal("http://orders.test/orders", downstream.RequestUri!.ToString());
        Assert.Equal("browser-key-1", downstream.Headers.GetValues("Idempotency-Key").Single());
        // Inbound W3C context continues: the outbound client span belongs to the browser's trace.
        Assert.Equal("4bf92f3577b34da6a3ce929d0e0e4736", Assert.Single(_factory.Stub.TraceIds));
        Assert.Contains("SKU-0001", _factory.Stub.RequestBodies["http://orders.test/orders"], StringComparison.Ordinal);
    }

    [Fact]
    public async Task Get_IsRetried_OnTransientFailure_PostIsNot()
    {
        _factory.Stub.Script.Enqueue(_ => StubDownstream.Json(HttpStatusCode.ServiceUnavailable, "{}"));
        _factory.Stub.Script.Enqueue(_ => StubDownstream.Json(HttpStatusCode.OK, "{\"items\":[],\"count\":0}"));
        var client = _factory.CreateClient();
        var get = await client.GetAsync("/api/orders?limit=5", Ct);
        Assert.Equal(HttpStatusCode.OK, get.StatusCode);
        Assert.Equal(2, _factory.Stub.Requests.Count);
        Assert.EndsWith("orders?limit=5", _factory.Stub.Requests.Last().RequestUri!.ToString(), StringComparison.Ordinal);

        _factory.Stub.Requests.Clear();
        _factory.Stub.Script.Enqueue(_ => StubDownstream.Json(HttpStatusCode.ServiceUnavailable, "{\"title\":\"down\"}"));
        var post = new HttpRequestMessage(HttpMethod.Post, "/api/orders") { Content = JsonContent.Create(new { sku = "SKU-0001", quantity = 1, customer_ref = "c" }) };
        post.Headers.Add("Idempotency-Key", "k-2");
        Assert.Equal(HttpStatusCode.ServiceUnavailable, (await client.SendAsync(post, Ct)).StatusCode);
        Assert.Single(_factory.Stub.Requests);
    }

    [Fact]
    public async Task Inventory_NotConfigured_Returns503Problem()
    {
        var client = _factory.CreateClient();
        var response = await client.GetAsync("/api/inventory/SKU-0001", Ct);
        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        Assert.Equal("application/problem+json", response.Content.Headers.ContentType?.MediaType);
    }

    [Fact]
    public async Task Adapters_ListAndRoundtrip()
    {
        var client = _factory.CreateClient();
        var list = await client.GetFromJsonAsync<JsonElement>("/api/adapters", Ct);
        Assert.Equal(2, list.GetArrayLength());
        Assert.Equal("sql", list[0].GetProperty("family").GetString());

        _factory.Stub.Script.Enqueue(_ => StubDownstream.Json(HttpStatusCode.OK, "{\"family\":\"redis\",\"ok\":true}"));
        var rt = await client.PostAsync("/api/adapters/redis/roundtrip", null, Ct);
        Assert.Equal(HttpStatusCode.OK, rt.StatusCode);
        Assert.Equal("http://dbadapter-redis.test/roundtrip", _factory.Stub.Requests.Last().RequestUri!.ToString());

        Assert.Equal(HttpStatusCode.NotFound, (await client.PostAsync("/api/adapters/nope/roundtrip", null, Ct)).StatusCode);
    }

    [Fact]
    public async Task EntraMode_RequiresBearerToken_ProbesStayOpen()
    {
        _factory.Settings["AUTH_MODE"] = "entra";
        _factory.Settings["ENTRA_TENANT_ID"] = "00000000-0000-0000-0000-000000000001";
        _factory.Settings["ENTRA_AUDIENCE"] = "api://hello-bff";
        var client = _factory.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/api/orders", Ct)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/api/healthz", Ct)).StatusCode);
        Assert.Empty(_factory.Stub.Requests);
    }

    [Fact]
    public async Task RateLimit_Returns429Problem()
    {
        _factory.Settings["RATE_LIMIT_PERMIT_LIMIT"] = "2";
        _factory.Settings["RATE_LIMIT_WINDOW_SECONDS"] = "60";
        var client = _factory.CreateClient();
        await client.GetAsync("/api/catalog/products", Ct);
        await client.GetAsync("/api/catalog/products", Ct);
        var limited = await client.GetAsync("/api/catalog/products", Ct);
        Assert.Equal(HttpStatusCode.TooManyRequests, limited.StatusCode);
        Assert.Equal("application/problem+json", limited.Content.Headers.ContentType?.MediaType);
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/healthz", Ct)).StatusCode);
    }

    [Fact]
    public async Task DependencyTimeoutFault_Returns504AfterBoundedTimeout()
    {
        var client = _factory.CreateClient();
        var fault = new HttpRequestMessage(HttpMethod.Post, "/admin/faults") { Content = JsonContent.Create(new { type = "dependency_timeout", rate = 1, duration_seconds = 60 }) };
        fault.Headers.Add("X-Fault-Token", "tok");
        Assert.Equal(HttpStatusCode.Created, (await client.SendAsync(fault, Ct)).StatusCode);

        var sw = System.Diagnostics.Stopwatch.StartNew();
        var response = await client.GetAsync("/api/catalog/products", Ct);
        Assert.Equal(HttpStatusCode.GatewayTimeout, response.StatusCode);
        Assert.InRange(sw.Elapsed.TotalSeconds, 1.5, 9);
        Assert.Empty(_factory.Stub.Requests);
    }
}
