using System.Collections;
using System.Diagnostics;
using System.Diagnostics.Metrics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Hello.Common;
using Hello.Common.Logging;
using Hello.Common.Telemetry;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;

namespace Hello.Common.Tests;

public sealed class TelemetryModeTests
{
    private static readonly HelloServiceInfo Info = new("hello-test", "dev", "1.2.3", "abc123", "2026-10-09T00:00:00Z", ".NET");

    private static IConfiguration Config(params (string Key, string? Value)[] values) =>
        new ConfigurationBuilder().AddInMemoryCollection(values.Select(v => new KeyValuePair<string, string?>(v.Key, v.Value))).Build();

    private static Func<string, string?> Settings(params (string Key, string Value)[] values)
    {
        var map = values.ToDictionary(v => v.Key, v => v.Value);
        return key => map.TryGetValue(key, out var v) ? v : null;
    }

    [Fact]
    public void Mode_DefaultsToOtel_AndParsesDatadog()
    {
        Assert.Equal(TelemetrySdk.Otel, HelloTelemetryMode.Resolve(Settings()));
        Assert.Equal(TelemetrySdk.Datadog, HelloTelemetryMode.Resolve(Settings(("TELEMETRY_SDK", "datadog"))));
        Assert.Equal(TelemetrySdk.Otel, HelloTelemetryMode.Resolve(Settings(("TELEMETRY_SDK", " OTel "))));
        Assert.Throws<InvalidOperationException>(() => HelloTelemetryMode.Resolve(Settings(("TELEMETRY_SDK", "dd"))));
    }

    [Fact]
    public void Mode_UnsetWithAttachedDatadogProfiler_IsDatadog_ExplicitOtelIsHonoured()
    {
        var attached = new[] { ("CORECLR_ENABLE_PROFILING", "1"), ("CORECLR_PROFILER", "{846f5f1c-f9ae-4b07-969e-05c26bc060d8}") };
        Assert.True(HelloTelemetryMode.DatadogTracerAttached(Settings(attached)));
        Assert.Equal(TelemetrySdk.Datadog, HelloTelemetryMode.Resolve(Settings(attached)));
        Assert.Equal(TelemetrySdk.Otel, HelloTelemetryMode.Resolve(Settings([.. attached, ("TELEMETRY_SDK", "otel")])));
        // another vendor's profiler is not the Datadog tracer
        Assert.False(HelloTelemetryMode.DatadogTracerAttached(Settings(("CORECLR_ENABLE_PROFILING", "1"), ("CORECLR_PROFILER", "{00000000-0000-0000-0000-000000000000}"))));
    }

    [Fact]
    public void DatadogMode_RegistersNoOpenTelemetryProvider_AndTheDogStatsdBridge()
    {
        var config = Config(("TELEMETRY_SDK", "datadog"), ("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4317"));
        var services = new ServiceCollection();
        services.AddSingleton(config);
        services.AddLogging();
        var builder = services.AddHelloOpenTelemetry(config, Info, o => o.AspNetCore = false);
        Assert.Null(builder);
        Assert.DoesNotContain(services, d => d.ServiceType.Namespace?.StartsWith("OpenTelemetry", StringComparison.Ordinal) == true);
        using var sp = services.BuildServiceProvider();
        Assert.Null(sp.GetService<TracerProvider>());
        Assert.Null(sp.GetService<MeterProvider>());
        Assert.Equal(TelemetrySdk.Datadog, sp.GetRequiredService<HelloTelemetryState>().Mode);
        Assert.Contains(sp.GetServices<IHostedService>(), s => s is DogStatsdMetricsBridge);
    }

    [Fact]
    public void DatadogMode_WithOtelMetricsBridge_HasNoDogStatsdBridge()
    {
        var config = Config(("TELEMETRY_SDK", "datadog"), ("DD_METRICS_OTEL_ENABLED", "true"));
        var services = new ServiceCollection();
        services.AddSingleton(config);
        services.AddLogging();
        services.AddHelloOpenTelemetry(config, Info, o => o.AspNetCore = false);
        using var sp = services.BuildServiceProvider();
        Assert.DoesNotContain(sp.GetServices<IHostedService>(), s => s is DogStatsdMetricsBridge);
        Assert.Null(sp.GetService<MeterProvider>());
    }

