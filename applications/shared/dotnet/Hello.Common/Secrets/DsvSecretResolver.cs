using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.RegularExpressions;
using Azure.Core;
using Azure.Identity;
using Microsoft.Extensions.Configuration;

namespace Hello.Common.Secrets;

/// <summary>How the resolver authenticates to Delinea DSV (DSV_AUTH).</summary>
public enum DsvAuthMode
{
    /// <summary>Azure managed identity → DSV <c>azure</c> grant (default in Azure).</summary>
    Azure,

    /// <summary>DSV client credentials (DSV_CLIENT_ID / DSV_CLIENT_SECRET) — local development and tests only.</summary>
    ClientCredentials,

    /// <summary>No resolution: any <c>dsv://</c> value is a start-up error.</summary>
    None,
}

/// <summary>DSV runtime settings (ADR-0001 §14 env contract). Never prints the client secret.</summary>
public sealed record DsvOptions
{
    public DsvAuthMode Auth { get; init; } = DsvAuthMode.Azure;

    public Uri? BaseUri { get; init; }

    public string? AzureClientId { get; init; }

    public string? FederatedTokenFile { get; init; }

    public string? AzureTenantId { get; init; }

    public string? ClientId { get; init; }

    public string? ClientSecret { get; init; }

    public TimeSpan Timeout { get; init; } = TimeSpan.FromSeconds(5);

    public TimeSpan CacheTtl { get; init; } = TimeSpan.FromSeconds(900);

    public int MaxAttempts { get; init; } = 3;

    /// <summary>Periodic re-resolution of configuration values (DSV_REFRESH_SECONDS, 0 = off).</summary>
    public TimeSpan RefreshInterval { get; init; } = TimeSpan.Zero;

    public bool AllowInsecureHttp { get; init; }

    public override string ToString() => $"DsvOptions {{ Auth = {Auth}, BaseUri = {BaseUri}, AzureClientId = {AzureClientId} }}";

    /// <summary>Reads DSV_AUTH, DSV_TENANT, DSV_TLD, DSV_BASE_URL, AZURE_CLIENT_ID, AZURE_FEDERATED_TOKEN_FILE, DSV_CLIENT_ID,
    /// DSV_CLIENT_SECRET, DSV_TIMEOUT_SECONDS, DSV_CACHE_TTL_SECONDS, DSV_MAX_ATTEMPTS, DSV_REFRESH_SECONDS, DSV_ALLOW_INSECURE_HTTP.</summary>
    public static DsvOptions FromConfiguration(IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        string? Get(string key) => string.IsNullOrWhiteSpace(configuration[key]) ? null : configuration[key]!.Trim();

        var auth = (Get("DSV_AUTH") ?? "azure").ToUpperInvariant() switch
        {
            "AZURE" => DsvAuthMode.Azure,
            "CLIENT_CREDENTIALS" => DsvAuthMode.ClientCredentials,
            "NONE" => DsvAuthMode.None,
            _ => throw new DsvConfigurationException("DSV_AUTH must be one of azure, client_credentials, none"),
        };
        var baseUrl = Get("DSV_BASE_URL")?.TrimEnd('/');
        if (baseUrl is null && Get("DSV_TENANT") is { } tenant)
        {
            baseUrl = $"https://{tenant}.secretsvaultcloud.{Get("DSV_TLD") ?? "com"}/v1";
        }

        Uri? baseUri = null;
        if (baseUrl is not null && !Uri.TryCreate(baseUrl + "/", UriKind.Absolute, out baseUri))
        {
            throw new DsvConfigurationException("DSV_BASE_URL must be an absolute https URL");
        }

        return new DsvOptions
        {
            Auth = auth,
            BaseUri = baseUri,
            AzureClientId = Get("AZURE_CLIENT_ID"),
            FederatedTokenFile = Get("AZURE_FEDERATED_TOKEN_FILE"),
            AzureTenantId = Get("AZURE_TENANT_ID"),
            ClientId = Get("DSV_CLIENT_ID"),
            ClientSecret = configuration["DSV_CLIENT_SECRET"],
            Timeout = TimeSpan.FromSeconds(Number(Get("DSV_TIMEOUT_SECONDS"), "DSV_TIMEOUT_SECONDS", 5, 0.1)),
            CacheTtl = TimeSpan.FromSeconds(Number(Get("DSV_CACHE_TTL_SECONDS"), "DSV_CACHE_TTL_SECONDS", 900, 0)),
            MaxAttempts = (int)Number(Get("DSV_MAX_ATTEMPTS"), "DSV_MAX_ATTEMPTS", 3, 1),
            RefreshInterval = TimeSpan.FromSeconds(Number(Get("DSV_REFRESH_SECONDS"), "DSV_REFRESH_SECONDS", 0, 0)),
            AllowInsecureHttp = Get("DSV_ALLOW_INSECURE_HTTP") is { } v && (v.Equals("true", StringComparison.OrdinalIgnoreCase) || v == "1"),
        };
    }

