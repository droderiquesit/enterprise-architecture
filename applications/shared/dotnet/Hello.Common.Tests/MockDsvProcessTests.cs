using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using Hello.Common.Secrets;
using Microsoft.Extensions.Configuration;

namespace Hello.Common.Tests;

/// <summary>Real HTTP (SocketsHttpHandler) against tools/secrets/mock_dsv.py in a child python3 process.</summary>
public sealed class MockDsvProcessTests : IAsyncLifetime
{
    private Process? _process;
    private string? _configPath;

    public Uri? BaseUri { get; private set; }

    public async ValueTask InitializeAsync()
    {
        var script = FindMockDsv();
        if (script is null)
        {
            return;
        }

        int port;
        using (var l = new TcpListener(IPAddress.Loopback, 0))
        {
            l.Start();
            port = ((IPEndPoint)l.LocalEndpoint).Port;
        }

        _configPath = Path.Combine(Path.GetTempPath(), $"mock-dsv-{Guid.NewGuid():N}.json");
        await File.WriteAllTextAsync(_configPath, JsonSerializer.Serialize(new
        {
            users = new Dictionary<string, object> { ["local-dev"] = new { read = new[] { "eh/dev/*" } } },
            clients = new Dictionary<string, object> { ["local-client"] = new { secret = FakeDsvHandler.ClientSecret, identity = "local-dev" } },
            secrets = new Dictionary<string, object> { ["eh/dev/orders/fault-token"] = new { value = FakeDsvHandler.FaultValue } },
        }));
        try
        {
            _process = Process.Start(new ProcessStartInfo("python3", [script, "--config", _configPath, "--port", port.ToString(System.Globalization.CultureInfo.InvariantCulture)])
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
            });
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return; // no python3: tests below become no-ops
        }

        var line = await _process!.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(20));
        if (line?.Contains("listening", StringComparison.Ordinal) == true)
        {
            BaseUri = new Uri($"http://127.0.0.1:{port}/v1/");
        }
    }

    public ValueTask DisposeAsync()
    {
        if (_process is { HasExited: false })
        {
            _process.Kill(entireProcessTree: true);
        }

        _process?.Dispose();
        if (_configPath is not null)
        {
            File.Delete(_configPath);
        }

        return ValueTask.CompletedTask;
    }

    [Fact]
    public void ClientCredentials_OverRealHttp_ResolvesConfiguration()
    {
        Assert.SkipWhen(BaseUri is null, "python3 or tools/secrets/mock_dsv.py not available");
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["DSV_AUTH"] = "client_credentials",
                ["DSV_BASE_URL"] = BaseUri!.ToString(),
                ["DSV_CLIENT_ID"] = "local-client",
                ["DSV_CLIENT_SECRET"] = FakeDsvHandler.ClientSecret,
                ["FAULT_TOKEN"] = "dsv://eh/dev/orders/fault-token#value",
            })
            .AddDsvSecrets()
            .Build();
        Assert.Equal(FakeDsvHandler.FaultValue, config["FAULT_TOKEN"]);
    }

    [Fact]
    public void AzureGrant_WithFakeEntraToken_OverRealHttp_UnknownIdentityIs401()
    {
        Assert.SkipWhen(BaseUri is null, "python3 or tools/secrets/mock_dsv.py not available");
        var ex = Assert.Throws<DsvSecretResolutionException>(() => new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?> { ["DSV_BASE_URL"] = BaseUri!.ToString(), ["X"] = "dsv://eh/dev/orders/fault-token" })
            .AddDsvSecrets(o => o.Credential = new FakeEntraCredential("/subscriptions/x/unknown"))
            .Build());
        Assert.Contains("X (DSV authentication failed (HTTP 401))", ex.Message, StringComparison.Ordinal);
    }

    private static string? FindMockDsv()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "tools", "secrets", "mock_dsv.py");
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }
}
