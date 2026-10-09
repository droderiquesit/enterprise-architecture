using Azure.Core;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Hello.Common.Secrets;

/// <summary>Options for <see cref="DsvConfigurationExtensions.AddDsvSecrets"/>. Defaults come from the configuration itself (DSV_* keys).</summary>
public sealed class DsvConfigurationSourceOptions
{
    /// <summary>Overrides <see cref="DsvOptions.FromConfiguration"/>.</summary>
    public DsvOptions? Options { get; set; }

    /// <summary>Test seam: credential for the azure grant (default: managed / workload identity).</summary>
    public TokenCredential? Credential { get; set; }

    /// <summary>Test seam: HTTP handler (default: SocketsHttpHandler).</summary>
    public HttpMessageHandler? Handler { get; set; }

    public TimeProvider? TimeProvider { get; set; }

    /// <summary>Optional logger. Only key names and counts are ever logged.</summary>
    public ILogger? Logger { get; set; }
}

/// <summary>A configuration value holds a dsv:// reference that cannot be resolved. Names the keys only.</summary>
public sealed class DsvSecretResolutionException : InvalidOperationException
{
    public DsvSecretResolutionException()
    {
    }

    public DsvSecretResolutionException(string message)
        : base(message)
    {
    }

    public DsvSecretResolutionException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public IReadOnlyList<string> Keys { get; init; } = [];
}

public static class DsvConfigurationExtensions
{
    /// <summary>
    /// Resolves every configuration value starting with <c>dsv://</c> (from all sources added before this call: env vars,
    /// appsettings, App Service app settings, ...) against Delinea DSV and overlays the resolved values under the same keys.
    /// Call it first thing after <c>CreateBuilder</c>: with a <see cref="ConfigurationManager"/> (WebApplicationBuilder,
    /// FunctionsApplicationBuilder, HostApplicationBuilder) resolution happens immediately, so everything that reads
    /// configuration afterwards sees values. A reference that cannot be resolved throws
    /// <see cref="DsvSecretResolutionException"/> naming the configuration keys (fail fast). No dsv:// values → no-op, no network.
    /// DSV_REFRESH_SECONDS &gt; 0 re-resolves periodically and raises a configuration reload when a value changed.
    /// </summary>
    public static IConfigurationBuilder AddDsvSecrets(this IConfigurationBuilder builder, Action<DsvConfigurationSourceOptions>? configure = null)
    {
        ArgumentNullException.ThrowIfNull(builder);
        var options = new DsvConfigurationSourceOptions();
        configure?.Invoke(options);
        return builder.Add(new DsvConfigurationSource(options));
    }
}

public sealed class DsvConfigurationSource(DsvConfigurationSourceOptions options) : IConfigurationSource
{
    public DsvConfigurationSourceOptions SourceOptions { get; } = options;

    public IConfigurationProvider Build(IConfigurationBuilder builder)
    {
        ArgumentNullException.ThrowIfNull(builder);

        // ConfigurationManager is the live configuration (this source is not part of it yet while Build runs);
        // a plain ConfigurationBuilder is snapshotted from the sources added before this one.
        IConfiguration input = builder is IConfigurationRoot root
            ? root
            : new ConfigurationBuilder().AddRange(builder.Sources.TakeWhile(s => !ReferenceEquals(s, this))).Build();
        return new DsvConfigurationProvider(input, SourceOptions);
    }
}

internal static class ConfigurationBuilderRange
{
    public static IConfigurationBuilder AddRange(this IConfigurationBuilder builder, IEnumerable<IConfigurationSource> sources)
    {
        foreach (var s in sources)
        {
            builder.Add(s);
        }

        return builder;
    }
}

public sealed class DsvConfigurationProvider : ConfigurationProvider, IDisposable
{
    private readonly IConfiguration _input;
    private readonly DsvConfigurationSourceOptions _sourceOptions;
    private readonly ILogger _logger;
    private Dictionary<string, string>? _references;
    private DsvSecretResolver? _resolver;
    private ITimer? _timer;

