using Hello.Common;
using Hello.Common.Telemetry;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using OpenTelemetry;
using OpenTelemetry.Trace;

namespace Hello.Common.Tests;

public sealed class TelemetryResourceTests
{
    [Fact]
    public void Resource_HasServiceIdentity_EnvironmentKeys_AndOtelResourceAttributes()
    {
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["DD_SERVICE"] = "hello-orders-api",
            ["DD_ENV"] = "dev",
            ["DD_VERSION"] = "1.4.2",
            ["GIT_COMMIT"] = "abc1234",
            ["OTEL_RESOURCE_ATTRIBUTES"] = "team=hello,domain=orders,tier=backend",
        }).Build();
        var info = HelloServiceInfo.FromConfiguration(config, "fallback");

        var services = new ServiceCollection();
        services.AddSingleton<IConfiguration>(config);
        services.AddLogging();
        services.AddHelloOpenTelemetry(config, info, o => o.AspNetCore = false);
        using var sp = services.BuildServiceProvider();
        var attributes = sp.GetRequiredService<TracerProvider>().GetResource().Attributes.ToDictionary(a => a.Key, a => a.Value);

        Assert.Equal("hello-orders-api", attributes["service.name"]);
        Assert.Equal("1.4.2", attributes["service.version"]);
        Assert.Equal("enterprise-hello", attributes["service.namespace"]);
        Assert.Equal("dev", attributes["deployment.environment.name"]);
        Assert.Equal("dev", attributes["deployment.environment"]);
        Assert.Equal("hello", attributes["team"]);
        Assert.Equal("orders", attributes["domain"]);
        Assert.Equal("backend", attributes["tier"]);
        Assert.Equal("abc1234", attributes["git.commit.sha"]);
        Assert.True(attributes.ContainsKey("service.instance.id"));
    }
}
