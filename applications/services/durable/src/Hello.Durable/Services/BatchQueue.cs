using System.Text.Json;
using Azure.Messaging.ServiceBus;
using Hello.Common.Azure;
using Hello.Common.Telemetry;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace Hello.Durable.Services;

/// <summary>Sends one message per item id to the `batch-items` queue (MessageId = item id → duplicate-detection safe).</summary>
public sealed partial class ServiceBusBatchQueue : IBatchQueue, IAsyncDisposable
{
    private readonly ServiceBusClient? _client;
    private readonly ServiceBusSender? _sender;
    private readonly ILogger<ServiceBusBatchQueue> _logger;

    public ServiceBusBatchQueue(DurableSettings settings, IConfiguration configuration, ILogger<ServiceBusBatchQueue> logger)
    {
        ArgumentNullException.ThrowIfNull(settings);
        _logger = logger;
        var options = new ServiceBusClientOptions { RetryOptions = { MaxRetries = 2, TryTimeout = TimeSpan.FromSeconds(10) } };
        if (!string.IsNullOrWhiteSpace(settings.ServiceBusConnectionString))
        {
            _client = new ServiceBusClient(settings.ServiceBusConnectionString, options);
        }
        else if (!string.IsNullOrWhiteSpace(settings.ServiceBusFqdn))
        {
            _client = new ServiceBusClient(settings.ServiceBusFqdn, AzureCredentialFactory.Create(configuration), options);
        }

        _sender = _client?.CreateSender(settings.BatchQueue);
    }

    public async Task EnqueueAsync(EnqueueInput input, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(input);
        if (_sender is null)
        {
            LogSkipped(_logger, input.BatchId, input.ItemIds.Count);
            return;
        }

        var traceparent = HelloTelemetry.ToTraceparent(System.Diagnostics.Activity.Current);
        var messages = input.ItemIds.Select(id =>
        {
            var m = new ServiceBusMessage(BinaryData.FromString(JsonSerializer.Serialize(new { batch_id = input.BatchId, item_id = id })))
            {
                MessageId = id,
                ContentType = "application/json",
                Subject = "BatchItem",
            };
            if (traceparent is not null)
            {
                m.ApplicationProperties["traceparent"] = traceparent;
            }

            return m;
        }).ToList();

        foreach (var chunk in messages.Chunk(50))
        {
            await _sender.SendMessagesAsync(chunk, cancellationToken).ConfigureAwait(false);
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_sender is not null)
        {
            await _sender.DisposeAsync().ConfigureAwait(false);
        }

        if (_client is not null)
        {
            await _client.DisposeAsync().ConfigureAwait(false);
        }
    }

    [LoggerMessage(EventId = 7321, Level = LogLevel.Information, Message = "Service Bus not configured: {item_count} batch items for {batch_id} not enqueued")]
    private static partial void LogSkipped(ILogger logger, string batch_id, int item_count);
}
