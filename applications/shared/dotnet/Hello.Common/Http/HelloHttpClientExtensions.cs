using System.Diagnostics;
using Hello.Common.Faults;
using Hello.Common.Telemetry;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Http.Resilience;
using Polly;

namespace Hello.Common.Http;

/// <summary>Resilience settings for one logical dependency.</summary>
public sealed class HelloHttpClientOptions
{
    /// <summary>Total budget per logical call including retries (default 5 s).</summary>
    public TimeSpan TotalTimeout { get; set; } = TimeSpan.FromSeconds(5);

    /// <summary>Per-attempt timeout (default 2 s).</summary>
    public TimeSpan AttemptTimeout { get; set; } = TimeSpan.FromSeconds(2);

    /// <summary>Retries after the first attempt (default 2, exponential backoff with jitter).</summary>
    public int MaxRetryAttempts { get; set; } = 2;

    /// <summary>When false (default) only GET/HEAD/OPTIONS/PUT/DELETE/TRACE are retried; POST/PATCH/CONNECT never are.</summary>
    public bool RetryUnsafeMethods { get; set; }
}

public static class HelloHttpClientExtensions
{
    /// <summary>
    /// Registers a typed client with: dependency duration metric (outermost, logical call) →
    /// standard resilience handler (rate limiter, total timeout, retry w/ jitter, circuit breaker, attempt timeout) →
    /// lab fault handler (innermost, simulates dependency_timeout).
    /// </summary>
    public static IHttpClientBuilder AddHelloHttpClient<TClient, TImplementation>(
        this IServiceCollection services,
        string dependencyName,
        Func<IServiceProvider, Uri?> baseAddress,
        Action<HelloHttpClientOptions>? configure = null)
        where TClient : class
        where TImplementation : class, TClient
    {
        var builder = services.AddHttpClient<TClient, TImplementation>((sp, client) =>
        {
            var uri = baseAddress(sp);
            if (uri is not null)
            {
                client.BaseAddress = uri;
            }

            // The resilience pipeline owns timeouts; this is only a safety net.
            client.Timeout = TimeSpan.FromSeconds(60);
        });
        return builder.ConfigureHelloResilience(dependencyName, configure);
    }

    public static IHttpClientBuilder ConfigureHelloResilience(this IHttpClientBuilder builder, string dependencyName, Action<HelloHttpClientOptions>? configure = null)
    {
        ArgumentNullException.ThrowIfNull(builder);
        var options = new HelloHttpClientOptions();
        configure?.Invoke(options);

        builder.ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
        {
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            PooledConnectionIdleTimeout = TimeSpan.FromMinutes(1),
            MaxConnectionsPerServer = 100,
            ConnectTimeout = TimeSpan.FromSeconds(3),
        });

        builder.AddHttpMessageHandler(sp => new DependencyMetricsHandler(sp.GetRequiredService<HelloMetrics>(), dependencyName));
        builder.AddStandardResilienceHandler(o =>
        {
            o.TotalRequestTimeout.Timeout = options.TotalTimeout;
            o.AttemptTimeout.Timeout = options.AttemptTimeout;
            o.Retry.MaxRetryAttempts = options.MaxRetryAttempts;
            o.Retry.UseJitter = true;
            o.Retry.BackoffType = DelayBackoffType.Exponential;
            o.Retry.Delay = TimeSpan.FromMilliseconds(200);
            if (!options.RetryUnsafeMethods)
            {
                o.Retry.DisableForUnsafeHttpMethods();
            }

            o.CircuitBreaker.SamplingDuration = TimeSpan.FromSeconds(Math.Max(30, options.AttemptTimeout.TotalSeconds * 2 + 1));
            o.CircuitBreaker.FailureRatio = 0.5;
            o.CircuitBreaker.MinimumThroughput = 10;
            o.CircuitBreaker.BreakDuration = TimeSpan.FromSeconds(15);
        });
        builder.AddHttpMessageHandler(sp => new FaultInjectionHandler(sp.GetRequiredService<FaultState>()));
        return builder;
    }
}

/// <summary>Records hello.http.dependency.duration with bounded attributes.</summary>
public sealed class DependencyMetricsHandler(HelloMetrics metrics, string dependencyName) : DelegatingHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var start = Stopwatch.GetTimestamp();
        string? errorType = null;
        int? status = null;
        try
        {
            var response = await base.SendAsync(request, cancellationToken).ConfigureAwait(false);
            status = (int)response.StatusCode;
            if (status >= 500)
            {
                errorType = status.Value.ToString(System.Globalization.CultureInfo.InvariantCulture);
            }

            return response;
        }
        catch (Exception ex)
        {
            errorType = ex.GetType().Name;
            throw;
        }
        finally
        {
            var tags = new TagList
            {
                { "peer.service", dependencyName },
                { "http.request.method", request.Method.Method },
            };
            if (status is not null)
            {
                tags.Add("http.response.status_code", status.Value);
            }

            if (errorType is not null)
            {
                tags.Add("error.type", errorType);
            }

            metrics.DependencyDuration.Record(Stopwatch.GetElapsedTime(start).TotalSeconds, tags);
        }
    }
}

/// <summary>Lab fault: dependency_timeout makes the outbound call hang until the resilience attempt timeout fires.</summary>
public sealed class FaultInjectionHandler(FaultState faults) : DelegatingHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (faults.ShouldInject(FaultTypes.DependencyTimeout, out _))
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken).ConfigureAwait(false);
        }

        return await base.SendAsync(request, cancellationToken).ConfigureAwait(false);
    }
}
