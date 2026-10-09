using System.Diagnostics;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Hello.Common.Logging;

namespace Hello.Common.Operational;

/// <summary>A dependency the service owns (its database, its broker). /readyz runs every registered check with a 2 s timeout.</summary>
public interface IReadinessCheck
{
    string Name { get; }

    Task CheckAsync(CancellationToken cancellationToken);
}

/// <summary>Readiness check from a delegate.</summary>
public sealed class DelegateReadinessCheck(string name, Func<CancellationToken, Task> check) : IReadinessCheck
{
    public string Name { get; } = name;

    public Task CheckAsync(CancellationToken cancellationToken) => check(cancellationToken);
}

public sealed record VersionInfo(string Service, string Version, string Commit, string BuildTime, string Runtime);

public static class OperationalEndpoints
{
    public static readonly TimeSpan ReadinessTimeout = TimeSpan.FromSeconds(2);

    /// <summary>Maps {prefix}/healthz, {prefix}/readyz and {prefix}/version.</summary>
    public static IEndpointRouteBuilder MapHelloOperationalEndpoints(this IEndpointRouteBuilder endpoints, string prefix = "")
    {
        endpoints.MapGet($"{prefix}/healthz", (HelloServiceInfo info) => Results.Ok(new { status = "ok", service = info.Service }))
            .ExcludeFromDescription();

        endpoints.MapGet($"{prefix}/version", (HelloServiceInfo info) =>
                Results.Ok(new VersionInfo(info.Service, info.Version, info.Commit, info.BuildTime, info.Runtime)))
            .ExcludeFromDescription();

        endpoints.MapGet($"{prefix}/readyz", async (IEnumerable<IReadinessCheck> checks, HttpContext ctx) =>
            {
                var report = await RunChecksAsync(checks, ctx.RequestAborted).ConfigureAwait(false);
                var ready = report.Values.All(r => r.Status == "ok");
                return Results.Json(
                    new { status = ready ? "ready" : "not_ready", checks = report },
                    statusCode: ready ? StatusCodes.Status200OK : StatusCodes.Status503ServiceUnavailable);
            })
            .ExcludeFromDescription();

        return endpoints;
    }

    public sealed record CheckResult(string Status, double DurationMs, string? Error);

    public static async Task<IReadOnlyDictionary<string, CheckResult>> RunChecksAsync(IEnumerable<IReadinessCheck> checks, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(checks);
        var tasks = checks.Select(async check =>
        {
            var sw = Stopwatch.StartNew();
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            cts.CancelAfter(ReadinessTimeout);
            try
            {
                await check.CheckAsync(cts.Token).WaitAsync(ReadinessTimeout, cancellationToken).ConfigureAwait(false);
                return (check.Name, new CheckResult("ok", sw.Elapsed.TotalMilliseconds, null));
            }
            catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
            {
                var message = ex is TimeoutException or OperationCanceledException ? "timeout after 2s" : Truncate(Redactor.Redact(ex.Message), 300);
                return (check.Name, new CheckResult("failed", sw.Elapsed.TotalMilliseconds, $"{ex.GetType().Name}: {message}"));
            }
        });

        var results = await Task.WhenAll(tasks).ConfigureAwait(false);
        return results.ToDictionary(r => r.Name, r => r.Item2, StringComparer.Ordinal);
    }

    private static string Truncate(string value, int max) => value.Length <= max ? value : value[..max];
}