    [Fact]
    public void OtelSdkDisabled_RegistersNoProvider()
    {
        var config = Config(("OTEL_SDK_DISABLED", "true"), ("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4317"));
        var services = new ServiceCollection();
        services.AddSingleton(config);
        services.AddLogging();
        Assert.Null(services.AddHelloOpenTelemetry(config, Info, o => o.AspNetCore = false));
        using var sp = services.BuildServiceProvider();
        Assert.Null(sp.GetService<TracerProvider>());
        Assert.False(sp.GetRequiredService<HelloTelemetryState>().OtelSdkActive);
    }

    [Fact]
    public void OtelMode_StillRegistersProviders()
    {
        var config = Config();
        var services = new ServiceCollection();
        services.AddSingleton(config);
        services.AddLogging();
        Assert.NotNull(services.AddHelloOpenTelemetry(config, Info, o => o.AspNetCore = false));
        using var sp = services.BuildServiceProvider();
        Assert.NotNull(sp.GetService<TracerProvider>());
        Assert.True(sp.GetRequiredService<HelloTelemetryState>().OtelSdkActive);
    }

    [Fact]
    public async Task DatadogMode_NeverWritesProfilerOrDatadogEnvironmentVariables()
    {
        static Dictionary<string, string?> Snapshot() => Environment.GetEnvironmentVariables().Cast<DictionaryEntry>()
            .Where(e => e.Key.ToString()!.StartsWith("COR", StringComparison.Ordinal) || e.Key.ToString()!.StartsWith("DD_", StringComparison.Ordinal))
            .ToDictionary(e => e.Key.ToString()!, e => e.Value?.ToString());
        var before = Snapshot();
        var config = Config(("TELEMETRY_SDK", "datadog"), ("DD_PROFILING_ENABLED", "1"));
        var services = new ServiceCollection();
        services.AddSingleton(config);
        services.AddLogging();
        services.AddHelloOpenTelemetry(config, Info, o => o.AspNetCore = false);
        await using (var sp = services.BuildServiceProvider())
        {
            foreach (var hosted in sp.GetServices<IHostedService>())
            {
                await hosted.StartAsync(TestContext.Current.CancellationToken);
            }
        }

        Assert.Equal(before, Snapshot());
    }

    [Fact]
    public void LogCorrelation_UsesActiveDatadogSpan_WithSameFieldNames()
    {
        DatadogCorrelation.UseAssembly(typeof(Datadog.Trace.Tracer).Assembly);
        try
        {
            var writer = new HelloJsonLogWriter(Info);
            using (Datadog.Trace.Tracer.Activate(traceIdLow: 11803532876627986230UL, spanId: 67667974448284343UL, rawTraceId: "4bf92f3577b34da6a3ce929d0e0e4736"))
            {
                var root = Parse(writer);
                Assert.Equal("4bf92f3577b34da6a3ce929d0e0e4736", root.GetProperty("trace_id").GetString());
                Assert.Equal("00f067aa0ba902b7", root.GetProperty("span_id").GetString());
                Assert.Equal("11803532876627986230", root.GetProperty("dd.trace_id").GetString());
                Assert.Equal("67667974448284343", root.GetProperty("dd.span_id").GetString());
            }

            // tracer without the 128-bit raw id: the low 64 bits padded to the 32-hex shape
            using (Datadog.Trace.Tracer.Activate(traceIdLow: 255UL, spanId: 16UL, rawTraceId: null))
            {
                var root = Parse(writer);
                Assert.Equal("000000000000000000000000000000ff", root.GetProperty("trace_id").GetString());
                Assert.Equal("0000000000000010", root.GetProperty("span_id").GetString());
                Assert.Equal("255", root.GetProperty("dd.trace_id").GetString());
            }

            // no Datadog span and no Activity: correlation fields omitted
            Assert.Null(Activity.Current);
            var none = Parse(writer);
            Assert.False(none.TryGetProperty("trace_id", out _));
            Assert.False(none.TryGetProperty("dd.trace_id", out _));
            Assert.Equal("hello-test", none.GetProperty("dd.service").GetString());
        }
        finally
        {
            DatadogCorrelation.UseAssembly(null);
        }
    }

