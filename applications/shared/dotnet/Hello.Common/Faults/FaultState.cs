using System.Collections.Concurrent;
using System.Text.Json.Serialization;

namespace Hello.Common.Faults;

/// <summary>Fault types accepted by POST /admin/faults (wire names).</summary>
public static class FaultTypes
{
    public const string Http500 = "http_500";
    public const string Latency = "latency";
    public const string DbError = "db_error";
    public const string DependencyTimeout = "dependency_timeout";

    public static readonly IReadOnlyList<string> All = [Http500, Latency, DbError, DependencyTimeout];
}

public sealed record ActiveFault(
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("rate")] double Rate,
    [property: JsonPropertyName("latency_ms")] int LatencyMs,
    [property: JsonPropertyName("created_at")] DateTimeOffset CreatedAt,
    [property: JsonPropertyName("expires_at")] DateTimeOffset ExpiresAt);

/// <summary>In-process registry of active lab faults. Faults always expire (max 900 s).</summary>
public sealed class FaultState
{
    public const int MaxDurationSeconds = 900;

    private readonly ConcurrentDictionary<string, ActiveFault> _faults = new(StringComparer.Ordinal);
    private readonly TimeProvider _time;

    public FaultState(TimeProvider time)
    {
        _time = time ?? throw new ArgumentNullException(nameof(time));
    }

    public ActiveFault Activate(string type, double rate, int latencyMs, int durationSeconds)
    {
        var now = _time.GetUtcNow();
        var fault = new ActiveFault(
            type,
            Math.Clamp(rate, 0, 1),
            Math.Clamp(latencyMs, 0, 60_000),
            now,
            now.AddSeconds(Math.Clamp(durationSeconds, 1, MaxDurationSeconds)));
        _faults[type] = fault;
        return fault;
    }

    public void Clear() => _faults.Clear();

    public IReadOnlyList<ActiveFault> Active()
    {
        var now = _time.GetUtcNow();
        foreach (var (key, fault) in _faults)
        {
            if (fault.ExpiresAt <= now)
            {
                _faults.TryRemove(key, out _);
            }
        }

        return [.. _faults.Values.OrderBy(f => f.Type, StringComparer.Ordinal)];
    }

    /// <summary>Returns the active fault of this type when the dice roll says it should fire.</summary>
    public bool ShouldInject(string type, out ActiveFault? fault)
    {
        fault = null;
        if (_faults.IsEmpty || !_faults.TryGetValue(type, out var candidate))
        {
            return false;
        }

        if (candidate.ExpiresAt <= _time.GetUtcNow())
        {
            _faults.TryRemove(type, out _);
            return false;
        }

        if (candidate.Rate <= 0 || Random.Shared.NextDouble() >= candidate.Rate)
        {
            return false;
        }

        fault = candidate;
        return true;
    }

    /// <summary>Throws <see cref="FaultInjectedException"/> when a fault of this type fires (used by repositories for db_error).</summary>
    public void ThrowIfInjected(string type)
    {
        if (ShouldInject(type, out _))
        {
            throw new FaultInjectedException(type);
        }
    }
}

public sealed class FaultInjectedException : Exception
{
    public FaultInjectedException()
        : this("unknown")
    {
    }

    public FaultInjectedException(string faultType)
        : base($"Injected lab fault: {faultType}")
    {
        FaultType = faultType;
    }

    public FaultInjectedException(string message, Exception innerException)
        : base(message, innerException)
    {
        FaultType = "unknown";
    }

    public string FaultType { get; }
}