    /// <summary>Throws <see cref="DsvConfigurationException"/> when the options cannot be used to resolve references.</summary>
    public void Validate()
    {
        if (Auth == DsvAuthMode.None)
        {
            return;
        }

        if (BaseUri is null)
        {
            throw new DsvConfigurationException("DSV_TENANT or DSV_BASE_URL must be set to resolve dsv:// references");
        }

        var loopback = BaseUri.IsLoopback;
        if (BaseUri.Scheme != Uri.UriSchemeHttps && !(BaseUri.Scheme == Uri.UriSchemeHttp && (loopback || AllowInsecureHttp)))
        {
            throw new DsvConfigurationException("DSV_BASE_URL must use https (http only for loopback or DSV_ALLOW_INSECURE_HTTP=true)");
        }

        if (Auth == DsvAuthMode.ClientCredentials && (string.IsNullOrEmpty(ClientId) || string.IsNullOrEmpty(ClientSecret)))
        {
            throw new DsvConfigurationException("DSV_AUTH=client_credentials requires DSV_CLIENT_ID and DSV_CLIENT_SECRET");
        }
    }

    private static double Number(string? raw, string name, double fallback, double minimum)
    {
        if (raw is null)
        {
            return fallback;
        }

        if (!double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) || v < minimum)
        {
            throw new DsvConfigurationException($"{name} must be a number >= {minimum.ToString(CultureInfo.InvariantCulture)}");
        }

        return v;
    }
}

/// <summary>A parsed <c>dsv://&lt;path&gt;#&lt;element&gt;</c> reference (element defaults to <c>value</c>). References are not secrets.</summary>
public readonly partial record struct DsvSecretReference(string Path, string Element)
{
    public const string Prefix = "dsv://";

    public static bool IsReference(string? value) => value is not null && value.StartsWith(Prefix, StringComparison.Ordinal);

    public static DsvSecretReference Parse(string reference)
    {
        ArgumentNullException.ThrowIfNull(reference);
        if (!IsReference(reference))
        {
            throw new FormatException("not a dsv:// reference");
        }

        var body = reference[Prefix.Length..];
        var hash = body.IndexOf('#', StringComparison.Ordinal);
        var path = (hash < 0 ? body : body[..hash]).Trim('/');
        var element = hash < 0 || hash == body.Length - 1 ? "value" : body[(hash + 1)..];
        if (path.Length == 0 || path.Split('/').Contains("..") || !PathRegex().IsMatch(path))
        {
            throw new FormatException("malformed dsv:// reference path");
        }

        if (!ElementRegex().IsMatch(element))
        {
            throw new FormatException("malformed dsv:// reference element");
        }

        return new DsvSecretReference(path, element);
    }

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9_.:-]*(/[A-Za-z0-9_.:-]+)*$", RegexOptions.CultureInvariant)]
    private static partial Regex PathRegex();

    [GeneratedRegex(@"^[A-Za-z0-9_.-]+$", RegexOptions.CultureInvariant)]
    private static partial Regex ElementRegex();
}

/// <summary>DSV settings are unusable (missing base URL, bad DSV_AUTH, ...).</summary>
public sealed class DsvConfigurationException : InvalidOperationException
{
    public DsvConfigurationException()
    {
    }

    public DsvConfigurationException(string message)
        : base(message)
    {
    }

    public DsvConfigurationException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

/// <summary>One DSV call failed. The message holds a status code / error class only — never a secret value.</summary>
public sealed class DsvSecretException : Exception
{
    public DsvSecretException()
    {
    }

    public DsvSecretException(string message)
        : base(message)
    {
    }

    public DsvSecretException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public DsvSecretException(string message, HttpStatusCode? status)
        : base(message)
    {
        Status = status;
    }

    public HttpStatusCode? Status { get; }
}

/// <summary>
/// Delinea DSV reader (protocol as implemented by dsv-sdk-go v2.3.0): Entra token for https://management.azure.com/ from the
/// user-assigned managed identity → <c>POST {base}/token {"grant_type":"azure","jwt":...}</c> → bearer → <c>GET {base}/secrets/&lt;path&gt;</c>.
/// DSV access tokens are cached and refreshed at 80 % of <c>expiresIn</c>; secrets are cached for <see cref="DsvOptions.CacheTtl"/>.
/// Transient failures (connection errors, timeouts, 429, 5xx) are retried with full jitter up to <see cref="DsvOptions.MaxAttempts"/>;
/// 401/403/404 and other 4xx are not. Thread-safe. Nothing here logs or formats secret values.
/// </summary>
public sealed class DsvSecretResolver : IDisposable
{
    public const string ArmScope = "https://management.azure.com/.default";
    private const double RefreshFraction = 0.8;

