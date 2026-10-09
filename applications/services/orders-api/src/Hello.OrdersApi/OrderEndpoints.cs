using Hello.Common.Idempotency;
using Hello.Common.Problems;

namespace Hello.OrdersApi;

public static class OrderEndpoints
{
    public static IEndpointRouteBuilder MapOrderEndpoints(this IEndpointRouteBuilder app)
    {
        var orders = app.MapGroup("/orders");

        orders.MapPost(string.Empty, async (CreateOrderRequest? body, HttpContext ctx, OrderService service) =>
        {
            var key = ctx.Request.Headers[IdempotencyKey.HeaderName].ToString();
            if (!IdempotencyKey.IsValid(key, out var keyError))
            {
                return Results.ValidationProblem(new Dictionary<string, string[]> { [IdempotencyKey.HeaderName] = [keyError!] }, type: HelloProblems.TypeUri("validation"));
            }

            var errors = Validate(body);
            if (errors.Count > 0)
            {
                return Results.ValidationProblem(errors, type: HelloProblems.TypeUri("validation"));
            }

            var outcome = await service.CreateAsync(body!, key, ctx.RequestAborted).ConfigureAwait(false);
            if (outcome.Replayed)
            {
                ctx.Response.Headers[IdempotencyKey.ReplayedHeaderName] = "true";
            }

            return Results.Accepted($"/orders/{outcome.Order.Id}", outcome.Order);
        });

        orders.MapGet(string.Empty, async (int? limit, DateTimeOffset? since, Data.IOrderRepository repo, Hello.Common.Faults.FaultState faults, CancellationToken ct) =>
        {
            var take = Math.Clamp(limit ?? 20, 1, 100);
            faults.ThrowIfInjected(Hello.Common.Faults.FaultTypes.DbError);
            var items = await repo.ListAsync(take, since, ct).ConfigureAwait(false);
            return Results.Ok(new OrderList(items, items.Count));
        });

        orders.MapGet("/{id:guid}", async (Guid id, Data.IOrderRepository repo, Hello.Common.Faults.FaultState faults, CancellationToken ct) =>
        {
            faults.ThrowIfInjected(Hello.Common.Faults.FaultTypes.DbError);
            var order = await repo.GetAsync(id, ct).ConfigureAwait(false);
            return order is null
                ? HelloProblems.Result(StatusCodes.Status404NotFound, "order-not-found", "Order not found")
                : Results.Ok(order);
        });

        orders.MapPatch("/{id:guid}/status", async (Guid id, UpdateOrderStatusRequest? body, OrderService service, CancellationToken ct) =>
        {
            if (body?.Status is null || !OrderStatus.Patchable.Contains(body.Status))
            {
                return Results.ValidationProblem(
                    new Dictionary<string, string[]> { ["status"] = [$"status must be one of: {string.Join(", ", OrderStatus.Patchable)}."] },
                    type: HelloProblems.TypeUri("validation"));
            }

            return Results.Ok(await service.UpdateStatusAsync(id, body, ct).ConfigureAwait(false));
        });

        orders.MapPost("/{id:guid}/republish", async (Guid id, OrderService service, CancellationToken ct) =>
            Results.Accepted($"/orders/{id}", await service.RepublishAsync(id, ct).ConfigureAwait(false)));

        return app;
    }

    internal static Dictionary<string, string[]> Validate(CreateOrderRequest? body)
    {
        var errors = new Dictionary<string, string[]>(StringComparer.Ordinal);
        if (body is null)
        {
            errors["body"] = ["A JSON body is required."];
            return errors;
        }

        if (string.IsNullOrWhiteSpace(body.Sku) || body.Sku.Length > 64)
        {
            errors["sku"] = ["sku is required (max 64 characters)."];
        }

        if (body.Quantity is null or < 1 or > 1000)
        {
            errors["quantity"] = ["quantity must be between 1 and 1000."];
        }

        if (string.IsNullOrWhiteSpace(body.CustomerRef) || body.CustomerRef.Length > 128)
        {
            errors["customer_ref"] = ["customer_ref is required (max 128 characters)."];
        }

        return errors;
    }
}
