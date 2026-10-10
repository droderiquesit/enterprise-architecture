// A Datadog.Trace-shaped API (same type/property names as the automatic-instrumentation tracer, which Hello.Common reads
// by reflection) so DatadogCorrelation can be tested without the CLR profiler.
#pragma warning disable CA1050, CA1716, CA1724, CA1822, IDE0130

namespace Datadog.Trace;

public interface ISpanContext
{
    ulong TraceId { get; }

    ulong SpanId { get; }
}

public interface ISpan
{
    ulong TraceId { get; }

    ulong SpanId { get; }

    ISpanContext Context { get; }
}

public interface IScope : IDisposable
{
    ISpan Span { get; }
}

public sealed class Tracer
{
    private static readonly AsyncLocal<IScope?> Active = new();

    public static Tracer Instance { get; } = new();

    public IScope? ActiveScope => Active.Value;

    public static IScope Activate(ulong traceIdLow, ulong spanId, string? rawTraceId)
    {
        var scope = new FakeScope(new FakeSpan(traceIdLow, spanId, new FakeContext(traceIdLow, spanId, rawTraceId)), Active.Value);
        Active.Value = scope;
        return scope;
    }

    private sealed class FakeContext(ulong traceId, ulong spanId, string? raw) : ISpanContext
    {
        public ulong TraceId { get; } = traceId;

        public ulong SpanId { get; } = spanId;

        internal string? RawTraceId { get; } = raw;
    }

    private sealed class FakeSpan(ulong traceId, ulong spanId, ISpanContext context) : ISpan
    {
        public ulong TraceId { get; } = traceId;

        public ulong SpanId { get; } = spanId;

        public ISpanContext Context { get; } = context;
    }

    private sealed class FakeScope(ISpan span, IScope? previous) : IScope
    {
        public ISpan Span { get; } = span;

        public void Dispose() => Active.Value = previous;
    }
}
