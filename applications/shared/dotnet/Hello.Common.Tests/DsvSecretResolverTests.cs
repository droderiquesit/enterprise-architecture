using System.Collections.Concurrent;
using System.Net;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Hello.Common.Secrets;
using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Time.Testing;

namespace Hello.Common.Tests;

/// <summary>In-process emulation of the DSV REST subset used here (same semantics as tools/secrets/mock_dsv.py).</summary>
internal sealed class FakeDsvHandler : HttpMessageHandler
{
    public const string Mirid = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-orders";
    public const string FaultValue = "fault-token-VALUE-7f3a9c";
    public const string ApiValue = "dd-api-key-VALUE-0c41d2";
    public const string ClientSecret = "client-secret-VALUE-5b5b";

    private readonly ConcurrentDictionary<string, string> _tokens = new();

    public Dictionary<string, Dictionary<string, object>> Secrets { get; } = new()
    {
        ["eh/dev/orders/fault-token"] = new() { ["value"] = FaultValue },
        ["eh/dev/datadog-api-key"] = new() { ["value"] = ApiValue, ["site"] = "datadoghq.com" },
        ["eh/dev/orders/sql"] = new() { ["value"] = "pw-VALUE-1", ["port"] = 1433 },
    };

    public Dictionary<string, string[]> Policies { get; } = new()
    {
        [Mirid] = ["eh/dev/orders/", "eh/dev/datadog-api-key"],
        ["local-dev"] = ["eh/dev/"],
    };

    public ConcurrentQueue<string> Calls { get; } = new();

    public Queue<HttpStatusCode> InjectSecretStatus { get; } = new();

    public void RevokeAll() => _tokens.Clear();

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var path = request.RequestUri!.AbsolutePath;
        if (request.Method == HttpMethod.Post && path == "/v1/token")
        {
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(cancellationToken));
            string? identity = null;
            var grant = body.RootElement.GetProperty("grant_type").GetString();
            if (grant == "azure")
            {
                var payload = body.RootElement.GetProperty("jwt").GetString()!.Split('.')[1];
                payload = payload.PadRight(payload.Length + ((4 - (payload.Length % 4)) % 4), '=').Replace('-', '+').Replace('_', '/');
                using var claims = JsonDocument.Parse(Convert.FromBase64String(payload));
                identity = claims.RootElement.GetProperty("xms_mirid").GetString();
            }
            else if (grant == "client_credentials" && body.RootElement.GetProperty("client_id").GetString() == "local-client"
                && body.RootElement.GetProperty("client_secret").GetString() == ClientSecret)
            {
                identity = "local-dev";
            }

            Calls.Enqueue($"POST token {identity}");
            if (identity is null || !Policies.ContainsKey(identity))
            {
                return Json(HttpStatusCode.Unauthorized, new { message = "unauthorized" });
            }

            var token = Guid.NewGuid().ToString("N");
            _tokens[token] = identity;
            return Json(HttpStatusCode.OK, new { accessToken = token, tokenType = "bearer", expiresIn = 3600 });
        }

        if (request.Method == HttpMethod.Get && path.StartsWith("/v1/secrets/", StringComparison.Ordinal))
        {
            var secretPath = Uri.UnescapeDataString(path["/v1/secrets/".Length..]);
            Calls.Enqueue($"GET {secretPath}");
            if (InjectSecretStatus.TryDequeue(out var injected))
            {
                return Json(injected, new { message = "injected" });
            }

            var auth = request.Headers.Authorization?.Parameter;
            if (auth is null || !_tokens.TryGetValue(auth, out var who))
            {
                return Json(HttpStatusCode.Unauthorized, new { message = "unauthorized" });
            }

            if (!Policies[who].Any(p => p.EndsWith('/') ? secretPath.StartsWith(p, StringComparison.Ordinal) : secretPath == p))
            {
                return Json(HttpStatusCode.Forbidden, new { message = "forbidden" });
            }

            return Secrets.TryGetValue(secretPath, out var data)
                ? Json(HttpStatusCode.OK, new { id = secretPath, path = secretPath, data, version = "1" })
                : Json(HttpStatusCode.NotFound, new { message = "not found" });
        }

        return Json(HttpStatusCode.NotFound, new { message = "not found" });
    }

    private static HttpResponseMessage Json(HttpStatusCode status, object body) =>
        new(status) { Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json") };
}

internal sealed class FakeEntraCredential(string mirid = FakeDsvHandler.Mirid) : TokenCredential
{
    public List<string> Scopes { get; } = [];

