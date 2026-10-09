using System.Text;
using System.Threading.Channels;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Hello.Common.Logging;

/// <summary>
/// Optional sink that appends the same JSON log lines to LOG_FILE_PATH for Fluent Bit sidecar/agent tailing.
/// Size-based rotation (default 10 MB x 3 files: path, path.1, path.2, path.3 is dropped). Writes are queued on a
/// bounded channel and performed by one background task; when the queue is full new lines are dropped (never block
/// request threads) and a counter is kept.
/// </summary>
[ProviderAlias("HelloFile")]
public sealed class RotatingFileLoggerProvider : ILoggerProvider, ISupportExternalScope
{
    private readonly string _path;
    private readonly long _maxBytes;
    private readonly int _maxFiles;
    private readonly HelloJsonLogWriter _writer;
    private readonly Channel<string> _queue;
    private readonly Task _pump;
    private IExternalScopeProvider _scopeProvider = new LoggerExternalScopeProvider();
    private long _dropped;

    public RotatingFileLoggerProvider(HelloJsonLogWriter writer, string path, long maxBytes = 10 * 1024 * 1024, int maxFiles = 3, int queueCapacity = 10_000)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        _writer = writer ?? throw new ArgumentNullException(nameof(writer));
        _path = Path.GetFullPath(path);
        _maxBytes = Math.Max(1024, maxBytes);
        _maxFiles = Math.Max(1, maxFiles);
        var dir = Path.GetDirectoryName(_path);
        if (!string.IsNullOrEmpty(dir))
        {
            Directory.CreateDirectory(dir);
        }

        _queue = Channel.CreateBounded<string>(new BoundedChannelOptions(queueCapacity)
        {
            FullMode = BoundedChannelFullMode.DropWrite,
            SingleReader = true,
            SingleWriter = false,
        });
        _pump = Task.Run(PumpAsync);
    }

    public long DroppedLines => Interlocked.Read(ref _dropped);

    public ILogger CreateLogger(string categoryName) => new FileLogger(this, categoryName);

    public void SetScopeProvider(IExternalScopeProvider scopeProvider) => _scopeProvider = scopeProvider;

    public void Dispose()
    {
        _queue.Writer.TryComplete();
        try
        {
            _pump.Wait(TimeSpan.FromSeconds(2));
        }
        catch (AggregateException)
        {
            // Best effort flush on shutdown.
        }
    }

    internal void Enqueue(string line)
    {
        if (!_queue.Writer.TryWrite(line))
        {
            Interlocked.Increment(ref _dropped);
        }
    }

    private async Task PumpAsync()
    {
        FileStream? stream = null;
        try
        {
            stream = Open();
            var reader = _queue.Reader;
            while (await reader.WaitToReadAsync().ConfigureAwait(false))
            {
                while (reader.TryRead(out var line))
                {
                    var bytes = Encoding.UTF8.GetBytes(line + "\n");
                    if (stream.Length + bytes.Length > _maxBytes && stream.Length > 0)
                    {
                        await stream.DisposeAsync().ConfigureAwait(false);
                        Rotate();
                        stream = Open();
                    }

                    await stream.WriteAsync(bytes).ConfigureAwait(false);
                }

                await stream.FlushAsync().ConfigureAwait(false);
            }
        }
        catch (IOException)
        {
            // The file sink is optional; stdout logging continues. Avoid recursive logging here.
        }
        catch (UnauthorizedAccessException)
        {
        }
        finally
        {
            if (stream is not null)
            {
                await stream.DisposeAsync().ConfigureAwait(false);
            }
        }
    }

    private FileStream Open() =>
        new(_path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.Asynchronous);

    private void Rotate()
    {
        // path.(n-1) -> path.n ... path -> path.1 ; the oldest file beyond _maxFiles is deleted.
        var oldest = $"{_path}.{_maxFiles}";
        if (File.Exists(oldest))
        {
            File.Delete(oldest);
        }

        for (var i = _maxFiles - 1; i >= 1; i--)
        {
            var src = $"{_path}.{i}";
            if (File.Exists(src))
            {
                File.Move(src, $"{_path}.{i + 1}", overwrite: true);
            }
        }

        if (File.Exists(_path))
        {
            File.Move(_path, $"{_path}.1", overwrite: true);
        }
    }

    private sealed class FileLogger(RotatingFileLoggerProvider provider, string category) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state)
            where TState : notnull => provider._scopeProvider.Push(state);

        public bool IsEnabled(LogLevel logLevel) => logLevel != LogLevel.None;

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            if (!IsEnabled(logLevel))
            {
                return;
            }

            var entry = new LogEntry<TState>(logLevel, category, eventId, state, exception, formatter);
            provider.Enqueue(provider._writer.Format(entry, provider._scopeProvider));
        }
    }
}
