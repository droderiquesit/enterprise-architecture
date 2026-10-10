using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Hello.Common.Telemetry;

/// <summary>The telemetry selection made by <see cref="OpenTelemetryExtensions.AddHelloOpenTelemetry"/>.</summary>
public sealed record HelloTelemetryState(TelemetrySdk Mode, bool OtelSdkDisabled, bool DatadogOtelMetrics)
{
    /// <summary>True when Hello.Common registered OpenTelemetry SDK providers.</summary>
    public bool OtelSdkActive => Mode == TelemetrySdk.Otel && !OtelSdkDisabled;
}

/// <summary>One start-up log line: mode, whether the Datadog tracer is attached, metrics route, profiler notes.</summary>
internal sealed class TelemetryStartupReporter(HelloTelemetryState state, IConfiguration configuration, ILogger<TelemetryStartupReporter> logger) : IHostedService
{
    public Task StartAsync(CancellationToken cancellationToken)
    {
        string? Setting(string key) => configuration[key] ?? Environment.GetEnvironmentVariable(key);
        var attached = HelloTelemetryMode.DatadogTracerAttached(Setting);
        var profiling = HelloTelemetryMode.IsTrue(Setting("DD_PROFILING_ENABLED"));
        var metrics = state.Mode == TelemetrySdk.Datadog ? (state.DatadogOtelMetrics ? "datadog-otel-bridge" : "dogstatsd") : (state.OtelSdkActive ? "otlp" : "none");
        if (state.Mode == TelemetrySdk.Otel && attached)
        {
            logger.LogWarning(
                "TELEMETRY_SDK=otel while the Datadog CLR profiler is attached: two tracers run in this process (set TELEMETRY_SDK=datadog)");
        }
        else if (state.Mode == TelemetrySdk.Datadog && !attached)
        {
            logger.LogWarning(
                "TELEMETRY_SDK=datadog but the Datadog CLR profiler is not attached (no CORECLR_PROFILER {Clsid}): no traces will be produced",
                HelloTelemetryMode.DatadogProfilerClsid);
        }

        if (state.Mode == TelemetrySdk.Datadog && state.OtelSdkDisabled)
        {
            // Datadog SDKs map OTEL_SDK_DISABLED=true to DD_TRACE_OTEL_ENABLED=false: Activity-based spans would be dropped.
            logger.LogWarning("OTEL_SDK_DISABLED=true with TELEMETRY_SDK=datadog disables the tracer's OpenTelemetry/Activity support (custom spans dropped)");
        }

        logger.LogInformation(
            "telemetry mode {telemetry_sdk} (datadog tracer attached={apm_tracer_attached}, metrics={apm_metrics}, otel sdk={otel_sdk})",
            state.Mode.ToString().ToLowerInvariant(),
            attached,
            metrics,
            state.OtelSdkActive);
        if (profiling && !attached)
        {
            // The .NET Continuous Profiler is part of the Datadog CLR profiler; without it DD_PROFILING_ENABLED has no effect.
            logger.LogInformation("DD_PROFILING_ENABLED is ignored: the Datadog CLR profiler is not attached to this process");
        }

        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
