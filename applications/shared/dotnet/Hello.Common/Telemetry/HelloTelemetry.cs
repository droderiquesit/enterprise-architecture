using System.Diagnostics;

namespace Hello.Common.Telemetry;

/// <summary>Shared ActivitySource for application-level spans (producer/consumer spans, business operations).</summary>
public static class HelloTelemetry
{
    public const string ActivitySourceName = "Hello.App";

    public static readonly ActivitySource Source = new(ActivitySourceName);

    /// <summary>W3C traceparent for an activity, e.g. 00-&lt;trace&gt;-&lt;span&gt;-01.</summary>
    public static string? ToTraceparent(Activity? activity)
    {
        if (activity is null || activity.IdFormat != ActivityIdFormat.W3C)
        {
            return null;
        }

        var flags = activity.ActivityTraceFlags.HasFlag(ActivityTraceFlags.Recorded) ? "01" : "00";
        return $"00-{activity.TraceId.ToHexString()}-{activity.SpanId.ToHexString()}-{flags}";
    }

    /// <summary>
    /// W3C traceparent of the active span: <paramref name="activity"/> when given, else the active Datadog span
    /// (TELEMETRY_SDK=datadog — ASP.NET Core's own Activity is then NOT the Datadog span), else Activity.Current.
    /// The Datadog form carries flag 01 (the tracer owns the sampling decision; Datadog propagation headers carry it).
    /// </summary>
    public static string? CurrentTraceparent(Activity? activity = null)
    {
        if (activity is not null)
        {
            return ToTraceparent(activity);
        }

        if (DatadogCorrelation.TryGetDatadogCurrent(out var ids))
        {
            return $"00-{ids.TraceId}-{ids.SpanId}-01";
        }

        return ToTraceparent(Activity.Current);
    }

    /// <summary>Parses a producer traceparent/tracestate into an ActivityLink (async boundary: link, not parent).</summary>
    public static bool TryCreateLink(string? traceparent, string? tracestate, out ActivityLink link)
    {
        link = default;
        if (string.IsNullOrWhiteSpace(traceparent))
        {
            return false;
        }

        if (!ActivityContext.TryParse(traceparent, tracestate, isRemote: true, out var context))
        {
            return false;
        }

        link = new ActivityLink(context, new ActivityTagsCollection { ["link.kind"] = "producer" });
        return true;
    }
}
