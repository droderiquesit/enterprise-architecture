using Hello.Common.Faults;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using Polly.CircuitBreaker;
using Polly.Timeout;

namespace Hello.Common.Problems;

/// <summary>Maps exceptions to RFC 7807 responses without leaking internals.</summary>
public sealed partial class HelloExceptionHandler(IProblemDetailsService problemDetails, ILogger<HelloExceptionHandler> logger) : IExceptionHandler
{
    public async ValueTask<bool> TryHandleAsync(HttpContext httpContext, Exception exception, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(httpContext);
        var (status, code, title, detail) = exception switch
        {
            HelloProblemException p => (p.Status, p.Code, p.Title, p.Detail),
            FaultInjectedException f => (StatusCodes.Status503ServiceUnavailable, "fault-injected", "Injected fault", $"A lab fault ({f.FaultType}) was injected."),
            TimeoutRejectedException => (StatusCodes.Status504GatewayTimeout, "dependency-timeout", "Dependency timeout", "A downstream dependency did not answer in time."),
            BrokenCircuitException => (StatusCodes.Status503ServiceUnavailable, "dependency-unavailable", "Dependency unavailable", "A downstream dependency is failing; circuit open."),
            HttpRequestException => (StatusCodes.Status502BadGateway, "dependency-error", "Dependency error", "A downstream dependency call failed."),
            BadHttpRequestException b => (b.StatusCode, "bad-request", "Bad request", "The request could not be read."),
            OperationCanceledException when httpContext.RequestAborted.IsCancellationRequested => (499, "client-closed", "Client closed request", (string?)null),
            _ => (StatusCodes.Status500InternalServerError, "internal-error", "Internal server error", (string?)null),
        };

        if (status >= 500)
        {
            LogServerError(logger, exception, status, code);
        }
        else
        {
            LogClientError(logger, status, code, exception.GetType().Name);
        }

        httpContext.Response.StatusCode = status;
        return await problemDetails.TryWriteAsync(new ProblemDetailsContext
        {
            HttpContext = httpContext,
            Exception = exception,
            ProblemDetails =
            {
                Status = status,
                Title = title,
                Detail = detail,
                Type = HelloProblems.TypeUri(code),
            },
        }).ConfigureAwait(false);
    }

    [LoggerMessage(EventId = 5000, Level = LogLevel.Error, Message = "Request failed with {http_status} ({problem_code})")]
    private static partial void LogServerError(ILogger logger, Exception exception, int http_status, string problem_code);

    [LoggerMessage(EventId = 4000, Level = LogLevel.Information, Message = "Request rejected with {http_status} ({problem_code}): {exception_type}")]
    private static partial void LogClientError(ILogger logger, int http_status, string problem_code, string exception_type);
}