    public DsvConfigurationProvider(IConfiguration input, DsvConfigurationSourceOptions sourceOptions)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(sourceOptions);
        _input = input;
        _sourceOptions = sourceOptions;
        _logger = sourceOptions.Logger ?? NullLogger.Instance;
    }

    /// <summary>Configuration keys that held dsv:// references (names only).</summary>
    public IReadOnlyCollection<string> ResolvedKeys => (IReadOnlyCollection<string>?)_references?.Keys ?? [];

    public override void Load()
    {
        // First load discovers the references; later loads (configuration reload) re-resolve the same references.
        _references ??= _input.AsEnumerable()
            .Where(kv => DsvSecretReference.IsReference(kv.Value) && !kv.Key.StartsWith("DSV_", StringComparison.OrdinalIgnoreCase))
            .ToDictionary(kv => kv.Key, kv => kv.Value!, StringComparer.OrdinalIgnoreCase);
        if (_references.Count == 0)
        {
            return;
        }

        Data = Resolve();
        StartRefreshTimer();
    }

    public void Dispose()
    {
        _timer?.Dispose();
        _resolver?.Dispose();
    }

    private Dictionary<string, string?> Resolve()
    {
        var keys = _references!.Keys.Order(StringComparer.Ordinal).ToList();
        DsvOptions options;
        try
        {
            options = _sourceOptions.Options ?? DsvOptions.FromConfiguration(_input);
            if (options.Auth == DsvAuthMode.None)
            {
                throw new DsvConfigurationException("DSV_AUTH=none but configuration values hold dsv:// references");
            }

            _resolver ??= new DsvSecretResolver(options, _sourceOptions.Credential, _sourceOptions.Handler, _sourceOptions.TimeProvider);
        }
        catch (DsvConfigurationException ex)
        {
            _logger.LogError("DSV secret resolution failed for {dsv_keys}: {error_message}", string.Join(',', keys), ex.Message);
            throw new DsvSecretResolutionException($"cannot resolve dsv:// references in {string.Join(", ", keys)}: {ex.Message}", ex) { Keys = keys };
        }

        var resolved = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        var failures = new List<string>();
        foreach (var key in keys)
        {
            try
            {
                // Configuration providers load synchronously; this runs once at host build time on the startup thread.
                resolved[key] = _resolver.ResolveAsync(_references[key]).GetAwaiter().GetResult();
            }
            catch (FormatException)
            {
                failures.Add($"{key} (malformed dsv:// reference)");
            }
            catch (DsvSecretException ex)
            {
                failures.Add($"{key} ({ex.Message})");
            }
        }

        if (failures.Count > 0)
        {
            var failedKeys = failures.Select(f => f.Split(' ', 2)[0]).ToList();
            _logger.LogError("DSV secret resolution failed for {dsv_keys}", string.Join(',', failedKeys));
            throw new DsvSecretResolutionException("could not resolve DSV secret for configuration key(s): " + string.Join("; ", failures)) { Keys = failedKeys };
        }

        _logger.LogInformation("DSV secrets resolved for {dsv_keys} ({dsv_count})", string.Join(',', keys), keys.Count);
        return resolved;
    }

    private void StartRefreshTimer()
    {
        var interval = (_sourceOptions.Options ?? DsvOptions.FromConfiguration(_input)).RefreshInterval;
        if (_timer is not null || interval <= TimeSpan.Zero)
        {
            return;
        }

        _timer = (_sourceOptions.TimeProvider ?? TimeProvider.System).CreateTimer(_ => Refresh(), null, interval, interval);
    }

    private void Refresh()
    {
        try
        {
            var fresh = Resolve();
            var changed = fresh.Count != Data.Count || fresh.Any(kv => !Data.TryGetValue(kv.Key, out var old) || !string.Equals(old, kv.Value, StringComparison.Ordinal));
            if (changed)
            {
                Data = fresh;
                OnReload();
            }
        }
#pragma warning disable CA1031 // a failed background refresh keeps the last good values
        catch (Exception ex)
#pragma warning restore CA1031
        {
            _logger.LogWarning("DSV secret refresh failed; keeping current values ({error_kind})", ex.GetType().Name);
        }
    }
}
