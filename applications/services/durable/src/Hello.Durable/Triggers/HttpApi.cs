using System.Text.Json;
using Hello.Common;
using Hello.Common.Problems;
using Hello.Durable.Orchestrations;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.DurableTask;
using Microsoft.DurableTask.Client;

namespace Hello.Durable.Triggers;

public sealed record BatchRequest(int? Items, bool? Enqueue);

/// <summary>
/// HTTP API (ASP.NET Core integration). Anonymous at the Functions layer: the app is reachable only on the private
/// network (inbound access is owned by the deployment root).
/// </summary>
public sealed class HttpApi(HelloServiceInfo info, DurableSettings settings, TimeProvider time, OrderEventStarter starter)
{
    /// <summary>
    /// Lab/manual entry point: same body as the `order-events` OrderCreated message; starts (or no-ops for an existing)
    /// OrderProcessing instance "order-{order_id}". Used for smoke tests when Service Bus is not available.
    /// </summary>
    [Function("StartOrderWorkflow")]
    public async Task<IActionResult> StartOrder(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "workflows/order")] HttpRequest req,
        [DurableClient] DurableTaskClient client)
    {
        ArgumentNullException.ThrowIfNull(req);
        using var reader = new StreamReader(req.Body);
        var body = await reader.ReadToEndAsync(req.HttpContext.RequestAborted).ConfigureAwait(false);
        var props = new Dictionary<string, object>();
        if (req.Headers.TryGetValue("traceparent", out var tp))
        {
            props["traceparent"] = tp.ToString();
        }

        var started = await starter.StartAsync(client, body, props, null, req.HttpContext.RequestAborted).ConfigureAwait(false);
        if (started is null)
        {
            return Problem(StatusCodes.Status409Conflict, "not-started", "Workflow not started", "Invalid payload or the instance already exists.");
        }

        return Accepted(started);
    }

    [Function("Healthz")]
    public IActionResult Healthz([HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "healthz")] HttpRequest req) =>
        new OkObjectResult(new { status = "ok", service = info.Service });

    /// <summary>
    /// Readiness: the Durable task hub backend (runtime storage) answers a point lookup within 2s.
    /// Business-database reachability is reported by the activities themselves, not gated here.
    /// </summary>
    [Function("Readyz")]
    public async Task<IActionResult> Readyz(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "readyz")] HttpRequest req,
        [DurableClient] DurableTaskClient client)
    {
        ArgumentNullException.ThrowIfNull(req);
        ArgumentNullException.ThrowIfNull(client);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(req.HttpContext.RequestAborted);
        cts.CancelAfter(TimeSpan.FromSeconds(2));
        try
        {
            await client.GetInstanceAsync("readyz-probe", getInputsAndOutputs: false, cts.Token).ConfigureAwait(false);
            return new OkObjectResult(new { status = "ready", service = info.Service, checks = new { durable_backend = "ok" } });
        }
        catch (Exception ex) when (ex is OperationCanceledException or InvalidOperationException or IOException or Azure.RequestFailedException)
        {
            return new ObjectResult(new { status = "not-ready", service = info.Service, checks = new { durable_backend = ex.GetType().Name } })
            {
                StatusCode = StatusCodes.Status503ServiceUnavailable,
            };
        }
    }

    [Function("Version")]
    public IActionResult Version([HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "version")] HttpRequest req) =>
        new OkObjectResult(new { service = info.Service, version = info.Version, commit = info.Commit, build_time = info.BuildTime, runtime = info.Runtime });

    [Function("StartBatch")]
    public async Task<IActionResult> StartBatch(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "workflows/batch")] HttpRequest req,
        [DurableClient] DurableTaskClient client)
    {
        ArgumentNullException.ThrowIfNull(req);
        ArgumentNullException.ThrowIfNull(client);
        BatchRequest? body;
        try
        {
            body = await JsonSerializer.DeserializeAsync<BatchRequest>(req.Body, Hello.Common.Web.HelloWebApplicationExtensions.WireJson, req.HttpContext.RequestAborted).ConfigureAwait(false);
        }
        catch (JsonException)
        {
            body = null;
        }

        if (body?.Items is not { } items || items < 1 || items > BatchProcessing.MaxItems)
        {
            return Problem(StatusCodes.Status400BadRequest, "validation", "Invalid batch request", $"items must be between 1 and {BatchProcessing.MaxItems}.");
        }

        var instanceId = $"batch-{time.GetUtcNow():yyyyMMddHHmmss}-{Guid.NewGuid():N}"[..40];
        await client.ScheduleNewOrchestrationInstanceAsync(new TaskName(BatchProcessing.Name), new BatchInput(items, body.Enqueue ?? false), new StartOrchestrationOptions(instanceId), req.HttpContext.RequestAborted).ConfigureAwait(false);
        return Accepted(instanceId);
    }

    [Function("StartReconciliation")]
    public async Task<IActionResult> StartReconciliation(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "workflows/reconciliation")] HttpRequest req,
        [DurableClient] DurableTaskClient client)
    {
        ArgumentNullException.ThrowIfNull(req);
        ArgumentNullException.ThrowIfNull(client);
        var instanceId = await Timers.StartReconciliationAsync(client, settings, time, "manual", req.HttpContext.RequestAborted).ConfigureAwait(false);
        return Accepted(instanceId);
    }

    [Function("GetWorkflowStatus")]
    public static async Task<IActionResult> GetStatus(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "workflows/{instanceId}")] HttpRequest req,
        string instanceId,
        [DurableClient] DurableTaskClient client)
    {
        ArgumentNullException.ThrowIfNull(req);
        ArgumentNullException.ThrowIfNull(client);
        if (string.IsNullOrWhiteSpace(instanceId) || instanceId.Length > 128)
        {
            return Problem(StatusCodes.Status400BadRequest, "validation", "Invalid instance id");
        }

        var meta = await client.GetInstanceAsync(instanceId, getInputsAndOutputs: true, req.HttpContext.RequestAborted).ConfigureAwait(false);
        if (meta is null)
        {
            return Problem(StatusCodes.Status404NotFound, "workflow-not-found", "Workflow not found");
        }

        return new OkObjectResult(new
        {
            instance_id = meta.InstanceId,
            name = meta.Name,
            runtime_status = meta.RuntimeStatus.ToString(),
            created_at = meta.CreatedAt,
            last_updated_at = meta.LastUpdatedAt,
            custom_status = ParseJson(meta.SerializedCustomStatus),
            output = ParseJson(meta.SerializedOutput),
            failure = meta.FailureDetails is null ? null : new { error_type = meta.FailureDetails.ErrorType, message = meta.FailureDetails.ErrorMessage },
        });
    }

    private static JsonElement? ParseJson(string? json)
    {
        if (string.IsNullOrEmpty(json))
        {
            return null;
        }

        try
        {
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.Clone();
        }
        catch (JsonException)
        {
            return JsonSerializer.SerializeToElement(json);
        }
    }

    private static AcceptedResult Accepted(string instanceId) =>
        new($"/api/workflows/{instanceId}", new { instance_id = instanceId, status_uri = $"/api/workflows/{instanceId}" });

    private static ObjectResult Problem(int status, string code, string title, string? detail = null) =>
        new(new ProblemDetails { Status = status, Title = title, Detail = detail, Type = HelloProblems.TypeUri(code) })
        {
            StatusCode = status,
            ContentTypes = { HelloProblems.ContentType },
        };
}