    public static string FakeJwt(string mirid)
    {
        static string Enc(object o) => Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(o)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        return $"{Enc(new { alg = "none", typ = "JWT" })}.{Enc(new { xms_mirid = mirid, aud = "https://management.azure.com/" })}.sig";
    }

    public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
    {
        Scopes.AddRange(requestContext.Scopes);
        return new AccessToken(FakeJwt(mirid), DateTimeOffset.UtcNow.AddHours(1));
    }

    public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
        new(GetToken(requestContext, cancellationToken));
}

internal sealed class CapturingLogger : ILogger
{
    public StringBuilder Text { get; } = new();

    public IDisposable? BeginScope<TState>(TState state)
        where TState : notnull => null;

    public bool IsEnabled(LogLevel logLevel) => true;

    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
    {
        Text.AppendLine(formatter(state, exception));
        if (state is IEnumerable<KeyValuePair<string, object?>> kvs)
        {
            foreach (var kv in kvs)
            {
                Text.Append(kv.Key).Append('=').AppendLine(kv.Value?.ToString());
            }
        }

        Text.AppendLine(exception?.ToString());
    }
}

public sealed class DsvSecretResolverTests
{
    private static readonly Uri Base = new("https://dsv.example/v1/");

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static DsvOptions AzureOptions() => new() { Auth = DsvAuthMode.Azure, BaseUri = Base, AzureClientId = "11111111-2222-3333-4444-555555555555" };

    private static Task NoDelay(TimeSpan _, CancellationToken __) => Task.CompletedTask;

    [Theory]
    [InlineData("dsv://eh/dev/datadog-api-key#value", "eh/dev/datadog-api-key", "value")]
    [InlineData("dsv://eh/dev/datadog-api-key", "eh/dev/datadog-api-key", "value")]
    [InlineData("dsv:///eh/dev/orders/sql#port", "eh/dev/orders/sql", "port")]
    public void Parse_Valid(string reference, string path, string element) =>
        Assert.Equal(new DsvSecretReference(path, element), DsvSecretReference.Parse(reference));

    [Theory]
    [InlineData("dsv://")]
    [InlineData("dsv://eh/../x")]
    [InlineData("dsv://eh/dev/x?y=1")]
    [InlineData("dsv://eh/dev/x#a b")]
    [InlineData("https://x")]
    public void Parse_Malformed(string reference) => Assert.Throws<FormatException>(() => DsvSecretReference.Parse(reference));

