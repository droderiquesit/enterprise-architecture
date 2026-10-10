using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using OpenTelemetry;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

namespace Hello.Common.Telemetry;

/// <summary>Options for <see cref="OpenTelemetryExtensions.AddHelloOpenTelemetry"/>.</summary>
public sealed class HelloTelemetryOptions
{
    /// <summary>Instrument ASP.NET Core server requests (false for the Functions worker, which has its own).</summary>
    public bool AspNetCore { get; set; } = true;

    /// <summary>Add Microsoft.Data.SqlClient instrumentation (callers pass a delegate so this library has no SqlClient dependency).</summary>
    public Action<TracerProviderBuilder>? ConfigureTracing { get; set; }

    public Action<MeterProviderBuilder>? ConfigureMetrics { get; set; }
}

public static class OpenTelemetryExtensions
{
    /// <summary>Azure SDK ActivitySource support is behind this AppContext switch (Azure.Core distributed tracing).</summary>
    public const string AzureActivitySourceSwitch = "Azure.Experimental.EnableActivitySource";

    private static readonly string[] ProbePaths = ["/healthz", "/readyz", "/api/healthz"];

    /// <summary>
    /// TELEMETRY_SDK=otel (default): traces + metrics via OTLP (honours OTEL_EXPORTER_OTLP_* env vars). Logs are
    /// deliberately NOT exported via OTLP: application logs travel stdout/file → Fluent Bit → Datadog (ADR-0001 §10), so
    /// OTLP logs would duplicate them. Exporters are only attached when an OTLP endpoint is configured.
    /// <para>
    /// TELEMETRY_SDK=datadog, or OTEL_SDK_DISABLED=true: NO OpenTelemetry provider/exporter is registered and
    /// <c>null</c> is returned. In datadog mode the Datadog CLR profiler (SSI / serverless-init / site extension / tracer
    /// home in the image) traces the process; <see cref="HelloTelemetry.Source"/> Activities become Datadog spans with
    /// DD_TRACE_OTEL_ENABLED=true; hello.* metrics are forwarded to DogStatsD by <see cref="DogStatsdMetricsBridge"/> unless
    /// DD_METRICS_OTEL_ENABLED=true (then the tracer exports the Meter over OTLP to the Agent). Hello.Common never sets
    /// CORECLR_*/COR_*/DD_PROFILING_* — the injector's profiler (tracing + Continuous Profiler) is left untouched.
    /// </para>
    /// </summary>
    public static OpenTelemetryBuilder? AddHelloOpenTelemetry(
        this IServiceCollection services,
        IConfiguration configuration,
        HelloServiceInfo info,
        Action<HelloTelemetryOptions>? configure = null)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ArgumentNullException.ThrowIfNull(info);
        var options = new HelloTelemetryOptions();
        configure?.Invoke(options);

        AppContext.SetSwitch(AzureActivitySourceSwitch, true);

        var mode = HelloTelemetryMode.Resolve(configuration);
        var otelDisabled = HelloTelemetryMode.OtelSdkDisabled(configuration);
        services.TryAddSingleton(new HelloTelemetryState(mode, otelDisabled, HelloTelemetryMode.DatadogOtelMetrics(configuration)));
        services.AddHostedService<TelemetryStartupReporter>();
        if (mode == TelemetrySdk.Datadog)
        {
            if (!HelloTelemetryMode.DatadogOtelMetrics(configuration))
            {
                services.TryAddSingleton<IDogStatsdSink>(sp => new DogStatsdSink(configuration));
                services.TryAddSingleton<DogStatsdMetricsBridge>();
                services.AddHostedService(sp => sp.GetRequiredService<DogStatsdMetricsBridge>());
            }

            return null;
        }

        if (otelDisabled)
        {
            return null;
        }

        var tracesEndpoint = First(configuration["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"], configuration["OTEL_EXPORTER_OTLP_ENDPOINT"]);
        var metricsEndpoint = First(configuration["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"], configuration["OTEL_EXPORTER_OTLP_ENDPOINT"]);
        var temporalityFromEnv = !string.IsNullOrWhiteSpace(configuration["OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE"]);

        var builder = services.AddOpenTelemetry();
        builder.ConfigureResource(resource => resource
            .AddService(
                serviceName: info.Service,
                serviceNamespace: HelloServiceInfo.ServiceNamespace,
                serviceVersion: info.Version,
                autoGenerateServiceInstanceId: true)
            .AddAttributes(new Dictionary<string, object>
            {
                ["deployment.environment.name"] = info.Environment,
                // Legacy key still read by older Datadog mappings.
                ["deployment.environment"] = info.Environment,
                ["vcs.ref.head.revision"] = info.Commit,
                ["git.commit.sha"] = info.Commit,
            }));

        builder.WithTracing(tracing =>
        {
            tracing
                .AddSource(HelloTelemetry.ActivitySourceName)
                .AddSource("Azure.*")
                .AddHttpClientInstrumentation(o => o.RecordException = true);

            if (options.AspNetCore)
            {
                tracing.AddAspNetCoreInstrumentation(o =>
                {
                    o.RecordException = true;
                    o.Filter = ctx => !IsProbe(ctx.Request.Path);
                });
            }

            options.ConfigureTracing?.Invoke(tracing);

            if (!string.IsNullOrWhiteSpace(tracesEndpoint))
            {
                tracing.AddOtlpExporter();
            }
        });

        builder.WithMetrics(metrics =>
        {
            metrics
                .AddMeter(HelloMetrics.MeterName)
                .AddHttpClientInstrumentation()
                .AddRuntimeInstrumentation();

            if (options.AspNetCore)
            {
                metrics.AddAspNetCoreInstrumentation();
            }

            options.ConfigureMetrics?.Invoke(metrics);

            if (!string.IsNullOrWhiteSpace(metricsEndpoint))
            {
                metrics.AddOtlpExporter((_, reader) =>
                {
                    // Datadog recommends delta temporality for OTLP metrics; env var wins when the platform sets it.
                    if (!temporalityFromEnv)
                    {
                        reader.TemporalityPreference = MetricReaderTemporalityPreference.Delta;
                    }
                });
            }
        });

        return builder;
    }

    internal static bool IsProbe(PathString path)
    {
        foreach (var probe in ProbePaths)
        {
            if (path.Equals(probe, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static string? First(params string?[] values) =>
        values.FirstOrDefault(v => !string.IsNullOrWhiteSpace(v));
}
