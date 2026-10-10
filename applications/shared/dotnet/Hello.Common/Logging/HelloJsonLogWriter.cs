using System.Buffers;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Hello.Common.Telemetry;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Hello.Common.Logging;

/// <summary>
/// Writes one log entry as a single-line JSON object in the Enterprise Hello log shape (ADR-0001 §9):
/// timestamp, level, message, logger, service, env, version, trace_id, span_id, dd.trace_id, dd.span_id,
/// dd.service, dd.env, dd.version, structured fields, and error.kind/error.message/error.stack.
/// </summary>
public sealed class HelloJsonLogWriter
{
    private const string OriginalFormatKey = "{OriginalFormat}";

    private static readonly HashSet<string> Reserved = new(StringComparer.Ordinal)
    {
        "timestamp", "level", "message", "logger", "service", "env", "version", "trace_id", "span_id",
        "dd.trace_id", "dd.span_id", "dd.service", "dd.env", "dd.version", "error.kind", "error.message",
        "error.stack", "event_id", "event_name",
    };

    // Scope keys that duplicate the correlation fields written explicitly (incl. the Datadog tracer's ILogger log
    // injection scope, DD_LOGS_INJECTION: dd_service/dd_env/dd_version/dd_trace_id/dd_span_id).
    private static readonly HashSet<string> SkippedScopeKeys = new(StringComparer.OrdinalIgnoreCase)
    {
        "TraceId", "SpanId", "ParentId", "TraceFlags", "TraceState", OriginalFormatKey,
        "dd_service", "dd_env", "dd_version", "dd_trace_id", "dd_span_id",
    };

