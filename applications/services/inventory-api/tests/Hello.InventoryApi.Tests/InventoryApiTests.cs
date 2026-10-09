using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;

namespace Hello.InventoryApi.Tests;

public sealed class InventoryApiFactory : WebApplicationFactory<Program>
{
    public Dictionary<string, string?> Settings { get; } = new()
    {
        ["STORAGE_MODE"] = "memory",
        ["DD_SERVICE"] = "hello-inventory-api",
        ["DD_VERSION"] = "1.0.0",
        ["LOG_LEVEL"] = "warning",
        ["FAULTS_ENABLED"] = "true",
        ["FAULT_TOKEN"] = "t0ken",
    };

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        foreach (var (k, v) in Settings)
        {
            builder.UseSetting(k, v);
        }
    }
}

public sealed class InventoryApiTests : IDisposable
{
    private readonly InventoryApiFactory _factory = new();

    public void Dispose() => _factory.Dispose();

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private async Task<HttpClient> SeededClientAsync()
    {
        var client = _factory.CreateClient();
        var seed = await client.PostAsync("/inventory/seed", null, Ct);
        Assert.Equal(HttpStatusCode.OK, seed.StatusCode);
        Assert.Equal(20, (await seed.Content.ReadFromJsonAsync<JsonElement>(Ct)).GetProperty("seeded").GetInt32());
        return client;
    }

    [Fact]
    public async Task OperationalEndpoints()
    {
        var client = _factory.CreateClient();
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/healthz", Ct)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/readyz", Ct)).StatusCode);
        var version = await client.GetFromJsonAsync<JsonElement>("/version", Ct);
        Assert.Equal("hello-inventory-api", version.GetProperty("service").GetString());
    }

    [Fact]
    public async Task Seed_IsDeterministic()
    {
        var client = await SeededClientAsync();
        var item = await client.GetFromJsonAsync<JsonElement>("/inventory/SKU-0001", Ct);
        Assert.Equal(110, item.GetProperty("quantity").GetInt32());
        var last = await client.GetFromJsonAsync<JsonElement>("/inventory/SKU-0020", Ct);
        Assert.Equal(300, last.GetProperty("quantity").GetInt32());
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync("/inventory/SKU-9999", Ct)).StatusCode);
    }

    [Fact]
    public async Task Reserve_IsIdempotentByOrderId_AndReleaseCompensates()
    {
        var client = await SeededClientAsync();
        var orderId = Guid.NewGuid();

        var first = await client.PostAsJsonAsync("/inventory/SKU-0002/reserve", new { order_id = orderId, quantity = 5 }, Ct);
        Assert.Equal(HttpStatusCode.OK, first.StatusCode);
        var body = await first.Content.ReadFromJsonAsync<JsonElement>(Ct);
        Assert.False(body.GetProperty("replayed").GetBoolean());
        Assert.Equal("reserved", body.GetProperty("status").GetString());

        var second = await (await client.PostAsJsonAsync("/inventory/SKU-0002/reserve", new { order_id = orderId, quantity = 5 }, Ct)).Content.ReadFromJsonAsync<JsonElement>(Ct);
        Assert.True(second.GetProperty("replayed").GetBoolean());

        var item = await client.GetFromJsonAsync<JsonElement>("/inventory/SKU-0002", Ct);
        Assert.Equal(115, item.GetProperty("quantity").GetInt32());
        Assert.Equal(5, item.GetProperty("reserved").GetInt32());

        var release = await (await client.PostAsJsonAsync("/inventory/SKU-0002/release", new { order_id = orderId }, Ct)).Content.ReadFromJsonAsync<JsonElement>(Ct);
        Assert.Equal("released", release.GetProperty("status").GetString());
        var releaseAgain = await (await client.PostAsJsonAsync("/inventory/SKU-0002/release", new { order_id = orderId }, Ct)).Content.ReadFromJsonAsync<JsonElement>(Ct);
        Assert.True(releaseAgain.GetProperty("replayed").GetBoolean());

        item = await client.GetFromJsonAsync<JsonElement>("/inventory/SKU-0002", Ct);
        Assert.Equal(120, item.GetProperty("quantity").GetInt32());
        Assert.Equal(0, item.GetProperty("reserved").GetInt32());
    }

    [Fact]
    public async Task Reserve_Insufficient_Returns409Problem()
    {
        var client = await SeededClientAsync();
        var response = await client.PostAsJsonAsync("/inventory/SKU-0001/reserve", new { order_id = Guid.NewGuid(), quantity = 999 }, Ct);
        Assert.Equal(HttpStatusCode.Conflict, response.StatusCode);
        Assert.Equal("application/problem+json", response.Content.Headers.ContentType?.MediaType);
        var problem = await response.Content.ReadFromJsonAsync<JsonElement>(Ct);
        Assert.Equal("urn:enterprise-hello:problem:insufficient-stock", problem.GetProperty("type").GetString());
        Assert.Equal(110, problem.GetProperty("available").GetInt32());
    }

    [Fact]
    public async Task Put_SetsQuantity_ValidatesInput()
    {
        var client = _factory.CreateClient();
        var put = await client.PutAsJsonAsync("/inventory/SKU-X1", new { quantity = 7 }, Ct);
        Assert.Equal(HttpStatusCode.OK, put.StatusCode);
        Assert.Equal(7, (await client.GetFromJsonAsync<JsonElement>("/inventory/SKU-X1", Ct)).GetProperty("quantity").GetInt32());
        Assert.Equal(HttpStatusCode.BadRequest, (await client.PutAsJsonAsync("/inventory/SKU-X1", new { quantity = -1 }, Ct)).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await client.PostAsJsonAsync("/inventory/SKU-X1/reserve", new { quantity = 1 }, Ct)).StatusCode);
    }

    [Fact]
    public async Task DbErrorFault_Returns503()
    {
        var client = await SeededClientAsync();
        var fault = new HttpRequestMessage(HttpMethod.Post, "/admin/faults") { Content = JsonContent.Create(new { type = "db_error", rate = 1, duration_seconds = 30 }) };
        fault.Headers.Add("X-Fault-Token", "t0ken");
        Assert.Equal(HttpStatusCode.Created, (await client.SendAsync(fault, Ct)).StatusCode);
        Assert.Equal(HttpStatusCode.ServiceUnavailable, (await client.GetAsync("/inventory/SKU-0001", Ct)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/healthz", Ct)).StatusCode);
    }
}
