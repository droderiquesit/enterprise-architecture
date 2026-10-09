using System.Net;
using System.Net.Http.Json;
using Hello.Common.Web;
using Microsoft.Extensions.Logging;

namespace Hello.Durable.Services;

/// <summary>Thrown for non-retryable business outcomes the orchestrator should not retry blindly.</summary>
public sealed class DependencyException : Exception
{
    public DependencyException()
    {
    }

    public DependencyException(string message)
        : base(message)
    {
    }

    public DependencyException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed partial class InventoryService(HttpClient http, DurableSettings settings, ILogger<InventoryService> logger) : IInventoryService
{
    public async Task<ReserveResult> ReserveAsync(ReserveInput input, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(input);
        if (settings.InventoryApiUrl is null)
        {
            LogSimulated(logger, input.OrderId);
            return new ReserveResult(true, "reserved", Simulated: true);
        }

        using var response = await http.PostAsJsonAsync(
            new Uri($"inventory/{Uri.EscapeDataString(input.Sku)}/reserve", UriKind.Relative),
            new { order_id = input.OrderId, quantity = input.Quantity },
            HelloWebApplicationExtensions.WireJson,
            cancellationToken).ConfigureAwait(false);
        return response.StatusCode switch
        {
            HttpStatusCode.OK => new ReserveResult(true, "reserved", false),
            HttpStatusCode.Conflict => new ReserveResult(false, "insufficient", false),
            HttpStatusCode.NotFound => new ReserveResult(false, "unknown_sku", false),
            _ => throw new HttpRequestException($"inventory reserve returned {(int)response.StatusCode}", null, response.StatusCode),
        };
    }

    public async Task ReleaseAsync(ReleaseInput input, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(input);
        if (settings.InventoryApiUrl is null)
        {
            return;
        }

        using var response = await http.PostAsJsonAsync(
            new Uri($"inventory/{Uri.EscapeDataString(input.Sku)}/release", UriKind.Relative),
            new { order_id = input.OrderId },
            HelloWebApplicationExtensions.WireJson,
            cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode && response.StatusCode != HttpStatusCode.NotFound)
        {
            throw new HttpRequestException($"inventory release returned {(int)response.StatusCode}", null, response.StatusCode);
        }
    }

    [LoggerMessage(EventId = 7301, Level = LogLevel.Information, Message = "INVENTORY_API_URL unset: simulated reservation for {order_id}")]
    private static partial void LogSimulated(ILogger logger, Guid order_id);
}

public sealed class PaymentService(HttpClient http, DurableSettings settings) : IPaymentService
{
    public async Task<PaymentResult> ChargeAsync(ChargeInput input, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(input);
        if (settings.PartnerApiUrl is null)
        {
            return new PaymentResult($"sim-{input.OrderId:N}", "approved");
        }

        using var response = await http.PostAsJsonAsync(
            new Uri("payments", UriKind.Relative),
            new { order_id = input.OrderId, amount = input.Amount },
            HelloWebApplicationExtensions.WireJson,
            cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            // 5xx/429 → activity failure → durable RetryPolicy retries; partner is idempotent by order_id.
            throw new HttpRequestException($"partner payments returned {(int)response.StatusCode}", null, response.StatusCode);
        }

        var body = await response.Content.ReadFromJsonAsync<PartnerPayment>(HelloWebApplicationExtensions.WireJson, cancellationToken).ConfigureAwait(false)
            ?? throw new DependencyException("empty payment response");
        return new PaymentResult(body.PaymentId ?? string.Empty, body.Status ?? "unknown");
    }

    private sealed record PartnerPayment(string? PaymentId, string? Status);
}

public sealed partial class OrdersService(HttpClient http, DurableSettings settings, ILogger<OrdersService> logger) : IOrdersService
{
    public async Task UpdateStatusAsync(StatusUpdateInput input, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(input);
        if (settings.OrdersApiUrl is null)
        {
            LogSkipped(logger, input.OrderId, input.Status);
            return;
        }

        using var request = new HttpRequestMessage(HttpMethod.Patch, new Uri($"orders/{input.OrderId:D}/status", UriKind.Relative))
        {
            Content = JsonContent.Create(new { status = input.Status, reason = input.Reason, workflow_instance_id = input.WorkflowInstanceId }, options: HelloWebApplicationExtensions.WireJson),
        };
        using var response = await http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        if (response.StatusCode is HttpStatusCode.Conflict or HttpStatusCode.NotFound)
        {
            // Terminal/unknown order: not retryable; record and move on.
            LogRejected(logger, input.OrderId, input.Status, (int)response.StatusCode);
            return;
        }

        response.EnsureSuccessStatusCode();
    }

    public async Task<IReadOnlyList<OrderSnapshot>> GetOrdersSinceAsync(DateTimeOffset since, CancellationToken cancellationToken)
    {
        if (settings.OrdersApiUrl is null)
        {
            return [];
        }

        var uri = new Uri($"orders?limit=100&since={Uri.EscapeDataString(since.UtcDateTime.ToString("O", System.Globalization.CultureInfo.InvariantCulture))}", UriKind.Relative);
        var list = await http.GetFromJsonAsync<OrderListDto>(uri, HelloWebApplicationExtensions.WireJson, cancellationToken).ConfigureAwait(false);
        return [.. (list?.Items ?? []).Select(o => new OrderSnapshot(o.Id, o.Status ?? "Unknown", o.CreatedAt, o.UpdatedAt))];
    }

    private sealed record OrderListDto(List<OrderDto>? Items);

    private sealed record OrderDto(Guid Id, string? Status, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt);

    [LoggerMessage(EventId = 7311, Level = LogLevel.Information, Message = "ORDERS_API_URL unset: skipped status {order_status} for {order_id}")]
    private static partial void LogSkipped(ILogger logger, Guid order_id, string order_status);

    [LoggerMessage(EventId = 7312, Level = LogLevel.Warning, Message = "orders-api rejected status {order_status} for {order_id} with {http_status}")]
    private static partial void LogRejected(ILogger logger, Guid order_id, string order_status, int http_status);
}
