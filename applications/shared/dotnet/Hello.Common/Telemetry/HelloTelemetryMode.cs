using Microsoft.Extensions.Configuration;

namespace Hello.Common.Telemetry;

/// <summary>Which tracer owns the process. Exactly one runs: never the OpenTelemetry SDK next to the Datadog tracer.</summary>
public enum TelemetrySdk
{
    /// <summary>OpenTelemetry SDK (TracerProvider/MeterProvider + OTLP exporters) configured by Hello.Common. Default.</summary>
    Otel,

    /// <summary>
    /// Datadog .NET tracer (CLR profiler attached by Single Step Instrumentation, serverless-init, the App Service site
    /// extension/sidecar or a tracer home baked into the image). Hello.Common registers no OpenTelemetry provider;
    /// Activity/Meter based code keeps working: Activities become Datadog spans with DD_TRACE_OTEL_ENABLED=true, hello.*
    /// metrics go to DogStatsD (or the tracer's OTel metrics bridge with DD_METRICS_OTEL_ENABLED=true).
    /// </summary>
    Datadog,
}

/// <summary>
/// Resolves <c>TELEMETRY_SDK</c> (<c>otel</c> | <c>datadog</c>). Unset ⇒ <c>otel</c>, unless the Datadog CLR profiler is
/// attached (then <c>datadog</c>, so an injected tracer never runs next to the OTel SDK). An explicit <c>otel</c> next to an
/// attached tracer is honoured (logged as a warning at start-up). Anything else fails fast.
/// </summary>
public static class HelloTelemetryMode
{
    /// <summary>CLSID of the Datadog .NET CLR profiler (Datadog.Trace.ClrProfiler.Native).</summary>
    public const string DatadogProfilerClsid = "{846F5F1C-F9AE-4B07-969E-05C26BC060D8}";

    public static TelemetrySdk Resolve(IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        return Resolve(key => configuration[key] ?? Environment.GetEnvironmentVariable(key));
    }

    public static TelemetrySdk Resolve(Func<string, string?> setting)
    {
        ArgumentNullException.ThrowIfNull(setting);
        var raw = setting("TELEMETRY_SDK")?.Trim();
        if (string.IsNullOrEmpty(raw))
        {
            return DatadogTracerAttached(setting) ? TelemetrySdk.Datadog : TelemetrySdk.Otel;
        }

        return raw.ToLowerInvariant() switch
        {
            "otel" => TelemetrySdk.Otel,
            "datadog" => TelemetrySdk.Datadog,
            _ => throw new InvalidOperationException($"TELEMETRY_SDK must be 'otel' or 'datadog', got '{raw}'."),
        };
    }

    /// <summary>
    /// True when the Datadog CLR profiler is configured for this process (CORECLR_* for .NET Core/5+, COR_* for .NET
    /// Framework) or the tracer's managed assembly is already loaded. Read-only: Hello.Common never sets these variables.
    /// </summary>
    public static bool DatadogTracerAttached(Func<string, string?> setting)
    {
        ArgumentNullException.ThrowIfNull(setting);
        static bool On(string? v) => v is not null && (v.Trim() == "1" || v.Trim().Equals("true", StringComparison.OrdinalIgnoreCase));
        static bool Clsid(string? v) => string.Equals(v?.Trim(), DatadogProfilerClsid, StringComparison.OrdinalIgnoreCase);
        if (On(setting("CORECLR_ENABLE_PROFILING")) && Clsid(setting("CORECLR_PROFILER")))
        {
            return true;
        }

        if (On(setting("COR_ENABLE_PROFILING")) && Clsid(setting("COR_PROFILER")))
        {
            return true;
        }

        return DatadogCorrelation.TracerAssemblyLoaded();
    }

    public static bool IsTrue(string? value) =>
        value is not null && (value.Trim() == "1" || value.Trim().Equals("true", StringComparison.OrdinalIgnoreCase));

    /// <summary>OTEL_SDK_DISABLED=true: no OpenTelemetry provider is created (either mode).</summary>
    public static bool OtelSdkDisabled(IConfiguration configuration) => IsTrue(configuration["OTEL_SDK_DISABLED"]);

    /// <summary>DD_METRICS_OTEL_ENABLED=true (datadog mode): the tracer exports System.Diagnostics.Metrics over OTLP itself.</summary>
    public static bool DatadogOtelMetrics(IConfiguration configuration) => IsTrue(configuration["DD_METRICS_OTEL_ENABLED"]);
}
