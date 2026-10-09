using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Logging.Console;

namespace Hello.Common.Logging;

/// <summary>Console formatter emitting the Enterprise Hello JSON log line (one object per line).</summary>
public sealed class HelloJsonConsoleFormatter : ConsoleFormatter
{
    public const string FormatterName = "hello-json";

    private readonly HelloJsonLogWriter _writer;

    public HelloJsonConsoleFormatter(HelloJsonLogWriter writer)
        : base(FormatterName)
    {
        _writer = writer;
    }

    public override void Write<TState>(in LogEntry<TState> logEntry, Microsoft.Extensions.Logging.IExternalScopeProvider? scopeProvider, TextWriter textWriter)
        => _writer.Write(logEntry, scopeProvider, textWriter);
}
