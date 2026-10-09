using Hello.OrdersApi.Messaging;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;

namespace Hello.OrdersApi.Tests;

public sealed class OrdersApiFactory : WebApplicationFactory<Program>
{
    public Dictionary<string, string?> Settings { get; } = new()
    {
        ["STORAGE_MODE"] = "memory",
        ["MESSAGING_MODE"] = "log",
        ["PRICE_FALLBACK"] = "true",
        ["DD_SERVICE"] = "hello-orders-api",
        ["DD_ENV"] = "test",
        ["DD_VERSION"] = "9.9.9",
        ["GIT_COMMIT"] = "deadbeef",
        ["FAULTS_ENABLED"] = "true",
        ["FAULT_TOKEN"] = "test-token",
        ["LOG_LEVEL"] = "warning",
    };

    public Action<IServiceCollection>? ConfigureServices { get; set; }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        foreach (var (k, v) in Settings)
        {
            builder.UseSetting(k, v);
        }

        builder.ConfigureTestServices(s => ConfigureServices?.Invoke(s));
    }
}

internal sealed class FailingPublisher : IOrderEventPublisher
{
    public int Calls { get; private set; }

    public bool Fail { get; set; } = true;

    public Task PublishAsync(OrderCreatedEvent orderEvent, CancellationToken cancellationToken)
    {
        Calls++;
        return Fail ? throw new InvalidOperationException("broker down") : Task.CompletedTask;
    }
}
