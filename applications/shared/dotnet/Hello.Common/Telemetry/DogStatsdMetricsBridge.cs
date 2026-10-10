using System.Diagnostics.Metrics;
using System.Globalization;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using StatsdClient;

namespace Hello.Common.Telemetry;

/// <summary>Minimal DogStatsD surface used by <see cref="DogStatsdMetricsBridge"/> (test seam).</summary>
public interface IDogStatsdSink : IDisposable
{
    void Count(string name, double value, string[] tags);

    void Distribution(string name, double value, string[] tags);

    void Gauge(string name, double value, string[] tags);

    void Flush();
}

/// <summary>
/// TELEMETRY_SDK=datadog without DD_METRICS_OTEL_ENABLED: forwards every measurement of the <c>Hello.App</c> Meter
/// (<see cref="HelloMetrics"/>: hello.orders.created, hello.workflow.completed/duration, ...) to DogStatsD with the same
/// metric names. Counter/UpDownCounter → count, Histogram → distribution (server-side percentiles), Gauge → gauge.
/// Tags are the measurement's bounded attributes (keys denoting ids are dropped defensively); unified service tags
/// env/service/version come from DD_ENV/DD_SERVICE/DD_VERSION (the DogStatsD client adds them).
/// Destination: DD_DOGSTATSD_URL (udp://host:port | unix:///path) else DD_AGENT_HOST[:DD_DOGSTATSD_PORT] else localhost:8125.
/// </summary>
public sealed class DogStatsdMetricsBridge : IHostedService, IDisposable
{
    private static readonly HashSet<string> ForbiddenTagKeys = new(StringComparer.OrdinalIgnoreCase)
    {
        "order_id", "order.id", "customer_ref", "customer.ref", "user_id", "user.id", "enduser.id", "workflow_instance_id",
        "instance_id", "idempotency_key", "message_id", "messaging.message.id", "sku_id",
    };

    private readonly IDogStatsdSink _sink;
    private readonly ILogger<DogStatsdMetricsBridge> _logger;
    private readonly MeterListener _listener = new();
    private bool _started;

    public DogStatsdMetricsBridge(IDogStatsdSink sink, ILogger<DogStatsdMetricsBridge> logger)
    {
        _sink = sink ?? throw new ArgumentNullException(nameof(sink));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _listener.InstrumentPublished = (instrument, listener) =>
        {
            if (instrument.Meter.Name == HelloMetrics.MeterName)
            {
                listener.EnableMeasurementEvents(instrument);
            }
        };
        _listener.SetMeasurementEventCallback<long>((i, v, t, _) => Record(i, v, t));
        _listener.SetMeasurementEventCallback<int>((i, v, t, _) => Record(i, v, t));
        _listener.SetMeasurementEventCallback<double>((i, v, t, _) => Record(i, v, t));
        _listener.SetMeasurementEventCallback<float>((i, v, t, _) => Record(i, v, t));
    }

    public Task StartAsync(CancellationToken cancellationToken)
    {
        Start();
        return Task.CompletedTask;
    }

    /// <summary>Starts listening (idempotent). Also used directly by tests.</summary>
    public void Start()
    {
        if (_started)
        {
            return;
        }

        _started = true;
        _listener.Start();
        _logger.LogInformation("hello.* metrics routed to DogStatsD (TELEMETRY_SDK=datadog)");
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        _listener.Dispose();
        _sink.Flush();
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        _listener.Dispose();
        _sink.Dispose();
    }

    internal static string[] Tags(ReadOnlySpan<KeyValuePair<string, object?>> tags)
    {
        var list = new List<string>(tags.Length);
        foreach (var tag in tags)
        {
            if (tag.Value is null || ForbiddenTagKeys.Contains(tag.Key))
            {
                continue;
            }

            var value = Convert.ToString(tag.Value, CultureInfo.InvariantCulture) ?? string.Empty;
            if (value.Length > 100)
            {
                value = value[..100];
            }

            list.Add($"{tag.Key}:{value}");
        }

        list.Sort(StringComparer.Ordinal);
        return [.. list];
    }

    private void Record<T>(Instrument instrument, T value, ReadOnlySpan<KeyValuePair<string, object?>> tags)
        where T : struct
    {
        try
        {
            var amount = Convert.ToDouble(value, CultureInfo.InvariantCulture);
            var tagArray = Tags(tags);
            switch (instrument)
            {
                case Counter<T>:
                case UpDownCounter<T>:
                    _sink.Count(instrument.Name, amount, tagArray);
                    break;
                case Histogram<T>:
                    _sink.Distribution(instrument.Name, amount, tagArray);
                    break;
                default:
                    _sink.Gauge(instrument.Name, amount, tagArray);
                    break;
            }
        }
        catch (Exception ex)
        {
            // Metrics must never fail a request.
            _logger.LogDebug(ex, "DogStatsD forward failed for {instrument}", instrument.Name);
        }
    }
}

/// <summary><see cref="IDogStatsdSink"/> over the official DogStatsD-CSharp-Client (client-side aggregation, async UDP/UDS).</summary>
public sealed class DogStatsdSink : IDogStatsdSink
{
    private readonly DogStatsdService _service = new();

    public DogStatsdSink(IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        var config = new StatsdConfig();
        var url = configuration["DD_DOGSTATSD_URL"];
        if (!string.IsNullOrWhiteSpace(url) && Uri.TryCreate(url.Trim(), UriKind.Absolute, out var uri))
        {
            if (uri.Scheme is "unix" or "unixgram")
            {
                config.StatsdServerName = "unix://" + uri.AbsolutePath;
            }
            else if (uri.Scheme == "udp")
            {
                config.StatsdServerName = uri.Host;
                config.StatsdPort = uri.IsDefaultPort || uri.Port <= 0 ? 8125 : uri.Port;
            }
        }
        else if (string.IsNullOrWhiteSpace(configuration["DD_AGENT_HOST"]))
        {
            config.StatsdServerName = "localhost"; // serverless-init / App Service sidecar listen locally
        }

        // Unified service tags from configuration (env vars or app settings); the client also reads DD_ENV/DD_SERVICE/
        // DD_VERSION/DD_AGENT_HOST/DD_DOGSTATSD_PORT/DD_ENTITY_ID from the process environment itself.
        config.Environment = NullIfEmpty(configuration["DD_ENV"]);
        config.ServiceName = NullIfEmpty(configuration["DD_SERVICE"]);
        config.ServiceVersion = NullIfEmpty(configuration["DD_VERSION"]);
        if (config.StatsdServerName is null && NullIfEmpty(configuration["DD_AGENT_HOST"]) is { } host)
        {
            config.StatsdServerName = host;
            if (int.TryParse(configuration["DD_DOGSTATSD_PORT"], NumberStyles.Integer, CultureInfo.InvariantCulture, out var port) && port > 0)
            {
                config.StatsdPort = port;
            }
        }

        _service.Configure(config);
    }

    private static string? NullIfEmpty(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    public void Count(string name, double value, string[] tags) => _service.Counter(name, value, tags: tags);

    public void Distribution(string name, double value, string[] tags) => _service.Distribution(name, value, tags: tags);

    public void Gauge(string name, double value, string[] tags) => _service.Gauge(name, value, tags: tags);

    public void Flush() => _service.Flush();

    public void Dispose() => _service.Dispose();
}
