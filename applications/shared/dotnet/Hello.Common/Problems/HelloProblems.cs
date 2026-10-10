using System.Diagnostics;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;

namespace Hello.Common.Problems;

/// <summary>RFC 7807 helpers. Problem type URIs are URNs (no resolvable documentation site in the lab).</summary>
public static class HelloProblems
{
    public const string ContentType = "application/problem+json";

    public static string TypeUri(string code) => $"urn:enterprise-hello:problem:{code}";

    public static IResult Result(int status, string code, string title, string? detail = null, IDictionary<string, object?>? extensions = null)
    {
        var ext = new Dictionary<string, object?>(StringComparer.Ordinal);
        if (extensions is not null)
        {
            foreach (var (k, v) in extensions)
            {
                ext[k] = v;
            }
        }

        return Results.Problem(detail: detail, statusCode: status, title: title, type: TypeUri(code), extensions: ext);
    }

    internal static void Enrich(ProblemDetails problem, HttpContext http)
    {
        problem.Instance ??= http.Request.Path;
        if (Telemetry.DatadogCorrelation.TryGetCurrent(out var ids))
        {
            problem.Extensions["trace_id"] = ids.TraceId;
        }

        problem.Extensions.Remove("traceId");
        if (problem.Type is null || problem.Type.StartsWith("https://tools.ietf.org", StringComparison.Ordinal))
        {
            problem.Type = TypeUri(problem.Status switch
            {
                400 => "bad-request",
                401 => "unauthorized",
                403 => "forbidden",
                404 => "not-found",
                405 => "method-not-allowed",
                409 => "conflict",
                415 => "unsupported-media-type",
                422 => "unprocessable",
                429 => "rate-limited",
                503 => "unavailable",
                _ => "error",
            });
        }
    }
}

/// <summary>Raised by typed clients/repositories to return a specific problem status to the caller.</summary>
public class HelloProblemException : Exception
{
    public HelloProblemException()
        : this(StatusCodes.Status500InternalServerError, "error", "Error")
    {
    }

    public HelloProblemException(string message)
        : this(StatusCodes.Status500InternalServerError, "error", message)
    {
    }

    public HelloProblemException(string message, Exception innerException)
        : base(message, innerException)
    {
        Status = StatusCodes.Status500InternalServerError;
        Code = "error";
        Title = message;
    }

    public HelloProblemException(int status, string code, string title, string? detail = null, Exception? inner = null)
        : base(detail ?? title, inner)
    {
        Status = status;
        Code = code;
        Title = title;
        Detail = detail;
    }

    public int Status { get; }

    public string Code { get; }

    public string Title { get; }

    public string? Detail { get; }
}

/// <summary>The owned data store is unavailable (SQL/Cosmos). Maps to 503.</summary>
public sealed class DataStoreUnavailableException : HelloProblemException
{
    public DataStoreUnavailableException()
        : this("Data store unavailable.", null)
    {
    }

    public DataStoreUnavailableException(string message)
        : this(message, null)
    {
    }

    public DataStoreUnavailableException(string message, Exception? innerException)
        : base(StatusCodes.Status503ServiceUnavailable, "data-store-unavailable", "Data store unavailable", message, innerException)
    {
    }
}
