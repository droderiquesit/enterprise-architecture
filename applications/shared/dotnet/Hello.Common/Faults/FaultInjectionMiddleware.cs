using Hello.Common.Problems;
using Hello.Common.Telemetry;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

namespace Hello.Common.Faults;

/// <summary>Applies active latency / http_500 faults to application requests (never to probes or /admin).</summary>
public sealed partial class FaultInjectionMiddleware(RequestDelegate next, FaultState state, HelloMetrics metrics, ILogger<FaultInjectionMiddleware> logger)
{
    public async Task InvokeAsync(HttpContext context)
    {
        if (!IsExempt(context.Request.Path))
        {
            if (state.ShouldInject(FaultTypes.Latency, out var latency) && latency!.LatencyMs > 0)
            {
                metrics.FaultsInjected.Add(1, new KeyValuePair<string, object?>("fault.type", FaultTypes.Latency));
                LogInjected(logger, FaultTypes.Latency);
                await Task.Delay(latency.LatencyMs, context.RequestAborted).ConfigureAwait(false);
            }

            if (state.ShouldInject(FaultTypes.Http500, out _))
            {
                metrics.FaultsInjected.Add(1, new KeyValuePair<string, object?>("fault.type", FaultTypes.Http500));
                LogInjected(logger, FaultTypes.Http500);
                await HelloProblems.Result(StatusCodes.Status500InternalServerError, "fault-injected", "Injected fault", "A lab fault (http_500) was injected.")
                    .ExecuteAsync(context).ConfigureAwait(false);
                return;
            }
        }

        await next(context).ConfigureAwait(false);
    }

    internal static bool IsExempt(PathString path) =>
        path.StartsWithSegments("/admin", StringComparison.OrdinalIgnoreCase)
        || path.StartsWithSegments("/healthz", StringComparison.OrdinalIgnoreCase)
        || path.StartsWithSegments("/readyz", StringComparison.OrdinalIgnoreCase)
        || path.StartsWithSegments("/version", StringComparison.OrdinalIgnoreCase)
        || path.StartsWithSegments("/api/healthz", StringComparison.OrdinalIgnoreCase)
        || path.StartsWithSegments("/api/version", StringComparison.OrdinalIgnoreCase);

    [LoggerMessage(EventId = 9001, Level = LogLevel.Warning, Message = "Injected lab fault {fault_type}")]
    private static partial void LogInjected(ILogger logger, string fault_type);
}
