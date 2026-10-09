using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;
using Azure.Messaging.ServiceBus;
using Hello.Common;
using Hello.Common.Azure;
using Hello.Common.Telemetry;
using Hello.Common.Web;

namespace Hello.OrdersApi.Messaging;

public interface IOrderEventPublisher
{
    Task PublishAsync(OrderCreatedEvent orderEvent, CancellationToken cancellationToken);
}

internal static class MessagingTelemetry
{
    /// <summary>Starts the producer span and returns the W3C context to inject into ApplicationProperties.</summary>
    public static Activity? StartPublish(string destination, Guid orderId)
    {
        var activity = HelloTelemetry.Source.StartActivity($"send {destination}", ActivityKind.Producer);
        activity?.SetTag("messaging.system", "servicebus");
        activity?.SetTag("messaging.operation.type", "send");
        activity?.SetTag("messaging.operation.name", "send");
        activity?.SetTag("messaging.destination.name", destination);
        activity?.SetTag("messaging.message.id", orderId.ToString("D"));
        return activity;
    }
}

/// <summary>
/// Publishes to the Service Bus topic with MessageId = order_id (duplicate-detection safe) and W3C trace context in
/// ApplicationProperties `traceparent`/`tracestate`. (Azure.Messaging.ServiceBus also stamps `Diagnostic-Id` when its
/// ActivitySource is enabled; consumers prefer `traceparent`.)
/// </summary>
public sealed partial class ServiceBusOrderEventPublisher : IOrderEventPublisher, IAsyncDisposable
{
    private readonly ServiceBusClient _client;
    private readonly ServiceBusSender _sender;
    private readonly string _topic;
    private readonly ILogger<ServiceBusOrderEventPublisher> _logger;

    public ServiceBusOrderEventPublisher(OrdersSettings settings, IConfiguration configuration, HelloServiceInfo info, ILogger<ServiceBusOrderEventPublisher> logger)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(info);
        _logger = logger;
        _topic = settings.Topic;
        var options = new ServiceBusClientOptions
        {
            Identifier = $"{info.Service}-{Environment.MachineName}",
            TransportType = ServiceBusTransportType.AmqpTcp,
            RetryOptions = new ServiceBusRetryOptions
            {
                Mode = ServiceBusRetryMode.Exponential,
                MaxRetries = 2,
                Delay = TimeSpan.FromMilliseconds(500),
                MaxDelay = TimeSpan.FromSeconds(5),
                TryTimeout = TimeSpan.FromSeconds(5),
            },
        };

        if (!string.IsNullOrWhiteSpace(settings.ServiceBusConnectionString))
        {
            _client = new ServiceBusClient(settings.ServiceBusConnectionString, options);
        }
        else if (!string.IsNullOrWhiteSpace(settings.ServiceBusFqdn))
        {
            _client = new ServiceBusClient(settings.ServiceBusFqdn, AzureCredentialFactory.Create(configuration), options);
        }
        else
        {
            throw new InvalidOperationException("MESSAGING_MODE=servicebus requires SERVICEBUS_FQDN or SERVICEBUS_CONNECTION_STRING.");
        }

        _sender = _client.CreateSender(_topic);
    }

    public async Task PublishAsync(OrderCreatedEvent orderEvent, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(orderEvent);
        using var activity = MessagingTelemetry.StartPublish(_topic, orderEvent.OrderId);
        var message = new ServiceBusMessage(BinaryData.FromBytes(JsonSerializer.SerializeToUtf8Bytes(orderEvent, HelloWebApplicationExtensions.WireJson)))
        {
            MessageId = orderEvent.OrderId.ToString("D"),
            CorrelationId = orderEvent.OrderId.ToString("D"),
            ContentType = "application/json",
            Subject = orderEvent.Event,
        };
        var current = activity ?? Activity.Current;
        var traceparent = HelloTelemetry.ToTraceparent(current);
        if (traceparent is not null)
        {
            message.ApplicationProperties["traceparent"] = traceparent;
            if (!string.IsNullOrEmpty(current!.TraceStateString))
            {
                message.ApplicationProperties["tracestate"] = current.TraceStateString;
            }
        }

        message.ApplicationProperties["event"] = orderEvent.Event;
        await _sender.SendMessageAsync(message, cancellationToken).ConfigureAwait(false);
        LogPublished(_logger, orderEvent.OrderId, _topic);
    }

    public async ValueTask DisposeAsync()
    {
        await _sender.DisposeAsync().ConfigureAwait(false);
        await _client.DisposeAsync().ConfigureAwait(false);
    }

    [LoggerMessage(EventId = 2001, Level = LogLevel.Information, Message = "Published OrderCreated for {order_id} to {topic}")]
    private static partial void LogPublished(ILogger logger, Guid order_id, string topic);
}

/// <summary>MESSAGING_MODE=log — no broker; the event is logged (and kept in a small ring buffer for tests).</summary>
public sealed partial class LogOrderEventPublisher(ILogger<LogOrderEventPublisher> logger) : IOrderEventPublisher
{
    private const int Capacity = 100;
    private readonly ConcurrentQueue<(OrderCreatedEvent Event, string? Traceparent)> _published = new();

    public IReadOnlyList<(OrderCreatedEvent Event, string? Traceparent)> Published => [.. _published];

    public Task PublishAsync(OrderCreatedEvent orderEvent, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(orderEvent);
        using var activity = MessagingTelemetry.StartPublish("order-events", orderEvent.OrderId);
        var traceparent = HelloTelemetry.ToTraceparent(activity ?? Activity.Current);
        _published.Enqueue((orderEvent, traceparent));
        while (_published.Count > Capacity)
        {
            _published.TryDequeue(out _);
        }

        LogEvent(logger, orderEvent.OrderId, orderEvent.Event, traceparent);
        return Task.CompletedTask;
    }

    [LoggerMessage(EventId = 2002, Level = LogLevel.Information, Message = "MESSAGING_MODE=log: would publish {event} for {order_id} traceparent={traceparent}")]
    private static partial void LogEvent(ILogger logger, Guid order_id, string @event, string? traceparent);
}
