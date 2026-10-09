namespace Hello.InventoryApi;

/// <summary>Cosmos item (container `items`, partition key /sku). Reservations are separate documents in the same partition.</summary>
public sealed record InventoryItem(string Id, string Sku, string DocType, int Quantity, int Reserved, DateTimeOffset UpdatedAt)
{
    public const string ItemType = "item";

    public static InventoryItem Create(string sku, int quantity, int reserved, DateTimeOffset now) =>
        new(sku, sku, ItemType, quantity, reserved, now);
}

public sealed record ReservationDoc(string Id, string Sku, string DocType, Guid OrderId, int Quantity, string Status, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt)
{
    public const string ReservationType = "reservation";

    public static string IdFor(Guid orderId) => $"reservation:{orderId:D}";
}

public sealed record InventoryView(string Sku, int Quantity, int Reserved, DateTimeOffset UpdatedAt)
{
    public static InventoryView From(InventoryItem item) => new(item.Sku, item.Quantity, item.Reserved, item.UpdatedAt);
}

public sealed record SetQuantityRequest(int? Quantity);

public sealed record ReserveRequest(Guid? OrderId, int? Quantity);

public sealed record ReleaseRequest(Guid? OrderId);

public enum ReservationOutcome
{
    Reserved,
    Replayed,
    Released,
    AlreadyReleased,
    NotFound,
    UnknownSku,
    Insufficient,
}

public sealed record ReservationResult(ReservationOutcome Outcome, string Sku, Guid OrderId, int Quantity, int Available)
{
    public string Status => Outcome switch
    {
        ReservationOutcome.Reserved or ReservationOutcome.Replayed => "reserved",
        ReservationOutcome.Released or ReservationOutcome.AlreadyReleased => "released",
        ReservationOutcome.Insufficient => "insufficient",
        _ => "not_found",
    };

    public bool Replayed => Outcome is ReservationOutcome.Replayed or ReservationOutcome.AlreadyReleased;
}

public static class Seed
{
    /// <summary>Deterministic seed: SKU-0001..SKU-0020, quantity 100 + 10·n.</summary>
    public static IEnumerable<(string Sku, int Quantity)> Items() =>
        Enumerable.Range(1, 20).Select(n => ($"SKU-{n:0000}", 100 + (10 * n)));
}
