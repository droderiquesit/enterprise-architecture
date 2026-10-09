using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Hello.OrdersApi.Messaging;
using Microsoft.Extensions.DependencyInjection;

namespace Hello.OrdersApi.Tests;

public sealed class OrdersApiTests : IDisposable
{
    private readonly OrdersApiFactory _factory = new();

    public void Dispose() => _factory.Dispose();

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static HttpRequestMessage CreateOrder(string key, string sku = "SKU-0003", int quantity = 2, string customer = "cust-1")
    {
        var req = new HttpRequestMessage(HttpMethod.Post, "/orders")
        {
            Content = JsonContent.Create(new { sku, quantity, customer_ref = customer }),
        };
        req.Headers.Add("Idempotency-Key", key);
        return req;
    }

    [Fact]
    public async Task Healthz_Version_Readyz()
    {
        var client = _factory.CreateClient();
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/healthz", Ct)).StatusCode);

        var version = await client.GetFromJsonAsync<JsonElement>("/version", Ct);
        Assert.Equal("hello-orders-api", version.GetProperty("service").GetString());
        Assert.Equal("9.9.9", version.GetProperty("version").GetString());
        Assert.Equal("deadbeef", version.GetProperty("commit").GetString());
        Assert.True(version.TryGetProperty("build_time", out _));
        Assert.True(version.TryGetProperty("runtime", out _));

        // Memory mode: migrations complete immediately; allow the hosted service a moment.
        HttpResponseMessage ready = null!;
        for (var i = 0; i < 20; i++)
        {
            ready = await client.GetAsync("/readyz", Ct);
            if (ready.StatusCode == HttpStatusCode.OK)
            {
                break;
            }

            await Task.Delay(50, Ct);
        }

        Assert.Equal(HttpStatusCode.OK, ready.StatusCode);
    }

    [Fact]
    public async Task PostOrder_Returns202_PublishesEvent_WithTraceparent()
    {
        var client = _factory.CreateClient();
        var response = await client.SendAsync(CreateOrder("key-1"), Ct);
        Assert.Equal(HttpStatusCode.Accepted, response.StatusCode);
        Assert.True(response.Headers.Contains("traceparent"));

        var order = await response.Content.ReadFromJsonAsync<JsonElement>(Ct);
        Assert.Equal("Pending", order.GetProperty("status").GetString());
        Assert.Equal(12.50m, order.GetProperty("unit_price").GetDecimal()); // PRICE_FALLBACK: 5 + 2.5 * 3
        Assert.Equal(25.00m, order.GetProperty("amount").GetDecimal());
    }

    [Fact]
    public async Task PostOrder_IsIdempotent_SameKeySameBody_ReturnsSameOrder()
    {
        var client = _factory.CreateClient();
        var first = await (await client.SendAsync(CreateOrder("idem-1"), Ct)).Content.ReadFromJsonAsync<JsonElement>(Ct);
        var secondResponse = await client.SendAsync(CreateOrder("idem-1"), Ct);
        Assert.Equal(HttpStatusCode.Accepted, secondResponse.StatusCode);
        Assert.Equal("true", secondResponse.Headers.GetValues("Idempotent-Replayed").Single());
        var second = await secondResponse.Content.ReadFromJsonAsync<JsonElement>(Ct);
        Assert.Equal(first.GetProperty("id").GetString(), second.GetProperty("id").GetString());

        var publisher = _factory.Services.GetRequiredService<LogOrderEventPublisher>();
        Assert.Single(publisher.Published, p => p.Event.OrderId == Guid.Parse(first.GetProperty("id").GetString()!));
    }

    [Fact]
    public async Task PostOrder_SameKeyDifferentBody_Returns409Problem()
    {
        var client = _factory.CreateClient();
        await client.SendAsync(CreateOrder("idem-2", quantity: 1), Ct);
        var conflict = await client.SendAsync(CreateOrder("idem-2", quantity: 5), Ct);
        Assert.Equal(HttpStatusCode.Conflict, conflict.StatusCode);
        Assert.Equal("application/problem+json", conflict.Content.Headers.ContentType?.MediaType);
        var problem = await conflict.Content.ReadFromJsonAsync<JsonElement>(Ct);
        Assert.Equal("urn:enterprise-hello:problem:idempotency-key-reused", problem.GetProperty("type").GetString());
        Assert.Equal(409, problem.GetProperty("status").GetInt32());
        Assert.True(problem.TryGetProperty("trace_id", out _));
    }