    private static readonly JsonWriterOptions WriterOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Indented = false,
    };

    private readonly HelloServiceInfo _info;
    private readonly TimeProvider _timeProvider;

    public HelloJsonLogWriter(HelloServiceInfo info, TimeProvider? timeProvider = null)
    {
        _info = info ?? throw new ArgumentNullException(nameof(info));
        _timeProvider = timeProvider ?? TimeProvider.System;
    }

    public static string LevelName(LogLevel level) => level switch
    {
        LogLevel.Trace => "trace",
        LogLevel.Debug => "debug",
        LogLevel.Information => "info",
        LogLevel.Warning => "warning",
        LogLevel.Error => "error",
        LogLevel.Critical => "critical",
        _ => "none",
    };

    public string Format<TState>(in LogEntry<TState> entry, IExternalScopeProvider? scopeProvider)
    {
        var buffer = new ArrayBufferWriter<byte>(512);
        using (var json = new Utf8JsonWriter(buffer, WriterOptions))
        {
            WriteEntry(json, entry, scopeProvider);
        }

        return Encoding.UTF8.GetString(buffer.WrittenSpan);
    }

    public void Write<TState>(in LogEntry<TState> entry, IExternalScopeProvider? scopeProvider, TextWriter textWriter)
    {
        ArgumentNullException.ThrowIfNull(textWriter);
        var line = Format(entry, scopeProvider);
        textWriter.Write(line);
        textWriter.Write('\n');
    }

    private void WriteEntry<TState>(Utf8JsonWriter json, in LogEntry<TState> entry, IExternalScopeProvider? scopeProvider)
    {
        var written = new HashSet<string>(Reserved, StringComparer.Ordinal);
        var message = entry.Formatter is null ? entry.State?.ToString() : entry.Formatter(entry.State, entry.Exception);

        json.WriteStartObject();
        json.WriteString("timestamp", _timeProvider.GetUtcNow().UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture));
        json.WriteString("level", LevelName(entry.LogLevel));
        json.WriteString("message", Redactor.Redact(message));
        json.WriteString("logger", entry.Category);
        json.WriteString("service", _info.Service);
        json.WriteString("env", _info.Environment);
        json.WriteString("version", _info.Version);

        // Active Datadog span (TELEMETRY_SDK=datadog, CLR profiler attached) first, then Activity.Current; none ⇒ omitted.
        if (DatadogCorrelation.TryGetCurrent(out var ids))
        {
            json.WriteString("trace_id", ids.TraceId);
            json.WriteString("span_id", ids.SpanId);
            json.WriteString("dd.trace_id", ids.DatadogTraceId);
            json.WriteString("dd.span_id", ids.DatadogSpanId);
        }

        json.WriteString("dd.service", _info.Service);
        json.WriteString("dd.env", _info.Environment);
        json.WriteString("dd.version", _info.Version);

        if (entry.EventId.Id != 0)
        {
            json.WriteNumber("event_id", entry.EventId.Id);
        }

        if (!string.IsNullOrEmpty(entry.EventId.Name))
        {
            json.WriteString("event_name", entry.EventId.Name);
        }

        if (entry.Exception is { } ex)
        {
            json.WriteString("error.kind", ex.GetType().FullName);
            json.WriteString("error.message", Redactor.Redact(ex.Message));
            json.WriteString("error.stack", Redactor.Redact(ex.ToString()));
        }

        if (entry.State is IEnumerable<KeyValuePair<string, object?>> stateValues)
        {
            foreach (var kv in stateValues)
            {
                WriteField(json, written, kv.Key, kv.Value);
            }
        }

        scopeProvider?.ForEachScope(
            (scope, state) =>
            {
                if (scope is IEnumerable<KeyValuePair<string, object?>> scopeValues)
                {
                    foreach (var kv in scopeValues)
                    {
                        if (!SkippedScopeKeys.Contains(kv.Key))
                        {
                            WriteField(state.Json, state.Written, kv.Key, kv.Value);
                        }
                    }
                }
            },
            (Json: json, Written: written));

        json.WriteEndObject();
    }

    private static void WriteField(Utf8JsonWriter json, HashSet<string> written, string key, object? value)
    {
        if (string.IsNullOrEmpty(key) || key == OriginalFormatKey)
        {
            return;
        }

        var name = key.StartsWith('@') ? key[1..] : key;
        if (!written.Add(name))
        {
            name = "attr." + name;
            if (!written.Add(name))
            {
                return;
            }
        }

        if (Redactor.IsSensitiveName(name))
        {
            json.WriteString(name, Redactor.Mask);
            return;
        }

        switch (value)
        {
            case null:
                json.WriteNull(name);
                break;
            case bool b:
                json.WriteBoolean(name, b);
                break;
            case int i:
                json.WriteNumber(name, i);
                break;
            case long l:
                json.WriteNumber(name, l);
                break;
            case short s:
                json.WriteNumber(name, s);
                break;
            case uint ui:
                json.WriteNumber(name, ui);
                break;
            case ulong ul:
                json.WriteNumber(name, ul);
                break;
            case double d when double.IsFinite(d):
                json.WriteNumber(name, d);
                break;
            case float f when float.IsFinite(f):
                json.WriteNumber(name, f);
                break;
            case decimal m:
                json.WriteNumber(name, m);
                break;
            case DateTime dt:
                json.WriteString(name, dt.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture));
                break;
            case DateTimeOffset dto:
                json.WriteString(name, dto.UtcDateTime.ToString("O", CultureInfo.InvariantCulture));
                break;
            case TimeSpan ts:
                json.WriteNumber(name, ts.TotalMilliseconds);
                break;
            case Guid g:
                json.WriteString(name, g.ToString("D"));
                break;
            default:
                json.WriteString(name, Redactor.Redact(Convert.ToString(value, CultureInfo.InvariantCulture)));
                break;
        }
    }

    /// <summary>Convenience for tests and the file sink: formats without a scope provider.</summary>
    public string FormatMessage(LogLevel level, string category, string message, Exception? exception = null)
    {
        var entry = new LogEntry<string>(level, category, default, message, exception, static (s, _) => s);
        return Format(entry, null);
    }
}
