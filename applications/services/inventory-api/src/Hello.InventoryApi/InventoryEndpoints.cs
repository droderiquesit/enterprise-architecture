using Hello.Common.Problems;
using Hello.Common.Telemetry;

namespace Hello.InventoryApi;

public static partial class InventoryEndpoints
{
    public static IEndpointRouteBuilder MapInventoryEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/inventory");

        group.MapGet("/{sku}", async (string sku, IInventoryStore store, CancellationToken ct) =>
        {
            if (!ValidSku(sku))
            {
                return InvalidSku();
            }

            var item = await store.GetAsync(sku, ct).ConfigureAwait(false);
            return item is null
                ? HelloProblems.Result(StatusCodes.Status404NotFound, "unknown-sku", "Unknown SKU", $"No inventory for {sku}.")
                : Results.Ok(InventoryView.From(item));
        });

        group.MapPut("/{sku}", async (string sku, SetQuantityRequest? body, IInventoryStore store, CancellationToken ct) =>
        {
            if (!ValidSku(sku))
            {
                return InvalidSku();
            }

            if (body?.Quantity is not { } q || q < 0 || q > 1_000_000)
            {
                return Results.ValidationProblem(new Dictionary<string, string[]> { ["quantity"] = ["quantity must be between 0 and 1000000."] }, type: HelloProblems.TypeUri("validation"));
            }

            return Results.Ok(InventoryView.From(await store.SetQuantityAsync(sku, q, ct).ConfigureAwait(false)));
        });

        group.MapPost("/{sku}/reserve", async (string sku, ReserveRequest? body, IInventoryStore store, HelloMetrics metrics, ILoggerFactory lf, CancellationToken ct) =>
        {
            if (!ValidSku(sku))
            {
                return InvalidSku();
            }

            var errors = new Dictionary<string, string[]>(StringComparer.Ordinal);
            if (body?.OrderId is null || body.OrderId == Guid.Empty)
            {
                errors["order_id"] = ["order_id (uuid) is required."];
            }

            if (body?.Quantity is null or < 1 or > 1000)
            {
                errors["quantity"] = ["quantity must be between 1 and 1000."];
            }

            if (errors.Count > 0)
            {
                return Results.ValidationProblem(errors, type: HelloProblems.TypeUri("validation"));
            }

            var result = await store.ReserveAsync(sku, body!.OrderId!.Value, body.Quantity!.Value, ct).ConfigureAwait(false);
            metrics.InventoryReservations.Add(1, new KeyValuePair<string, object?>("result", result.Outcome.ToString().ToLowerInvariant()));
            LogReservation(lf.CreateLogger("Hello.InventoryApi.Reservations"), result.OrderId, sku, result.Quantity, result.Outcome.ToString());
            return result.Outcome switch
            {
                ReservationOutcome.UnknownSku => HelloProblems.Result(StatusCodes.Status404NotFound, "unknown-sku", "Unknown SKU", $"No inventory for {sku}."),
                ReservationOutcome.Insufficient => HelloProblems.Result(StatusCodes.Status409Conflict, "insufficient-stock", "Insufficient stock", $"Requested {result.Quantity}, available {result.Available}.",
                    new Dictionary<string, object?> { ["available"] = result.Available }),
                _ => Results.Ok(ToBody(result)),
            };
        });

        group.MapPost("/{sku}/release", async (string sku, ReleaseRequest? body, IInventoryStore store, HelloMetrics metrics, CancellationToken ct) =>
        {
            if (!ValidSku(sku))
            {
                return InvalidSku();
            }

            if (body?.OrderId is null || body.OrderId == Guid.Empty)
            {
                return Results.ValidationProblem(new Dictionary<string, string[]> { ["order_id"] = ["order_id (uuid) is required."] }, type: HelloProblems.TypeUri("validation"));
            }

            var result = await store.ReleaseAsync(sku, body.OrderId.Value, ct).ConfigureAwait(false);
            metrics.InventoryReservations.Add(1, new KeyValuePair<string, object?>("result", result.Outcome.ToString().ToLowerInvariant()));
            return Results.Ok(ToBody(result));
        });

        group.MapPost("/seed", async (IInventoryStore store, CancellationToken ct) =>
            Results.Ok(new { seeded = await store.SeedAsync(ct).ConfigureAwait(false) }));

        return app;
    }

    private static object ToBody(ReservationResult r) => new
    {
        reservation_id = $"reservation:{r.OrderId:D}",
        order_id = r.OrderId,
        sku = r.Sku,
        quantity = r.Quantity,
        status = r.Status,
        replayed = r.Replayed,
        available = r.Available,
    };

    private static bool ValidSku(string sku) =>
        !string.IsNullOrWhiteSpace(sku) && sku.Length <= 64 && sku.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.');

    private static IResult InvalidSku() =>
        Results.ValidationProblem(new Dictionary<string, string[]> { ["sku"] = ["sku must be 1-64 characters [A-Za-z0-9-_.]."] }, type: HelloProblems.TypeUri("validation"));

    [LoggerMessage(EventId = 3001, Level = LogLevel.Information, Message = "Reservation {reservation_outcome} for order {order_id} sku={sku} quantity={quantity}")]
    private static partial void LogReservation(ILogger logger, Guid order_id, string sku, int quantity, string reservation_outcome);
}
