using Microsoft.Azure.Functions.Worker;
using Microsoft.DurableTask;
using Microsoft.Extensions.Logging;

namespace Hello.Durable.Orchestrations;

/// <summary>
/// OrderProcessing saga: ReserveInventory → ChargePayment (retry ×3 exponential, raced against a durable timer) →
/// RecordFulfillment → UpdateOrderStatus. Any failure after the reservation releases it (compensation), marks the order
/// Failed and records the failure. Deterministic: only context time/ids, no I/O, replay-safe logging.
/// </summary>
public static partial class OrderProcessing
{
    public const string Name = nameof(OrderProcessing);

    /// <summary>Activities that talk to idempotent HTTP APIs: 3 attempts, 2 s → 4 s backoff.</summary>
    public static readonly TaskOptions DefaultRetry = TaskOptions.FromRetryPolicy(new RetryPolicy(
        maxNumberOfAttempts: 3, firstRetryInterval: TimeSpan.FromSeconds(2), backoffCoefficient: 2.0, maxRetryInterval: TimeSpan.FromSeconds(30)));

    /// <summary>ChargePayment: 3 attempts, exponential backoff 1 s → 2 s (partner-sim is idempotent by order_id).</summary>
    public static readonly TaskOptions PaymentRetry = TaskOptions.FromRetryPolicy(new RetryPolicy(
        maxNumberOfAttempts: 3, firstRetryInterval: TimeSpan.FromSeconds(1), backoffCoefficient: 2.0, maxRetryInterval: TimeSpan.FromSeconds(10)));

    [Function(Name)]
    public static async Task<OrderWorkflowResult> RunAsync([OrchestrationTrigger] TaskOrchestrationContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var input = context.GetInput<OrderWorkflowInput>() ?? throw new InvalidOperationException("OrderProcessing requires input.");
        var log = context.CreateReplaySafeLogger(Name);
        var steps = new List<string>();
        var reserved = false;
        LogStarted(log, input.OrderId, context.InstanceId);

        try
        {
            context.SetCustomStatus(new { step = "reserve" });
            var reservation = await context.CallActivityAsync<ReserveResult>(WorkflowActivityNames.ReserveInventory, new ReserveInput(input.OrderId, input.Sku, input.Quantity), DefaultRetry);
            steps.Add($"reserve:{reservation.Status}");
            if (!reservation.Reserved)
            {
                return await FailAsync(context, input, steps, $"inventory_{reservation.Status}", compensate: false, log);
            }

            reserved = true;
            await context.CallActivityAsync(WorkflowActivityNames.UpdateOrderStatus, new StatusUpdateInput(input.OrderId, "Reserved", null, context.InstanceId), DefaultRetry);

            context.SetCustomStatus(new { step = "charge" });
            var (payment, failure) = await ChargeWithTimeoutAsync(context, input);
            steps.Add($"charge:{payment?.Status ?? failure}");
            if (failure is not null)
            {
                return await FailAsync(context, input, steps, failure, compensate: reserved, log);
            }

            await context.CallActivityAsync(WorkflowActivityNames.UpdateOrderStatus, new StatusUpdateInput(input.OrderId, "Charged", null, context.InstanceId), DefaultRetry);

            context.SetCustomStatus(new { step = "fulfill" });
            await context.CallActivityAsync(
                WorkflowActivityNames.RecordFulfillment,
                new FulfillmentRecord(input.OrderId, input.Sku, input.Quantity, input.Amount, WorkflowStatus.Fulfilled, null, payment!.PaymentId, context.InstanceId, context.CurrentUtcDateTime),
                DefaultRetry);
            steps.Add("fulfillment:recorded");

            await context.CallActivityAsync(WorkflowActivityNames.UpdateOrderStatus, new StatusUpdateInput(input.OrderId, WorkflowStatus.Fulfilled, null, context.InstanceId), DefaultRetry);
            steps.Add("status:Fulfilled");
            context.SetCustomStatus(new { step = "done", outcome = WorkflowStatus.Fulfilled });
            LogCompleted(log, input.OrderId, WorkflowStatus.Fulfilled, null);
            return new OrderWorkflowResult(input.OrderId, WorkflowStatus.Fulfilled, null, payment.PaymentId, steps);
        }
        catch (TaskFailedException ex)
        {
            steps.Add($"error:{ex.TaskName}");
            return await FailAsync(context, input, steps, $"activity_failed:{ex.TaskName}", compensate: reserved, log);
        }
    }

