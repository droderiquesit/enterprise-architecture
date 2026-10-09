using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Hello.Common.Faults;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Time.Testing;

namespace Hello.OrdersApi.Tests;

public sealed class FaultEndpointTests : IDisposable
{
    private readonly OrdersApiFactory _factory = new();

    public void Dispose() => _factory.Dispose();

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static HttpRequestMessage Post(object body, string? token)
    {
        var req = new HttpRequestMessage(HttpMethod.Post, "/admin/faults") { Content = JsonContent.Create(body) };
        if (token is not null)
        {
            req.Headers.Add("X-Fault-Token", token);
        }

        return req;
    }

    [Fact]
    public async Task Disabled_Returns404()
    {
        _factory.Settings["FAULTS_ENABLED"] = "false";
        var client = _factory.CreateClient();
        var response = await client.SendAsync(Post(new { type = "http_500", rate = 1, duration_seconds = 10 }, "test-token"), Ct);
        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Fact]
    public async Task WrongOrMissingToken_Returns403()
    {
        var client = _factory.CreateClient();
        Assert.Equal(HttpStatusCode.Forbidden, (await client.SendAsync(Post(new { type = "http_500", rate = 1, duration_seconds = 10 }, "nope"), Ct)).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await client.SendAsync(Post(new { type = "http_500", rate = 1, duration_seconds = 10 }, null), Ct)).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync("/admin/faults", Ct)).StatusCode);
    }

    [Fact]
    public async Task InvalidBody_Returns400()
    {
        var client = _factory.CreateClient();
        var response = await client.SendAsync(Post(new { type = "meteor", rate = 2, duration_seconds = 5000 }, "test-token"), Ct);
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Http500Fault_IsInjected_ThenExpires_ProbesUnaffected()
    {
        var time = new FakeTimeProvider(DateTimeOffset.UtcNow);
        _factory.ConfigureServices = s => s.AddSingleton(new FaultState(time));
        var client = _factory.CreateClient();

        var created = await client.SendAsync(Post(new { type = "http_500", rate = 1.0, duration_seconds = 60 }, "test-token"), Ct);
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);

        var listed = await (await client.SendAsync(new HttpRequestMessage(HttpMethod.Get, "/admin/faults") { Headers = { { "X-Fault-Token", "test-token" } } }, Ct))
            .Content.ReadFromJsonAsync<JsonElement>(Ct);
        Assert.Equal(1, listed.GetProperty("faults").GetArrayLength());

        var failed = await client.GetAsync("/orders", Ct);
        Assert.Equal(HttpStatusCode.InternalServerError, failed.StatusCode);
        Assert.Equal("application/problem+json", failed.Content.Headers.ContentType?.MediaType);
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/healthz", Ct)).StatusCode);

        time.Advance(TimeSpan.FromSeconds(61));
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/orders", Ct)).StatusCode);
    }

    [Fact]
    public async Task DbErrorFault_Returns503Problem_AndDeleteClears()
    {
        var client = _factory.CreateClient();
        await client.SendAsync(Post(new { type = "db_error", rate = 1.0, duration_seconds = 60 }, "test-token"), Ct);
        var failed = await client.GetAsync("/orders", Ct);
        Assert.Equal(HttpStatusCode.ServiceUnavailable, failed.StatusCode);
        var problem = await failed.Content.ReadFromJsonAsync<JsonElement>(Ct);
        Assert.Equal("urn:enterprise-hello:problem:fault-injected", problem.GetProperty("type").GetString());

        var delete = new HttpRequestMessage(HttpMethod.Delete, "/admin/faults");
        delete.Headers.Add("X-Fault-Token", "test-token");
        Assert.Equal(HttpStatusCode.NoContent, (await client.SendAsync(delete, Ct)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/orders", Ct)).StatusCode);
    }
}