    private readonly DsvOptions _options;
    private readonly HttpClient _http;
    private readonly TimeProvider _time;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly Dictionary<string, (Dictionary<string, JsonElement> Data, DateTimeOffset Expires)> _cache = new(StringComparer.Ordinal);
    private TokenCredential? _credential;
    private string? _token;
    private DateTimeOffset _tokenRefreshAt;

    public DsvSecretResolver(
        DsvOptions options,
        TokenCredential? credential = null,
        HttpMessageHandler? handler = null,
        TimeProvider? timeProvider = null,
        Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (options.Auth == DsvAuthMode.None)
        {
            throw new DsvConfigurationException("DSV_AUTH=none: dsv:// references cannot be resolved");
        }

        options.Validate();
        _options = options;
        _credential = credential;
        _time = timeProvider ?? TimeProvider.System;
        _delay = delay ?? Task.Delay;
        handler ??= new SocketsHttpHandler
        {
            ConnectTimeout = options.Timeout,
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            AllowAutoRedirect = false,
        };
        _http = new HttpClient(handler, disposeHandler: true) { BaseAddress = options.BaseUri, Timeout = options.Timeout };
        _http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("hello-common-dsv/1");
    }

    /// <summary>Requests made (for tests and diagnostics; counts only).</summary>
    public int TokenRequests { get; private set; }

    public int SecretRequests { get; private set; }

    public int CacheHits { get; private set; }

    /// <summary>The managed identity credential used for the azure grant (no developer-credential fallbacks).</summary>
    public static TokenCredential CreateDefaultCredential(DsvOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (!string.IsNullOrWhiteSpace(options.FederatedTokenFile))
        {
            return new WorkloadIdentityCredential(new WorkloadIdentityCredentialOptions
            {
                ClientId = options.AzureClientId,
                TokenFilePath = options.FederatedTokenFile,
                TenantId = options.AzureTenantId,
            });
        }

        return string.IsNullOrWhiteSpace(options.AzureClientId)
            ? new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned)
            : new ManagedIdentityCredential(ManagedIdentityId.FromUserAssignedClientId(options.AzureClientId));
    }

    public async Task<string> ResolveAsync(string reference, CancellationToken cancellationToken = default)
    {
        var parsed = DsvSecretReference.Parse(reference);
        var data = await GetSecretDataAsync(parsed.Path, cancellationToken).ConfigureAwait(false);
        if (!data.TryGetValue(parsed.Element, out var element))
        {
            throw new DsvSecretException("element missing in DSV secret");
        }

        return element.ValueKind switch
        {
            JsonValueKind.String => element.GetString()!,
            JsonValueKind.Null or JsonValueKind.Undefined => throw new DsvSecretException("element is null in DSV secret"),
            _ => element.GetRawText(),
        };
    }

    public async Task<IReadOnlyDictionary<string, JsonElement>> GetSecretDataAsync(string path, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(path);
        path = path.Trim('/');
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_cache.TryGetValue(path, out var hit) && _time.GetUtcNow() < hit.Expires)
            {
                CacheHits++;
                return hit.Data;
            }

            var token = await GetAccessTokenCoreAsync(cancellationToken).ConfigureAwait(false);
            SecretRequests++;
            var encoded = string.Join('/', path.Split('/').Select(Uri.EscapeDataString));
            HttpResponseMessage response;
            try
            {
                response = await SendAsync(
                    () =>
                    {
                        var request = new HttpRequestMessage(HttpMethod.Get, new Uri("secrets/" + encoded, UriKind.Relative));
                        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                        return request;
                    },
                    cancellationToken).ConfigureAwait(false);
            }
            catch (DsvSecretException ex)
            {
                if (ex.Status == HttpStatusCode.Unauthorized)
                {
                    _token = null; // revoked / expired early: the next call re-authenticates (no retry here)
                }

                var reason = ex.Status switch
                {
                    HttpStatusCode.Unauthorized => "unauthorized, ",
                    HttpStatusCode.Forbidden => "access denied, ",
                    HttpStatusCode.NotFound => "not found, ",
                    _ => string.Empty,
                };
                throw new DsvSecretException($"DSV secret read failed ({reason}{ex.Message})", ex.Status);
            }

