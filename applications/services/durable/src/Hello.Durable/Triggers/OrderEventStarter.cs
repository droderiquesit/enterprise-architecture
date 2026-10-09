using System.Diagnostics;
using System.Text.Json;
using Azure.Messaging.ServiceBus;
using Hello.Common.Telemetry;
using Hello.Common.Web;
using Hello.Durable.Orchestrations;
using Microsoft.Azure.Functions.Worker;
using Microsoft.DurableTask;
using Microsoft.DurableTask.Client;
using Microsoft.Extensions.Logging;

namespace Hello.Durable.Triggers;

public sealed record OrderCreatedMessage(string? Event, Guid OrderId, string? Sku, int Quantity, decimal Amount, DateTimeOffset CreatedAt);

/// <summary>
/// Service Bus topic `order-events` / subscription `fulfillment` → starts OrderProcessing with instance id
/// "order-{order_id}" unless it already exists (at-least-once delivery safe). The producer's traceparent is attached
/// as a span LINK (async boundary), not as parent.
/// </summary>
public sealed partial class OrderEventStarter(DurableSettings settings, ILogger<OrderEventStarter> logger)
{
    public const string FunctionName = "OrderEventsStarter";

    [Function(FunctionName)]
    public Task RunAsync(
        [ServiceBusTrigger("order-events", "fulfillment", Connection = "ServiceBusConnection")] ServiceBusReceivedMessage message,
        [DurableClient] DurableTaskClient client,
        FunctionContext context)
    {
        ArgumentNullException.ThrowIfNull(message);
        ArgumentNullException.ThrowIfNull(context);
        return StartAsync(client, message.Body.ToString(), message.ApplicationProperties, message.MessageId, context.CancellationToken);
    }

    /// <summary>Testable core: returns the instance id started, or null when skipped.</summary>
    public async Task<string?> StartAsync(DurableTaskClient client, string body, IReadOnlyDictionary<string, object> properties, string? messageId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(client);
        ArgumentNullException.ThrowIfNull(properties);
        properties.TryGetValue("traceparent", out var tp);
        properties.TryGetValue("tracestate", out var ts);
        using var activity = StartConsumerActivity(tp as string, ts as string, messageId);

        OrderCreatedMessage? evt;
        try
        {
            evt = JsonSerializer.Deserialize<OrderCreatedMessage>(body, HelloWebApplicationExtensions.WireJson);
        }
        catch (JsonException)
        {
            evt = null;
        }

        if (evt is null || evt.OrderId == Guid.Empty || string.IsNullOrWhiteSpace(evt.Sku) || !string.Equals(evt.Event, "OrderCreated", StringComparison.Ordinal))
        {
            LogInvalid(logger, messageId);
            activity?.SetStatus(ActivityStatusCode.Error, "invalid payload");
            return null;
        }

        var instanceId = InstanceIdFor(evt.OrderId);
        activity?.SetTag("workflow.instance_id", instanceId);
        if (await client.GetInstanceAsync(instanceId, getInputsAndOutputs: false, cancellationToken).ConfigureAwait(false) is not null)
        {
            LogSkipped(logger, instanceId);
            return null;
        }

        var input = new OrderWorkflowInput(evt.OrderId, evt.Sku, evt.Quantity, evt.Amount, evt.CreatedAt, settings.PaymentTimeoutSeconds);
        try
        {
            await client.ScheduleNewOrchestrationInstanceAsync(new TaskName(OrderProcessing.Name), input, new StartOrchestrationOptions(instanceId), cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // Concurrent duplicate delivery may have created it between the check and the start.
            if (await client.GetInstanceAsync(instanceId, getInputsAndOutputs: false, cancellationToken).ConfigureAwait(false) is not null)
            {
                LogSkipped(logger, instanceId);
                return null;
            }

            throw;
        }

        LogStarted(logger, instanceId, evt.OrderId);
        return instanceId;
    }

    public static string InstanceIdFor(Guid orderId) => $"order-{orderId:D}";

    /// <summary>Consumer span whose parent is the current (Functions invocation) span, with a link to the producer.</summary>
    internal static Activity? StartConsumerActivity(string? traceparent, string? tracestate, string? messageId)
    {
        var links = HelloTelemetry.TryCreateLink(traceparent, tracestate, out var link) ? new[] { link } : null;
        var activity = HelloTelemetry.Source.StartActivity("process order-events", ActivityKind.Consumer, parentContext: default, tags: null, links: links);
        activity?.SetTag("messaging.system", "servicebus");
        activity?.SetTag("messaging.operation.type", "process");
        activity?.SetTag("messaging.destination.name", "order-events");
        activity?.SetTag("messaging.destination.subscription.name", "fulfillment");
        if (messageId is not null)
        {
            activity?.SetTag("messaging.message.id", messageId);
        }

        return activity;
    }

    [LoggerMessage(EventId = 7501, Level = LogLevel.Information, Message = "Started {workflow_instance_id} for order {order_id}")]
    private static partial void LogStarted(ILogger logger, string workflow_instance_id, Guid order_id);

    [LoggerMessage(EventId = 7502, Level = LogLevel.Information, Message = "Orchestration {workflow_instance_id} already exists; duplicate delivery skipped")]
    private static partial void LogSkipped(ILogger logger, string workflow_instance_id);

    [LoggerMessage(EventId = 7503, Level = LogLevel.Warning, Message = "Ignoring invalid order-events message {message_id}")]
    private static partial void LogInvalid(ILogger logger, string? message_id);
}