    [Fact]
    public async Task PostOrder_WithoutIdempotencyKey_Returns400Problem()
    {
        var client = _factory.CreateClient();
        var response = await client.PostAsJsonAsync("/orders", new { sku = "SKU-0001", quantity = 1, customer_ref = "c" }, Ct);
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Equal("application/problem+json", response.Content.Headers.ContentType?.MediaType);
    }

    [Fact]
    public async Task PostOrder_InvalidBody_Returns400ValidationProblem()
    {
        var client = _factory.CreateClient();
        var response = await client.SendAsync(CreateOrder("bad-1", quantity: 0), Ct);
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        var problem = await response.Content.ReadFromJsonAsync<JsonElement>(Ct);
        Assert.True(problem.GetProperty("errors").TryGetProperty("quantity", out _));
    }

    [Fact]
    public async Task GetOrder_Unknown_Returns404Problem()
    {
        var client = _factory.CreateClient();
        var response = await client.GetAsync($"/orders/{Guid.NewGuid()}", Ct);
        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
        Assert.Equal("application/problem+json", response.Content.Headers.ContentType?.MediaType);
    }

    [Fact]
    public async Task ListAndGet_ReturnCreatedOrders()
    {
        var client = _factory.CreateClient();
        var created = await (await client.SendAsync(CreateOrder("list-1"), Ct)).Content.ReadFromJsonAsync<JsonElement>(Ct);
        var id = created.GetProperty("id").GetString();
        var list = await client.GetFromJsonAsync<JsonElement>("/orders?limit=5", Ct);
        Assert.Contains(list.GetProperty("items").EnumerateArray(), o => o.GetProperty("id").GetString() == id);
        var single = await client.GetFromJsonAsync<JsonElement>($"/orders/{id}", Ct);
        Assert.Equal("cust-1", single.GetProperty("customer_ref").GetString());
    }

    [Fact]
    public async Task PatchStatus_ForwardOnly_IdempotentAndTerminal()
    {
        var client = _factory.CreateClient();
        var created = await (await client.SendAsync(CreateOrder("status-1"), Ct)).Content.ReadFromJsonAsync<JsonElement>(Ct);
        var id = created.GetProperty("id").GetString();

        var reserved = await client.PatchAsJsonAsync($"/orders/{id}/status", new { status = "Reserved", workflow_instance_id = $"order-{id}" }, Ct);
        Assert.Equal(HttpStatusCode.OK, reserved.StatusCode);
        var again = await client.PatchAsJsonAsync($"/orders/{id}/status", new { status = "Reserved" }, Ct);
        Assert.Equal(HttpStatusCode.OK, again.StatusCode);
        var fulfilled = await client.PatchAsJsonAsync($"/orders/{id}/status", new { status = "Fulfilled" }, Ct);
        var body = await fulfilled.Content.ReadFromJsonAsync<JsonElement>(Ct);
        Assert.Equal("Fulfilled", body.GetProperty("status").GetString());
        Assert.Equal($"order-{id}", body.GetProperty("workflow_instance_id").GetString());

        var back = await client.PatchAsJsonAsync($"/orders/{id}/status", new { status = "Failed" }, Ct);
        Assert.Equal(HttpStatusCode.Conflict, back.StatusCode);

        var invalid = await client.PatchAsJsonAsync($"/orders/{id}/status", new { status = "Bogus" }, Ct);
        Assert.Equal(HttpStatusCode.BadRequest, invalid.StatusCode);
    }

    [Fact]
    public async Task PublishFailure_MarksPublishFailed_AndRepublishRecovers()
    {
        var failing = new FailingPublisher();
        _factory.ConfigureServices = s => s.AddSingleton<IOrderEventPublisher>(failing);
        var client = _factory.CreateClient();

        var created = await (await client.SendAsync(CreateOrder("pub-1"), Ct)).Content.ReadFromJsonAsync<JsonElement>(Ct);
        Assert.Equal("PublishFailed", created.GetProperty("status").GetString());

        failing.Fail = false;
        var republished = await client.PostAsync($"/orders/{created.GetProperty("id").GetString()}/republish", null, Ct);
        Assert.Equal(HttpStatusCode.Accepted, republished.StatusCode);
        var body = await republished.Content.ReadFromJsonAsync<JsonElement>(Ct);
        Assert.Equal("Pending", body.GetProperty("status").GetString());
        Assert.Equal(2, failing.Calls);
    }

    [Fact]
    public async Task CatalogNotConfigured_WithoutFallback_Returns503()
    {
        _factory.Settings["PRICE_FALLBACK"] = "false";
        var client = _factory.CreateClient();
        var response = await client.SendAsync(CreateOrder("nocat-1"), Ct);
        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
    }
}