            using (response)
            {
                Dictionary<string, JsonElement>? data = null;
                try
                {
                    using var doc = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false), cancellationToken: cancellationToken).ConfigureAwait(false);
                    if (doc.RootElement.ValueKind == JsonValueKind.Object && doc.RootElement.TryGetProperty("data", out var d) && d.ValueKind == JsonValueKind.Object)
                    {
                        data = d.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.Clone(), StringComparer.Ordinal);
                    }
                }
                catch (JsonException)
                {
                    data = null;
                }

                if (data is null)
                {
                    throw new DsvSecretException("DSV secret response malformed");
                }

                _cache[path] = (data, _time.GetUtcNow() + _options.CacheTtl);
                return data;
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<string> GetAccessTokenAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await GetAccessTokenCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public void Dispose()
    {
        _http.Dispose();
        _gate.Dispose();
    }

    private async Task<string> GetAccessTokenCoreAsync(CancellationToken cancellationToken)
    {
        if (_token is not null && _time.GetUtcNow() < _tokenRefreshAt)
        {
            return _token;
        }

        Dictionary<string, string> body;
        if (_options.Auth == DsvAuthMode.ClientCredentials)
        {
            body = new() { ["grant_type"] = "client_credentials", ["client_id"] = _options.ClientId!, ["client_secret"] = _options.ClientSecret! };
        }
        else
        {
            _credential ??= CreateDefaultCredential(_options);
            string entra;
            try
            {
                entra = (await _credential.GetTokenAsync(new TokenRequestContext([ArmScope]), cancellationToken).ConfigureAwait(false)).Token;
            }
#pragma warning disable CA1031 // any credential failure becomes a value-free resolution error
            catch (Exception ex) when (ex is not OperationCanceledException)
#pragma warning restore CA1031
            {
                throw new DsvSecretException($"managed identity token unavailable ({ex.GetType().Name})");
            }

            body = new() { ["grant_type"] = "azure", ["jwt"] = entra };
        }

        TokenRequests++;
        HttpResponseMessage response;
        try
        {
            response = await SendAsync(() => new HttpRequestMessage(HttpMethod.Post, new Uri("token", UriKind.Relative)) 
            {
                // Buffered (Content-Length) rather than JsonContent's chunked stream: not every DSV-compatible endpoint
                // (e.g. tools/secrets/mock_dsv.py) reads chunked request bodies.
                Content = new ByteArrayContent(JsonSerializer.SerializeToUtf8Bytes(body)) { Headers = { ContentType = new MediaTypeHeaderValue("application/json") } },
            }, cancellationToken).ConfigureAwait(false);
        }
        catch (DsvSecretException ex)
        {
            throw new DsvSecretException($"DSV authentication failed ({ex.Message})", ex.Status);
        }

        using (response)
        {
            try
            {
                using var doc = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false), cancellationToken: cancellationToken).ConfigureAwait(false);
                var token = doc.RootElement.GetProperty("accessToken").GetString() ?? throw new DsvSecretException("DSV token response malformed");
                var expiresIn = doc.RootElement.TryGetProperty("expiresIn", out var e) && e.TryGetDouble(out var s) && s > 0 ? s : 3600;
                _token = token;
                _tokenRefreshAt = _time.GetUtcNow() + TimeSpan.FromSeconds(expiresIn * RefreshFraction);
                return token;
            }
            catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException)
            {
                throw new DsvSecretException("DSV token response malformed");
            }
        }
    }

    private async Task<HttpResponseMessage> SendAsync(Func<HttpRequestMessage> requestFactory, CancellationToken cancellationToken)
    {
        var attempts = Math.Max(1, _options.MaxAttempts);
        for (var attempt = 1; ; attempt++)
        {
            using var request = requestFactory();
            try
            {
                var response = await _http.SendAsync(request, HttpCompletionOption.ResponseContentRead, cancellationToken).ConfigureAwait(false);
                var code = (int)response.StatusCode;
                if (code < 400)
                {
                    return response;
                }

                response.Dispose();
                if (code != 429 && code < 500)
                {
                    throw new DsvSecretException($"HTTP {code}", response.StatusCode);
                }

                if (attempt >= attempts)
                {
                    throw new DsvSecretException($"HTTP {code} after {attempts} attempts", response.StatusCode);
                }
            }
            catch (Exception ex) when (ex is HttpRequestException || (ex is TaskCanceledException && !cancellationToken.IsCancellationRequested))
            {
                if (attempt >= attempts)
                {
                    throw new DsvSecretException($"DSV unreachable ({(ex is TaskCanceledException ? "Timeout" : ex.GetType().Name)})");
                }
            }

#pragma warning disable CA5394 // jitter, not security
            var backoff = TimeSpan.FromSeconds(Random.Shared.NextDouble() * Math.Min(2.0, 0.25 * Math.Pow(2, attempt - 1)));
#pragma warning restore CA5394
            await _delay(backoff, cancellationToken).ConfigureAwait(false);
        }
    }
}
