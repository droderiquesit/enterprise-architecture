using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;
using Hello.Common.Problems;
using Hello.Common.Telemetry;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace Hello.Common.Faults;

public sealed record FaultRequest(
    [property: JsonPropertyName("type")] string? Type,
    [property: JsonPropertyName("rate")] double? Rate,
    [property: JsonPropertyName("latency_ms")] int? LatencyMs,
    [property: JsonPropertyName("duration_seconds")] int? DurationSeconds);

/// <summary>
/// Lab-only fault administration (ADR-0001 §9): disabled (404) unless FAULTS_ENABLED=true; requires header
/// X-Fault-Token equal (constant-time) to FAULT_TOKEN; faults auto-expire after duration_seconds (1..900).
/// </summary>
public static class FaultEndpoints
{
    public const string TokenHeader = "X-Fault-Token";

    public static IEndpointRouteBuilder MapHelloFaultEndpoints(this IEndpointRouteBuilder endpoints)
    {
        var group = endpoints.MapGroup("/admin/faults").ExcludeFromDescription();
        group.MapPost(string.Empty, (FaultRequest? body, HttpContext ctx, FaultState state, HelloMetrics metrics, ILoggerFactory lf) =>
        {
            var denied = Authorize(ctx);
            if (denied is not null)
            {
                return denied;
            }

            var errors = Validate(body);
            if (errors.Count > 0)
            {
                return Results.ValidationProblem(errors, title: "Invalid fault request", type: HelloProblems.TypeUri("validation"));
            }

            var fault = state.Activate(body!.Type!, body.Rate ?? 1.0, body.LatencyMs ?? 0, body.DurationSeconds!.Value);
            lf.CreateLogger("Hello.Faults").LogWarning(
                "Lab fault activated {fault_type} rate={fault_rate} latency_ms={fault_latency_ms} expires_at={fault_expires_at}",
                fault.Type, fault.Rate, fault.LatencyMs, fault.ExpiresAt);
            return Results.Json(fault, statusCode: StatusCodes.Status201Created);
        });

        group.MapGet(string.Empty, (HttpContext ctx, FaultState state) =>
            Authorize(ctx) ?? Results.Ok(new { faults = state.Active() }));

        group.MapDelete(string.Empty, (HttpContext ctx, FaultState state, ILoggerFactory lf) =>
        {
            var denied = Authorize(ctx);
            if (denied is not null)
            {
                return denied;
            }

            state.Clear();
            lf.CreateLogger("Hello.Faults").LogWarning("Lab faults cleared");
            return Results.NoContent();
        });

        return endpoints;
    }

    internal static IResult? Authorize(HttpContext ctx)
    {
        var config = ctx.RequestServices.GetRequiredService<IConfiguration>();
        if (!string.Equals(config["FAULTS_ENABLED"], "true", StringComparison.OrdinalIgnoreCase))
        {
            return HelloProblems.Result(StatusCodes.Status404NotFound, "not-found", "Not Found", "Fault injection is disabled.");
        }

        var expected = config["FAULT_TOKEN"];
        var provided = ctx.Request.Headers[TokenHeader].ToString();
        if (string.IsNullOrEmpty(expected) || !TokenEquals(provided, expected))
        {
            return HelloProblems.Result(StatusCodes.Status403Forbidden, "forbidden", "Forbidden", "Missing or invalid fault token.");
        }

        return null;
    }

    /// <summary>Constant-time comparison (hash both sides so length differences do not leak timing).</summary>
    public static bool TokenEquals(string? provided, string expected)
    {
        var a = SHA256.HashData(Encoding.UTF8.GetBytes(provided ?? string.Empty));
        var b = SHA256.HashData(Encoding.UTF8.GetBytes(expected));
        return CryptographicOperations.FixedTimeEquals(a, b) && !string.IsNullOrEmpty(provided);
    }

    private static Dictionary<string, string[]> Validate(FaultRequest? body)
    {
        var errors = new Dictionary<string, string[]>(StringComparer.Ordinal);
        if (body is null)
        {
            errors["body"] = ["A JSON body is required."];
            return errors;
        }

        if (body.Type is null || !FaultTypes.All.Contains(body.Type))
        {
            errors["type"] = [$"type must be one of: {string.Join(", ", FaultTypes.All)}."];
        }

        if (body.Rate is { } rate && (double.IsNaN(rate) || rate < 0 || rate > 1))
        {
            errors["rate"] = ["rate must be between 0 and 1."];
        }

        if (body.LatencyMs is { } latency && (latency < 0 || latency > 60_000))
        {
            errors["latency_ms"] = ["latency_ms must be between 0 and 60000."];
        }

        if (body.DurationSeconds is not { } duration || duration < 1 || duration > FaultState.MaxDurationSeconds)
        {
            errors["duration_seconds"] = [$"duration_seconds is required and must be between 1 and {FaultState.MaxDurationSeconds}."];
        }

        return errors;
    }
}