    [Fact]
    public async Task DogStatsdBridge_SendsHelloMetrics_ToUdpListener_WithBoundedTags()
    {
        using var udp = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        var port = ((IPEndPoint)udp.Client.LocalEndPoint!).Port;
        var config = Config(
            ("DD_DOGSTATSD_URL", $"udp://127.0.0.1:{port}"),
            ("DD_ENV", "dev"),
            ("DD_SERVICE", "hello-durable"),
            ("DD_VERSION", "1.2.3"));

        var services = new ServiceCollection();
        services.AddMetrics();
        using var sp = services.BuildServiceProvider();
        using var metrics = new HelloMetrics(sp.GetRequiredService<IMeterFactory>(), Info);
        using var bridge = new DogStatsdMetricsBridge(new DogStatsdSink(config), NullLogger<DogStatsdMetricsBridge>.Instance);
        bridge.Start();

        metrics.WorkflowCompleted.Add(1, new KeyValuePair<string, object?>("workflow", "OrderProcessing"), new KeyValuePair<string, object?>("outcome", "succeeded"), new KeyValuePair<string, object?>("order_id", "ORD-1"));
        metrics.WorkflowCompleted.Add(2, new KeyValuePair<string, object?>("workflow", "OrderProcessing"), new KeyValuePair<string, object?>("outcome", "succeeded"));
        metrics.WorkflowDuration.Record(1500, new KeyValuePair<string, object?>("workflow", "OrderProcessing"));
        metrics.OrdersCreated.Add(1, new KeyValuePair<string, object?>("order.status", "Pending"));
        await bridge.StopAsync(TestContext.Current.CancellationToken);

        var lines = await ReceiveAsync(udp, TimeSpan.FromSeconds(5), l => l.Any(x => x.StartsWith("hello.orders.created:", StringComparison.Ordinal)) && l.Any(x => x.StartsWith("hello.workflow.duration:", StringComparison.Ordinal)));
        var all = string.Join('\n', lines);
        var completed = lines.Where(l => l.StartsWith("hello.workflow.completed:", StringComparison.Ordinal)).ToList();
        Assert.NotEmpty(completed);
        Assert.Equal(3, completed.Sum(l => double.Parse(l.Split(':')[1].Split('|')[0], System.Globalization.CultureInfo.InvariantCulture)));
        Assert.All(completed, l => Assert.Contains("|c", l, StringComparison.Ordinal));
        Assert.Contains(lines, l => l.StartsWith("hello.workflow.duration:1500|d", StringComparison.Ordinal));
        Assert.Contains(lines, l => l.StartsWith("hello.orders.created:1|c", StringComparison.Ordinal) && l.Contains("order.status:Pending", StringComparison.Ordinal));
        Assert.All(completed, l =>
        {
            Assert.Contains("outcome:succeeded", l, StringComparison.Ordinal);
            Assert.Contains("env:dev", l, StringComparison.Ordinal);
            Assert.Contains("service:hello-durable", l, StringComparison.Ordinal);
            Assert.Contains("version:1.2.3", l, StringComparison.Ordinal);
        });
        Assert.DoesNotContain("ORD-1", all, StringComparison.Ordinal);
        Assert.DoesNotContain("order_id", all, StringComparison.Ordinal);
    }

    [Fact]
    public void DogStatsdBridge_IgnoresForeignMeters()
    {
        using var meter = new Meter("Some.Other");
        var counter = meter.CreateCounter<long>("other.count");
        var sink = new RecordingSink();
        using var bridge = new DogStatsdMetricsBridge(sink, NullLogger<DogStatsdMetricsBridge>.Instance);
        bridge.Start();
        counter.Add(5);
        Assert.Empty(sink.Calls);
    }

    private static JsonElement Parse(HelloJsonLogWriter writer)
    {
        var entry = new LogEntry<string>(LogLevel.Information, "t", default, "hello", null, (s, _) => s);
        return JsonDocument.Parse(writer.Format(entry, null)).RootElement.Clone();
    }

    private static async Task<List<string>> ReceiveAsync(UdpClient udp, TimeSpan timeout, Func<List<string>, bool> done)
    {
        var lines = new List<string>();
        using var cts = new CancellationTokenSource(timeout);
        try
        {
            while (!done(lines))
            {
                var result = await udp.ReceiveAsync(cts.Token);
                lines.AddRange(Encoding.UTF8.GetString(result.Buffer).Split('\n', StringSplitOptions.RemoveEmptyEntries));
            }
        }
        catch (OperationCanceledException)
        {
            // timeout: return what arrived
        }

        return lines;
    }

    private sealed class RecordingSink : IDogStatsdSink
    {
        public List<string> Calls { get; } = [];

        public void Count(string name, double value, string[] tags) => Calls.Add(name);

        public void Distribution(string name, double value, string[] tags) => Calls.Add(name);

        public void Gauge(string name, double value, string[] tags) => Calls.Add(name);

        public void Flush()
        {
        }

        public void Dispose()
        {
        }
    }
}