    /// <summary>Payment with bounded retries, raced against a durable timer (timeout path → compensation).</summary>
    internal static async Task<(PaymentResult? Payment, string? Failure)> ChargeWithTimeoutAsync(TaskOrchestrationContext context, OrderWorkflowInput input)
    {
        using var timeoutCts = new CancellationTokenSource();
        var deadline = context.CurrentUtcDateTime.AddSeconds(Math.Max(1, input.PaymentTimeoutSeconds));
        var chargeTask = context.CallActivityAsync<PaymentResult>(WorkflowActivityNames.ChargePayment, new ChargeInput(input.OrderId, input.Amount), PaymentRetry);
        var timeoutTask = context.CreateTimer(deadline, timeoutCts.Token);

        var winner = await Task.WhenAny(chargeTask, timeoutTask);
        if (winner != chargeTask)
        {
            return (null, "payment_timeout");
        }

        // Cancel the durable timer so the orchestration can complete.
#pragma warning disable CA1849 // Cancel synchronously: orchestrator code must stay on the orchestration thread.
        timeoutCts.Cancel();
#pragma warning restore CA1849
        try
        {
            var payment = await chargeTask;
            return payment.Approved ? (payment, null) : (payment, "payment_declined");
        }
        catch (TaskFailedException)
        {
            return (null, "payment_error");
        }
    }

    private static async Task<OrderWorkflowResult> FailAsync(
        TaskOrchestrationContext context, OrderWorkflowInput input, List<string> steps, string reason, bool compensate, ILogger log)
    {
        context.SetCustomStatus(new { step = "compensate", reason });
        if (compensate)
        {
            try
            {
                await context.CallActivityAsync(WorkflowActivityNames.ReleaseInventory, new ReleaseInput(input.OrderId, input.Sku), DefaultRetry);
                steps.Add("compensate:released");
            }
            catch (TaskFailedException)
            {
                steps.Add("compensate:release_failed");
            }
        }

        try
        {
            await context.CallActivityAsync(WorkflowActivityNames.UpdateOrderStatus, new StatusUpdateInput(input.OrderId, WorkflowStatus.Failed, reason, context.InstanceId), DefaultRetry);
            steps.Add("status:Failed");
        }
        catch (TaskFailedException)
        {
            steps.Add("status:update_failed");
        }

        try
        {
            await context.CallActivityAsync(
                WorkflowActivityNames.RecordFulfillment,
                new FulfillmentRecord(input.OrderId, input.Sku, input.Quantity, input.Amount, WorkflowStatus.Failed, reason, null, context.InstanceId, context.CurrentUtcDateTime),
                DefaultRetry);
            steps.Add("fulfillment:recorded");
        }
        catch (TaskFailedException)
        {
            steps.Add("fulfillment:record_failed");
        }

        context.SetCustomStatus(new { step = "done", outcome = WorkflowStatus.Failed, reason });
        LogCompleted(log, input.OrderId, WorkflowStatus.Failed, reason);
        return new OrderWorkflowResult(input.OrderId, WorkflowStatus.Failed, reason, null, steps);
    }

    [LoggerMessage(EventId = 7001, Level = LogLevel.Information, Message = "OrderProcessing started for {order_id} ({workflow_instance_id})")]
    private static partial void LogStarted(ILogger logger, Guid order_id, string workflow_instance_id);

    [LoggerMessage(EventId = 7002, Level = LogLevel.Information, Message = "OrderProcessing for {order_id} completed: {workflow_outcome} {workflow_reason}")]
    private static partial void LogCompleted(ILogger logger, Guid order_id, string workflow_outcome, string? workflow_reason);
}
