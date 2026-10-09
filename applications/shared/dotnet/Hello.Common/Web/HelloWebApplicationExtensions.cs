using System.Diagnostics;
using System.Text.Json;
using Hello.Common.Faults;
using Hello.Common.Logging;
using Hello.Common.Operational;
using Hello.Common.Problems;
using Hello.Common.Secrets;
using Hello.Common.Telemetry;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Json;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Hello.Common.Web;

public static class HelloWebApplicationExtensions
{
    /// <summary>JSON options used on the wire by every Enterprise Hello .NET service (snake_case).</summary>
    public static readonly JsonSerializerOptions WireJson = CreateWireJson();

    public static JsonSerializerOptions CreateWireJson()
    {
        var o = new JsonSerializerOptions(JsonSerializerDefaults.Web)
        {
            PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
            DictionaryKeyPolicy = null,
        };
        return o;
    }

    /// <summary>
    /// Common service wiring: dsv:// secret references (Delinea DSV, resolved first), identity, PORT binding, JSON logging, OpenTelemetry, metrics, faults, problem details.
    /// </summary>
    public static WebApplicationBuilder AddHelloServiceDefaults(
        this WebApplicationBuilder builder,
        string defaultServiceName,
        Action<HelloTelemetryOptions>? telemetry = null)
    {
        ArgumentNullException.ThrowIfNull(builder);

        // ADR-0001 §14: every configuration value starting with dsv:// is resolved from Delinea DSV right here, before
        // anything reads configuration (fails fast naming the key; values are never logged).
        builder.Configuration.AddDsvSecrets();
        var info = HelloServiceInfo.FromConfiguration(builder.Configuration, defaultServiceName);
        builder.Services.AddSingleton(info);

        // PORT (default 8080) unless the host already configured URLs (ASPNETCORE_URLS / ASPNETCORE_HTTP_PORTS / IIS).
        var urls = builder.Configuration["ASPNETCORE_URLS"] ?? builder.Configuration["urls"];
        var httpPorts = builder.Configuration["ASPNETCORE_HTTP_PORTS"] ?? builder.Configuration["http_ports"];
        var port = builder.Configuration["PORT"];
        // Behind IIS / App Service Windows the ASP.NET Core Module owns the port (ASPNETCORE_PORT, in- or out-of-process).
        var behindIis = !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("ASPNETCORE_PORT"))
            || !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("ASPNETCORE_IIS_HTTPAUTH"));
        if (!behindIis && (!string.IsNullOrWhiteSpace(port) || (string.IsNullOrWhiteSpace(urls) && string.IsNullOrWhiteSpace(httpPorts))))
        {
            builder.WebHost.UseUrls($"http://+:{(string.IsNullOrWhiteSpace(port) ? "8080" : port.Trim())}");
        }

        builder.WebHost.ConfigureKestrel(k =>
        {
            k.AddServerHeader = false;
            k.Limits.MaxRequestBodySize = 1 * 1024 * 1024;
        });

        builder.Logging.AddHelloJsonLogging(builder.Configuration, info);
        builder.Services.AddHelloOpenTelemetry(builder.Configuration, info, telemetry);

        builder.Services.TryAddSingleton(TimeProvider.System);
        builder.Services.TryAddSingleton<HelloMetrics>();
        builder.Services.TryAddSingleton<FaultState>();

        builder.Services.Configure<JsonOptions>(o =>
        {
            o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower;
            o.SerializerOptions.DictionaryKeyPolicy = null;
        });

        builder.Services.AddProblemDetails(o => o.CustomizeProblemDetails = ctx => HelloProblems.Enrich(ctx.ProblemDetails, ctx.HttpContext));
        builder.Services.AddExceptionHandler<HelloExceptionHandler>();
        return builder;
    }

    /// <summary>Exception handling, status-code problem bodies, traceparent response header, fault middleware.</summary>
    public static WebApplication UseHelloServiceDefaults(this WebApplication app)
    {
        ArgumentNullException.ThrowIfNull(app);
        app.UseExceptionHandler();
        app.UseStatusCodePages();
        app.Use(static (context, next) =>
        {
            context.Response.OnStarting(static state =>
            {
                var ctx = (HttpContext)state;
                var traceparent = HelloTelemetry.ToTraceparent(Activity.Current);
                if (traceparent is not null && !ctx.Response.Headers.ContainsKey("traceparent"))
                {
                    ctx.Response.Headers["traceparent"] = traceparent;
                }

                return Task.CompletedTask;
            }, context);
            return next(context);
        });
        app.UseMiddleware<FaultInjectionMiddleware>();
        return app;
    }

    /// <summary>/healthz, /readyz, /version and /admin/faults.</summary>
    public static IEndpointRouteBuilder MapHelloServiceEndpoints(this IEndpointRouteBuilder endpoints)
    {
        endpoints.MapHelloOperationalEndpoints();
        endpoints.MapHelloFaultEndpoints();
        return endpoints;
    }
}
