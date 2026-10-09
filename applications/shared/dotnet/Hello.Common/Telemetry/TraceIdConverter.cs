using System.Diagnostics;
using System.Globalization;

namespace Hello.Common.Telemetry;

/// <summary>
/// Converts W3C ids to the Datadog log-correlation representation: the decimal string of the low 64 bits.
/// </summary>
public static class TraceIdConverter
{
    public static string ToDatadogTraceId(ActivityTraceId traceId) => LowBitsToDecimal(traceId.ToHexString());

    public static string ToDatadogSpanId(ActivitySpanId spanId) => LowBitsToDecimal(spanId.ToHexString());

    /// <summary>Converts a 16 or 32 hex-character id to the decimal string of its low 64 bits.</summary>
    public static string LowBitsToDecimal(string hex)
    {
        ArgumentException.ThrowIfNullOrEmpty(hex);
        var low = hex.Length > 16 ? hex.AsSpan(hex.Length - 16) : hex.AsSpan();
        return ulong.Parse(low, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture)
            .ToString(CultureInfo.InvariantCulture);
    }
}
