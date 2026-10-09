using System.Diagnostics;
using System.Text.Json;
using Hello.Common;
using Hello.Common.Logging;
using Hello.Common.Telemetry;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Time.Testing;

namespace Hello.Common.Tests;

public sealed class JsonLogFormatTests
{
    private const string KnownTraceId = "4bf92f3577b34da6a3ce929d0e0e4736";
    private const string KnownSpanId = "00f067aa0ba902b7";

    private static readonly HelloServiceInfo Info = new("hello-test", "dev", "1.2.3", "abc123", "2026-10-09T00:00:00Z", ".NET");

    [Fact]
    public void DatadogTraceId_IsDecimalOfLow64Bits()
    {
        var traceId = ActivityTraceId.CreateFromString(KnownTraceId);
        var spanId = ActivitySpanId.CreateFromString(KnownSpanId);

        Assert.Equal("11803532876627986230", TraceIdConverter.ToDatadogTraceId(traceId));
        Assert.Equal("67667974448284343", TraceIdConverter.ToDatadogSpanId(spanId));
    }

    [Fact]
    public void LogLine_HasSpecShape_WithCorrelationFields()
    {
        var time = new FakeTimeProvider(new DateTimeOffset(2026, 10, 9, 12, 0, 0, 123, TimeSpan.Zero));
        var writer = new HelloJsonLogWriter(Info, time);

        using var activity = new Activity("test");
        activity.SetParentId(ActivityTraceId.CreateFromString(KnownTraceId), ActivitySpanId.CreateFromString(KnownSpanId), ActivityTraceFlags.Recorded);
        activity.Start();

        var state = new List<KeyValuePair<string, object?>>
        {
            new("order_count", 3),
            new("sku", "SKU-0001"),
            new("{OriginalFormat}", "Created {order_count} for {sku}"),
        };
        var entry = new LogEntry<IReadOnlyList<KeyValuePair<string, object?>>>(
            LogLevel.Information, "Hello.Orders", new EventId(42, "OrderCreated"), state, null, (_, _) => "Created 3 for SKU-0001");

        var line = writer.Format(entry, null);
        Assert.DoesNotContain('\n', line);
        using var doc = JsonDocument.Parse(line);
        var root = doc.RootElement;

        Assert.Equal("2026-10-09T12:00:00.123Z", root.GetProperty("timestamp").GetString());
        Assert.Equal("info", root.GetProperty("level").GetString());
        Assert.Equal("Created 3 for SKU-0001", root.GetProperty("message").GetString());
        Assert.Equal("Hello.Orders", root.GetProperty("logger").GetString());
        Assert.Equal("hello-test", root.GetProperty("service").GetString());
        Assert.Equal("dev", root.GetProperty("env").GetString());
        Assert.Equal("1.2.3", root.GetProperty("version").GetString());
        Assert.Equal(KnownTraceId, root.GetProperty("trace_id").GetString());
        Assert.Equal(32, root.GetProperty("trace_id").GetString()!.Length);
        var spanHex = root.GetProperty("span_id").GetString()!;
        Assert.Equal(16, spanHex.Length);
        Assert.Equal("11803532876627986230", root.GetProperty("dd.trace_id").GetString());
        Assert.Equal(TraceIdConverter.LowBitsToDecimal(spanHex), root.GetProperty("dd.span_id").GetString());
        Assert.Equal("hello-test", root.GetProperty("dd.service").GetString());
        Assert.Equal("dev", root.GetProperty("dd.env").GetString());
        Assert.Equal("1.2.3", root.GetProperty("dd.version").GetString());
        Assert.Equal(3, root.GetProperty("order_count").GetInt32());
        Assert.Equal("SKU-0001", root.GetProperty("sku").GetString());
        Assert.False(root.TryGetProperty("{OriginalFormat}", out _));
    }

    [Fact]
    public void LogLine_WithoutActivity_OmitsTraceFields()
    {
        Activity.Current = null;
        var line = new HelloJsonLogWriter(Info).FormatMessage(LogLevel.Warning, "cat", "hello");
        using var doc = JsonDocument.Parse(line);
        Assert.False(doc.RootElement.TryGetProperty("trace_id", out _));
        Assert.Equal("warning", doc.RootElement.GetProperty("level").GetString());
    }

    [Fact]
    public void Exception_IsWrittenWithErrorFields_AndRedacted()
    {
        Exception ex;
        try
        {
            throw new InvalidOperationException("connect failed Password=hunter2;Server=x");
        }
        catch (InvalidOperationException e)
        {
            ex = e;
        }

        var line = new HelloJsonLogWriter(Info).FormatMessage(LogLevel.Error, "cat", "boom token=abc.def", ex);
        using var doc = JsonDocument.Parse(line);
        var root = doc.RootElement;
        Assert.Equal("System.InvalidOperationException", root.GetProperty("error.kind").GetString());
        Assert.Equal("connect failed Password=***;Server=x", root.GetProperty("error.message").GetString());
        Assert.Contains("JsonLogFormatTests", root.GetProperty("error.stack").GetString(), StringComparison.Ordinal);
        Assert.DoesNotContain("hunter2", line, StringComparison.Ordinal);
        Assert.Equal("boom token=***", root.GetProperty("message").GetString());
    }

    [Fact]
    public void SensitiveStructuredFields_AreMasked()
    {
        var state = new List<KeyValuePair<string, object?>> { new("client_secret", "s3cr3t"), new("sku", "SKU-1") };
        var entry = new LogEntry<IReadOnlyList<KeyValuePair<string, object?>>>(LogLevel.Information, "c", default, state, null, (_, _) => "m");
        var line = new HelloJsonLogWriter(Info).Format(entry, null);
        Assert.DoesNotContain("s3cr3t", line, StringComparison.Ordinal);
        Assert.Contains("\"client_secret\":\"***\"", line, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("Server=tcp:x;Password=abc;", "Server=tcp:x;Password=***;")]
    [InlineData("Authorization: Bearer eyJhbGciOi.xyz", "Authorization: Bearer ***")]
    [InlineData("{\"api_key\": \"k-123\"}", "{\"api_key\": \"***\"}")]
    [InlineData("https://acct.blob.core.windows.net/c?sv=1&sig=abcdef", "https://acct.blob.core.windows.net/c?sv=1&sig=***")]
    [InlineData("AccountKey=Zm9vYmFy==;", "AccountKey=***;")]
    [InlineData("no secrets here", "no secrets here")]
    public void Redactor_MasksSecrets(string input, string expected) => Assert.Equal(expected, Redactor.Redact(input));

    [Fact]
    public void ScopeValues_AreIncluded_WithoutDuplicatingCorrelation()
    {
        var scopes = new LoggerExternalScopeProvider();
        using var scope = scopes.Push(new Dictionary<string, object?> { ["RequestPath"] = "/orders", ["TraceId"] = "dup" });
        var entry = new LogEntry<string>(LogLevel.Information, "c", default, "m", null, (s, _) => s);
        var line = new HelloJsonLogWriter(Info).Format(entry, scopes);
        using var doc = JsonDocument.Parse(line);
        Assert.Equal("/orders", doc.RootElement.GetProperty("RequestPath").GetString());
        Assert.False(doc.RootElement.TryGetProperty("TraceId", out _));
    }
}