    [Fact]
    public void Options_FromConfiguration_TenantUrl_And_HttpsPolicy()
    {
        static DsvOptions From(params (string K, string V)[] kv) =>
            DsvOptions.FromConfiguration(new ConfigurationBuilder().AddInMemoryCollection(kv.Select(x => new KeyValuePair<string, string?>(x.K, x.V))).Build());

        Assert.Equal(new Uri("https://contoso.secretsvaultcloud.eu/v1/"), From(("DSV_TENANT", "contoso"), ("DSV_TLD", "eu")).BaseUri);
        Assert.Equal(new Uri("https://contoso.secretsvaultcloud.com/v1/"), From(("DSV_TENANT", "contoso")).BaseUri);
        Assert.Throws<DsvConfigurationException>(() => From(("DSV_BASE_URL", "http://mock-dsv:8200/v1")).Validate());
        From(("DSV_BASE_URL", "http://mock-dsv:8200/v1"), ("DSV_ALLOW_INSECURE_HTTP", "true")).Validate();
        From(("DSV_BASE_URL", "http://127.0.0.1:8200/v1")).Validate();
        Assert.Throws<DsvConfigurationException>(() => From(("DSV_AUTH", "client_credentials"), ("DSV_BASE_URL", "https://x/v1")).Validate());
        Assert.Throws<DsvConfigurationException>(() => From(("DSV_AUTH", "kerberos")));
        Assert.DoesNotContain(FakeDsvHandler.ClientSecret, new DsvOptions { ClientSecret = FakeDsvHandler.ClientSecret }.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task AzureGrant_ResolvesValues_UsingArmScope()
    {
        var handler = new FakeDsvHandler();
        var cred = new FakeEntraCredential();
        using var resolver = new DsvSecretResolver(AzureOptions(), cred, handler);
        Assert.Equal(FakeDsvHandler.FaultValue, await resolver.ResolveAsync("dsv://eh/dev/orders/fault-token#value", Ct));
        Assert.Equal("1433", await resolver.ResolveAsync("dsv://eh/dev/orders/sql#port", Ct));
        Assert.Equal(["https://management.azure.com/.default"], cred.Scopes);
        Assert.Equal($"POST token {FakeDsvHandler.Mirid}", handler.Calls.First());
        Assert.Equal(1, resolver.TokenRequests);
    }

    [Fact]
    public async Task ClientCredentials_Grant()
    {
        var handler = new FakeDsvHandler();
        using var resolver = new DsvSecretResolver(
            new DsvOptions { Auth = DsvAuthMode.ClientCredentials, BaseUri = Base, ClientId = "local-client", ClientSecret = FakeDsvHandler.ClientSecret }, handler: handler);
        Assert.Equal(FakeDsvHandler.ApiValue, await resolver.ResolveAsync("dsv://eh/dev/datadog-api-key", Ct));
        Assert.Equal("POST token local-dev", handler.Calls.First());
    }

    [Theory]
    [InlineData("dsv://eh/dev/other/thing", "access denied, HTTP 403")]
    [InlineData("dsv://eh/dev/orders/missing", "not found, HTTP 404")]
    public async Task ClientErrors_AreNotRetried(string reference, string expected)
    {
        var handler = new FakeDsvHandler();
        using var resolver = new DsvSecretResolver(AzureOptions(), new FakeEntraCredential(), handler, delay: NoDelay);
        var ex = await Assert.ThrowsAsync<DsvSecretException>(() => resolver.ResolveAsync(reference, Ct));
        Assert.Contains(expected, ex.Message, StringComparison.Ordinal);
        Assert.Equal(1, handler.Calls.Count(c => c.StartsWith("GET", StringComparison.Ordinal)));
    }

    [Fact]
    public async Task UnknownIdentity_IsUnauthorized()
    {
        using var resolver = new DsvSecretResolver(AzureOptions(), new FakeEntraCredential("/subscriptions/x/unknown"), new FakeDsvHandler(), delay: NoDelay);
        var ex = await Assert.ThrowsAsync<DsvSecretException>(() => resolver.ResolveAsync("dsv://eh/dev/orders/fault-token", Ct));
        Assert.Equal("DSV authentication failed (HTTP 401)", ex.Message);
    }

    [Fact]
    public async Task TransientFailures_AreRetried_Bounded()
    {
        var handler = new FakeDsvHandler();
        handler.InjectSecretStatus.Enqueue(HttpStatusCode.ServiceUnavailable);
        handler.InjectSecretStatus.Enqueue(HttpStatusCode.TooManyRequests);
        var delays = new List<TimeSpan>();
        using var resolver = new DsvSecretResolver(AzureOptions(), new FakeEntraCredential(), handler, delay: (d, _) => { delays.Add(d); return Task.CompletedTask; });
        Assert.Equal(FakeDsvHandler.FaultValue, await resolver.ResolveAsync("dsv://eh/dev/orders/fault-token", Ct));
        Assert.Equal(2, delays.Count);
        Assert.All(delays, d => Assert.InRange(d, TimeSpan.Zero, TimeSpan.FromSeconds(2)));

        for (var i = 0; i < 3; i++)
        {
            handler.InjectSecretStatus.Enqueue(HttpStatusCode.InternalServerError);
        }

        var ex = await Assert.ThrowsAsync<DsvSecretException>(() => resolver.ResolveAsync("dsv://eh/dev/datadog-api-key", Ct));
        Assert.Contains("HTTP 500 after 3 attempts", ex.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Unreachable_FailsAfterBoundedAttempts()
    {
        var options = AzureOptions() with { BaseUri = new Uri("http://127.0.0.1:9/v1/"), Timeout = TimeSpan.FromSeconds(1) };
        using var resolver = new DsvSecretResolver(options, new FakeEntraCredential(), delay: NoDelay);
        var ex = await Assert.ThrowsAsync<DsvSecretException>(() => resolver.ResolveAsync("dsv://eh/dev/a", Ct));
        Assert.StartsWith("DSV authentication failed (DSV unreachable", ex.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task SecretCacheTtl_And_TokenRefreshAt80Percent()
    {
        var time = new FakeTimeProvider(DateTimeOffset.UtcNow);
        var handler = new FakeDsvHandler();
        using var resolver = new DsvSecretResolver(AzureOptions() with { CacheTtl = TimeSpan.FromSeconds(900) }, new FakeEntraCredential(), handler, time);
        const string reference = "dsv://eh/dev/orders/fault-token";
        await resolver.ResolveAsync(reference, Ct);
        await resolver.ResolveAsync(reference, Ct);
        Assert.Equal((1, 1, 1), (resolver.TokenRequests, resolver.SecretRequests, resolver.CacheHits));

        time.Advance(TimeSpan.FromSeconds(901));
        await resolver.ResolveAsync(reference, Ct);
        Assert.Equal((1, 2), (resolver.TokenRequests, resolver.SecretRequests));

        time.Advance(TimeSpan.FromSeconds(2880 - 901 - 1));
        await resolver.GetAccessTokenAsync(Ct);
        Assert.Equal(1, resolver.TokenRequests);
        time.Advance(TimeSpan.FromSeconds(2));
        await resolver.GetAccessTokenAsync(Ct);
        Assert.Equal(2, resolver.TokenRequests);
    }

    [Fact]
    public async Task Unauthorized_OnRead_DropsCachedToken()
    {
        var handler = new FakeDsvHandler();
        using var resolver = new DsvSecretResolver(AzureOptions(), new FakeEntraCredential(), handler);
        await resolver.GetAccessTokenAsync(Ct);
        handler.RevokeAll();
        var ex = await Assert.ThrowsAsync<DsvSecretException>(() => resolver.ResolveAsync("dsv://eh/dev/orders/fault-token", Ct));
        Assert.Contains("unauthorized", ex.Message, StringComparison.Ordinal);
        Assert.Equal(FakeDsvHandler.FaultValue, await resolver.ResolveAsync("dsv://eh/dev/orders/fault-token", Ct));
        Assert.Equal(2, resolver.TokenRequests);
    }

    [Fact]
    public void DefaultCredential_PicksWorkloadIdentity_WhenFederatedTokenFileSet()
    {
        Assert.IsType<global::Azure.Identity.WorkloadIdentityCredential>(DsvSecretResolver.CreateDefaultCredential(AzureOptions() with
        {
            FederatedTokenFile = "/var/run/secrets/azure/tokens/azure-identity-token",
            AzureTenantId = "00000000-0000-0000-0000-000000000000",
        }));
        Assert.IsType<global::Azure.Identity.ManagedIdentityCredential>(DsvSecretResolver.CreateDefaultCredential(AzureOptions()));
    }
}

public sealed class DsvConfigurationTests
{
    private static Dictionary<string, string?> Env(params (string K, string V)[] extra)
    {
        var d = new Dictionary<string, string?>
        {
            ["DSV_AUTH"] = "azure",
            ["DSV_BASE_URL"] = "https://dsv.example/v1",
            ["AZURE_CLIENT_ID"] = "11111111-2222-3333-4444-555555555555",
        };
        foreach (var (k, v) in extra)
        {
            d[k] = v;
        }

        return d;
    }

    [Fact]
    public void ConfigurationManager_ResolvesImmediately_BeforeAnythingReadsConfig()
    {
        var builder = WebApplication.CreateBuilder();
        builder.Configuration.AddInMemoryCollection(Env(
            ("FAULT_TOKEN", "dsv://eh/dev/orders/fault-token#value"),
            ("Datadog:ApiKey", "dsv://eh/dev/datadog-api-key"),
            ("SQL_PORT", "dsv://eh/dev/orders/sql#port"),
            ("PLAIN", "literal")));
        var handler = new FakeDsvHandler();
        builder.Configuration.AddDsvSecrets(o => { o.Handler = handler; o.Credential = new FakeEntraCredential(); });

        Assert.Equal(FakeDsvHandler.FaultValue, builder.Configuration["FAULT_TOKEN"]);
        Assert.Equal(FakeDsvHandler.ApiValue, builder.Configuration["Datadog:ApiKey"]);
        Assert.Equal("1433", builder.Configuration["SQL_PORT"]);
        Assert.Equal("literal", builder.Configuration["PLAIN"]);
        using var app = builder.Build();
        Assert.Equal(FakeDsvHandler.FaultValue, app.Configuration["FAULT_TOKEN"]);
        Assert.Single(handler.Calls, c => c.StartsWith("POST", StringComparison.Ordinal));
    }

    [Fact]
    public void ConfigurationBuilder_ResolvesAtBuild_AndEnvironmentVariablesWork()
    {
        var key = "HELLO_DSV_TEST_" + Guid.NewGuid().ToString("N")[..8].ToUpperInvariant();
        Environment.SetEnvironmentVariable(key, "dsv://eh/dev/orders/fault-token");
        try
        {
            var config = new ConfigurationBuilder()
                .AddInMemoryCollection(Env())
                .AddEnvironmentVariables()
                .AddDsvSecrets(o => { o.Handler = new FakeDsvHandler(); o.Credential = new FakeEntraCredential(); })
                .Build();
            Assert.Equal(FakeDsvHandler.FaultValue, config[key]);
        }
        finally
        {
            Environment.SetEnvironmentVariable(key, null);
        }
    }

    [Fact]
    public void NoReferences_IsNoOp_WithoutDsvSettings()
    {
        var handler = new FakeDsvHandler();
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?> { ["FAULT_TOKEN"] = "literal", ["DSV_AUTH"] = "none" })
            .AddDsvSecrets(o => o.Handler = handler)
            .Build();
        Assert.Equal("literal", config["FAULT_TOKEN"]);
        Assert.Empty(handler.Calls);
    }

    [Fact]
    public void AuthNone_WithReferences_FailsNamingKeys()
    {
        var ex = Assert.Throws<DsvSecretResolutionException>(() => new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?> { ["FAULT_TOKEN"] = "dsv://eh/dev/orders/fault-token", ["DSV_AUTH"] = "none" })
            .AddDsvSecrets()
            .Build());
        Assert.Contains("FAULT_TOKEN", ex.Message, StringComparison.Ordinal);
        Assert.Contains("DSV_AUTH=none", ex.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Failures_NameKeysOnly_AndNoValueIsLogged()
    {
        var logger = new CapturingLogger();
        var handler = new FakeDsvHandler();
        var ok = new ConfigurationBuilder()
            .AddInMemoryCollection(Env(("FAULT_TOKEN", "dsv://eh/dev/orders/fault-token"), ("DD_API_KEY", "dsv://eh/dev/datadog-api-key")))
            .AddDsvSecrets(o => { o.Handler = handler; o.Credential = new FakeEntraCredential(); o.Logger = logger; })
            .Build();
        Assert.Equal(FakeDsvHandler.ApiValue, ok["DD_API_KEY"]);

        var ex = Assert.Throws<DsvSecretResolutionException>(() => new ConfigurationBuilder()
            .AddInMemoryCollection(Env(("FAULT_TOKEN", "dsv://eh/dev/orders/fault-token"), ("DENIED", "dsv://eh/dev/other/x"), ("MISSING", "dsv://eh/dev/orders/nope")))
            .AddDsvSecrets(o => { o.Handler = handler; o.Credential = new FakeEntraCredential(); o.Logger = logger; })
            .Build());
        Assert.Contains("DENIED (DSV secret read failed (access denied, HTTP 403))", ex.Message, StringComparison.Ordinal);
        Assert.Contains("MISSING (DSV secret read failed (not found, HTTP 404))", ex.Message, StringComparison.Ordinal);
        Assert.DoesNotContain("FAULT_TOKEN", ex.Message, StringComparison.Ordinal);
        Assert.DoesNotContain("eh/dev/other", ex.Message, StringComparison.Ordinal);
        Assert.Equal(["DENIED", "MISSING"], ex.Keys);

        var text = logger.Text.ToString() + ex;
        Assert.Contains("DSV secrets resolved", text, StringComparison.Ordinal);
        Assert.Contains("DSV secret resolution failed", text, StringComparison.Ordinal);
        Assert.DoesNotContain(FakeDsvHandler.FaultValue, text, StringComparison.Ordinal);
        Assert.DoesNotContain(FakeDsvHandler.ApiValue, text, StringComparison.Ordinal);
    }

    [Fact]
    public void PeriodicRefresh_ReloadsChangedValues()
    {
        var time = new FakeTimeProvider(DateTimeOffset.UtcNow);
        var handler = new FakeDsvHandler();
        var options = new DsvOptions
        {
            BaseUri = new Uri("https://dsv.example/v1/"),
            CacheTtl = TimeSpan.FromSeconds(60),
            RefreshInterval = TimeSpan.FromSeconds(300),
        };
        var config = new ConfigurationBuilder()
            .AddInMemoryCollection(Env(("FAULT_TOKEN", "dsv://eh/dev/orders/fault-token")))
            .AddDsvSecrets(o => { o.Handler = handler; o.Credential = new FakeEntraCredential(); o.TimeProvider = time; o.Options = options; })
            .Build();
        var reloaded = 0;
        Microsoft.Extensions.Primitives.ChangeToken.OnChange(config.GetReloadToken, () => reloaded++);
        Assert.Equal(FakeDsvHandler.FaultValue, config["FAULT_TOKEN"]);

        handler.Secrets["eh/dev/orders/fault-token"]["value"] = "rotated-VALUE";
        time.Advance(TimeSpan.FromSeconds(301));
        Assert.Equal("rotated-VALUE", config["FAULT_TOKEN"]);
        Assert.Equal(1, reloaded);
    }
}
