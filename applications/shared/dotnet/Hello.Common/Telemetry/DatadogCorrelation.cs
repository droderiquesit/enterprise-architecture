using System.Diagnostics;
using System.Globalization;
using System.Reflection;

namespace Hello.Common.Telemetry;

/// <summary>Log-correlation ids of the active span: 32/16 hex (W3C form) and the Datadog decimal low-64-bit form.</summary>
public readonly record struct CorrelationIds(string TraceId, string SpanId, string DatadogTraceId, string DatadogSpanId);

/// <summary>
/// Reads the active Datadog span from the automatic-instrumentation tracer (the <c>Datadog.Trace</c> assembly the CLR
/// profiler loads) without a compile-time reference to it: <c>Tracer.Instance.ActiveScope.Span</c> → <c>TraceId</c>
/// (low 64 bits), <c>SpanId</c>, and the span context's 128-bit <c>RawTraceId</c> when the tracer exposes it.
/// When no Datadog span is active the current <see cref="Activity"/> is used (OTel mode, or Activities that are Datadog spans
/// with DD_TRACE_OTEL_ENABLED=true). No span at all ⇒ no ids (the log fields are omitted).
/// </summary>
public static class DatadogCorrelation
{
    private const string TracerAssemblyName = "Datadog.Trace";
    private static readonly object Gate = new();
    private static Accessor? _accessor;
    private static long _nextScanTicks;

    /// <summary>True once the Datadog tracer assembly is loaded in the process.</summary>
    public static bool TracerAssemblyLoaded() => FindTracerAssembly() is not null;

    /// <summary>Correlation ids for the active span (Datadog first, then Activity.Current); false when none is active.</summary>
    public static bool TryGetCurrent(out CorrelationIds ids)
    {
        if (TryGetDatadog(out ids))
        {
            return true;
        }

        var activity = Activity.Current;
        if (activity is not null && activity.IdFormat == ActivityIdFormat.W3C)
        {
            ids = new CorrelationIds(
                activity.TraceId.ToHexString(),
                activity.SpanId.ToHexString(),
                TraceIdConverter.ToDatadogTraceId(activity.TraceId),
                TraceIdConverter.ToDatadogSpanId(activity.SpanId));
            return true;
        }

        ids = default;
        return false;
    }

    /// <summary>Test hook: bind to a Datadog.Trace-shaped API in <paramref name="assembly"/> (null = rescan the process).</summary>
    public static void UseAssembly(Assembly? assembly)
    {
        lock (Gate)
        {
            _accessor = assembly is null ? null : Accessor.Create(assembly);
            _nextScanTicks = assembly is null ? 0 : long.MaxValue;
        }
    }

    private static bool TryGetDatadog(out CorrelationIds ids)
    {
        ids = default;
        var accessor = GetAccessor();
        if (accessor is null)
        {
            return false;
        }

        try
        {
            return accessor.TryRead(out ids);
        }
        catch (Exception)
        {
            // Never let correlation break logging (tracer API drift is reported by missing fields, not exceptions).
            return false;
        }
    }

    private static Accessor? GetAccessor()
    {
        var accessor = Volatile.Read(ref _accessor);
        if (accessor is not null)
        {
            return accessor;
        }

        var now = Environment.TickCount64;
        if (now < Interlocked.Read(ref _nextScanTicks))
        {
            return null;
        }

        lock (Gate)
        {
            if (_accessor is not null)
            {
                return _accessor;
            }

            // The tracer loads before Main when the profiler is attached; rescan at most every 5 s otherwise.
            Interlocked.Exchange(ref _nextScanTicks, now + 5000);
            var assembly = FindTracerAssembly();
            if (assembly is not null)
            {
                _accessor = Accessor.Create(assembly);
            }

            return _accessor;
        }
    }

    private static Assembly? FindTracerAssembly()
    {
        foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies())
        {
            if (string.Equals(assembly.GetName().Name, TracerAssemblyName, StringComparison.Ordinal))
            {
                return assembly;
            }
        }

        return null;
    }

    private sealed class Accessor
    {
        private readonly PropertyInfo _instance;
        private readonly PropertyInfo _activeScope;
        private readonly PropertyInfo _span;
        private readonly PropertyInfo _traceId;
        private readonly PropertyInfo _spanId;
        private readonly PropertyInfo? _context;

        private Accessor(PropertyInfo instance, PropertyInfo activeScope, PropertyInfo span, PropertyInfo traceId, PropertyInfo spanId, PropertyInfo? context)
        {
            _instance = instance;
            _activeScope = activeScope;
            _span = span;
            _traceId = traceId;
            _spanId = spanId;
            _context = context;
        }

        public static Accessor? Create(Assembly assembly)
        {
            var tracer = assembly.GetType("Datadog.Trace.Tracer");
            var scope = assembly.GetType("Datadog.Trace.IScope");
            var span = assembly.GetType("Datadog.Trace.ISpan");
            var instance = tracer?.GetProperty("Instance", BindingFlags.Public | BindingFlags.Static);
            var activeScope = tracer?.GetProperty("ActiveScope", BindingFlags.Public | BindingFlags.Instance);
            var spanProp = scope?.GetProperty("Span");
            var traceId = span?.GetProperty("TraceId");
            var spanId = span?.GetProperty("SpanId");
            if (instance is null || activeScope is null || spanProp is null || traceId is null || spanId is null)
            {
                return null;
            }

            return new Accessor(instance, activeScope, spanProp, traceId, spanId, span!.GetProperty("Context"));
        }

        public bool TryRead(out CorrelationIds ids)
        {
            ids = default;
            var tracer = _instance.GetValue(null);
            var scope = tracer is null ? null : _activeScope.GetValue(tracer);
            var span = scope is null ? null : _span.GetValue(scope);
            if (span is null)
            {
                return false;
            }

            var low = Convert.ToUInt64(_traceId.GetValue(span), CultureInfo.InvariantCulture);
            var spanId = Convert.ToUInt64(_spanId.GetValue(span), CultureInfo.InvariantCulture);
            if (low == 0 || spanId == 0)
            {
                return false;
            }

            var traceHex = RawTraceId(span) ?? FromActivity(low) ?? low.ToString("x32", CultureInfo.InvariantCulture);
            ids = new CorrelationIds(
                traceHex,
                spanId.ToString("x16", CultureInfo.InvariantCulture),
                low.ToString(CultureInfo.InvariantCulture),
                spanId.ToString(CultureInfo.InvariantCulture));
            return true;
        }

        private string? RawTraceId(object span)
        {
            var context = _context?.GetValue(span);
            var raw = context?.GetType().GetProperty("RawTraceId", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)?.GetValue(context) as string;
            return raw is { Length: 32 } ? raw : null;
        }

        // 128-bit form from the current Activity when it is the same trace (DD_TRACE_OTEL_ENABLED keeps them aligned).
        private static string? FromActivity(ulong low)
        {
            var activity = Activity.Current;
            if (activity is null || activity.IdFormat != ActivityIdFormat.W3C)
            {
                return null;
            }

            var hex = activity.TraceId.ToHexString();
            return string.Equals(TraceIdConverter.LowBitsToDecimal(hex), low.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal) ? hex : null;
        }
    }
}
