using System.Net.Http.Headers;
using Hello.Common.Idempotency;
using Hello.Common.Problems;

namespace Hello.Bff;

/// <summary>Pass-through of a downstream JSON response (status, content type, body).</summary>
public static class Proxy
{
    private const int MaxBodyBytes = 1024 * 1024;

    public static async Task<IResult> SendAsync(HttpClient http, HttpRequestMessage request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(http);
        ArgumentNullException.ThrowIfNull(request);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseContentRead, cancellationToken).ConfigureAwait(false);
        var body = await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
        if (body.Length > MaxBodyBytes)
        {
            throw new HelloProblemException(StatusCodes.Status502BadGateway, "dependency-error", "Dependency error", "Downstream response too large.");
        }

        var contentType = response.Content.Headers.ContentType?.ToString() ?? "application/json";
        var result = Results.Bytes(body, contentType);
        return new StatusPassThrough(result, (int)response.StatusCode, response.Headers.TryGetValues(IdempotencyKey.ReplayedHeaderName, out var replayed) ? replayed.FirstOrDefault() : null);
    }

    public static HttpRequestMessage Build(HttpMethod method, string relative, HttpContent? content = null, string? idempotencyKey = null)
    {
        var req = new HttpRequestMessage(method, new Uri(relative, UriKind.Relative)) { Content = content };
        if (!string.IsNullOrEmpty(idempotencyKey))
        {
            req.Headers.TryAddWithoutValidation(IdempotencyKey.HeaderName, idempotencyKey);
        }

        return req;
    }

    private sealed class StatusPassThrough(IResult inner, int status, string? replayed) : IResult
    {
        public Task ExecuteAsync(HttpContext httpContext)
        {
            httpContext.Response.StatusCode = status;
            if (replayed is not null)
            {
                httpContext.Response.Headers[IdempotencyKey.ReplayedHeaderName] = replayed;
            }

            return inner.ExecuteAsync(httpContext);
        }
    }
}

public interface IDownstream
{
    HttpClient Http { get; }

    bool Configured { get; }
}

public sealed class CatalogApi(HttpClient http) : IDownstream
{
    public HttpClient Http { get; } = http;

    public bool Configured => Http.BaseAddress is not null;
}

public sealed class OrdersApi(HttpClient http) : IDownstream
{
    public HttpClient Http { get; } = http;

    public bool Configured => Http.BaseAddress is not null;
}

public sealed class InventoryApi(HttpClient http) : IDownstream
{
    public HttpClient Http { get; } = http;

    public bool Configured => Http.BaseAddress is not null;
}

/// <summary>Adapter roundtrips use absolute URLs from ADAPTERS_JSON.</summary>
public sealed class AdaptersApi(HttpClient http)
{
    public HttpClient Http { get; } = http;
}
