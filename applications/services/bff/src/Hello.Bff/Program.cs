using System.Net;
using System.Threading.RateLimiting;
using Hello.Bff;
using Hello.Common.Http;
using Hello.Common.Problems;
using Hello.Common.Web;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Cors.Infrastructure;
using Microsoft.AspNetCore.HttpOverrides;

var builder = WebApplication.CreateBuilder(args);
builder.AddHelloServiceDefaults("hello-bff");
var services = builder.Services;

services.AddSingleton(sp => BffSettings.From(sp.GetRequiredService<IConfiguration>()));

// Typed clients: 5 s total, 2 s per attempt, 2 retries with jitter for GETs only, circuit breaker.
services.AddHelloHttpClient<CatalogApi, CatalogApi>("hello-catalog-api", sp => sp.GetRequiredService<BffSettings>().CatalogApiUrl);
services.AddHelloHttpClient<OrdersApi, OrdersApi>("hello-orders-api", sp => sp.GetRequiredService<BffSettings>().OrdersApiUrl);
services.AddHelloHttpClient<InventoryApi, InventoryApi>("hello-inventory-api", sp => sp.GetRequiredService<BffSettings>().InventoryApiUrl);
services.AddHelloHttpClient<AdaptersApi, AdaptersApi>("hello-dbadapter", _ => null, o =>
{
    o.TotalTimeout = TimeSpan.FromSeconds(20);
    o.AttemptTimeout = TimeSpan.FromSeconds(15);
    o.MaxRetryAttempts = 1;
});

// CORS for the SPA (+ Datadog RUM trace headers). Origins from CORS_ALLOWED_ORIGINS.
services.AddCors();
services.AddOptions<CorsOptions>().Configure<IServiceProvider>((o, sp) =>
{
    var settings = sp.GetRequiredService<BffSettings>();
    o.AddPolicy("frontend", p => p
        .WithOrigins([.. settings.AllowedOrigins])
        .WithMethods("GET", "POST", "OPTIONS")
        .WithHeaders(
            "content-type", "idempotency-key", "traceparent", "tracestate", "authorization",
            "x-datadog-origin", "x-datadog-parent-id", "x-datadog-sampling-priority", "x-datadog-trace-id", "x-datadog-tags")
        .WithExposedHeaders("traceparent", "Idempotent-Replayed")
        .SetPreflightMaxAge(TimeSpan.FromMinutes(10)));
});

// Fixed-window rate limit per client IP (probes exempt).
services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    o.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(ctx =>
    {
        var path = ctx.Request.Path;
        if (path.StartsWithSegments("/healthz") || path.StartsWithSegments("/readyz") || path.StartsWithSegments("/api/healthz"))
        {
            return RateLimitPartition.GetNoLimiter("probe");
        }

        var settings = ctx.RequestServices.GetRequiredService<BffSettings>();
        var ip = ctx.Connection.RemoteIpAddress?.ToString() ?? "unknown";
        return RateLimitPartition.GetFixedWindowLimiter(ip, _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = settings.RateLimitPermits,
            Window = settings.RateLimitWindow,
            QueueLimit = 0,
            AutoReplenishment = true,
        });
    });
    o.OnRejected = async (ctx, ct) =>
    {
        if (ctx.Lease.TryGetMetadata(MetadataName.RetryAfter, out var retry))
        {
            ctx.HttpContext.Response.Headers.RetryAfter = ((int)retry.TotalSeconds).ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        await HelloProblems.Result(StatusCodes.Status429TooManyRequests, "rate-limited", "Too many requests").ExecuteAsync(ctx.HttpContext).ConfigureAwait(false);
    };
});

// AUTH_MODE=entra: Entra ID JWT bearer (v1 + v2 issuers); otherwise anonymous.
services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer();
services.AddOptions<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme).Configure<IServiceProvider>((o, sp) =>
{
    var s = sp.GetRequiredService<BffSettings>();
    if (s.AuthMode != "entra")
    {
        return;
    }

    o.Authority = $"https://login.microsoftonline.com/{s.EntraTenantId}/v2.0";
    o.MapInboundClaims = false;
    o.TokenValidationParameters.ValidAudiences = string.IsNullOrWhiteSpace(s.EntraAudience)
        ? []
        : [s.EntraAudience, s.EntraAudience.StartsWith("api://", StringComparison.Ordinal) ? s.EntraAudience : $"api://{s.EntraAudience}"];
    o.TokenValidationParameters.ValidIssuers =
    [
        $"https://login.microsoftonline.com/{s.EntraTenantId}/v2.0",
        $"https://sts.windows.net/{s.EntraTenantId}/",
    ];
});
services.AddSingleton<IAuthorizationHandler, AuthModeHandler>();
services.AddAuthorizationBuilder().AddPolicy(BffEndpoints.ApiPolicy, p => p.AddRequirements(new AuthModeRequirement()));

services.Configure<ForwardedHeadersOptions>(o =>
{
    o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    o.ForwardLimit = 1;
    o.KnownIPNetworks.Clear();
    o.KnownProxies.Clear();
    o.KnownIPNetworks.Add(new System.Net.IPNetwork(IPAddress.Parse("10.0.0.0"), 8));
    o.KnownIPNetworks.Add(new System.Net.IPNetwork(IPAddress.Parse("172.16.0.0"), 12));
    o.KnownIPNetworks.Add(new System.Net.IPNetwork(IPAddress.Parse("192.168.0.0"), 16));
});

var app = builder.Build();
app.UseWhen(ctx => ctx.RequestServices.GetRequiredService<BffSettings>().ForwardedHeaders, b => b.UseForwardedHeaders());
// CORS first so preflights and error responses (problem+json) carry CORS headers too.
app.UseCors("frontend");
app.UseHelloServiceDefaults();
app.UseRateLimiter();
app.UseWhen(ctx => ctx.RequestServices.GetRequiredService<BffSettings>().AuthMode == "entra", b => b.UseAuthentication());
app.UseAuthorization();
app.MapHelloServiceEndpoints();
app.MapBffEndpoints();
app.Run();

/// <summary>Entry point marker for WebApplicationFactory.</summary>
public partial class Program;
