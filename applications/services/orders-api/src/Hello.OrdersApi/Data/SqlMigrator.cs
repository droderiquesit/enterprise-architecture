using System.Reflection;
using Microsoft.Data.SqlClient;

namespace Hello.OrdersApi.Data;

/// <summary>Tracks whether startup migrations have completed (readiness depends on it).</summary>
public sealed class MigrationState
{
    private volatile bool _completed;
    private volatile string? _lastError;

    public bool Completed => _completed;

    public string? LastError => _lastError;

    public void MarkCompleted()
    {
        _completed = true;
        _lastError = null;
    }

    public void MarkFailed(string error) => _lastError = error;
}

/// <summary>Runs the embedded idempotent migration scripts in order (bounded retries with backoff).</summary>
public sealed partial class SqlMigrationService(
    OrdersSettings settings,
    IServiceProvider services,
    MigrationState state,
    ILogger<SqlMigrationService> logger) : BackgroundService
{
    private const int MaxAttempts = 10;

    public static IReadOnlyList<(string Name, string Sql)> LoadScripts()
    {
        var asm = typeof(SqlMigrationService).Assembly;
        return [.. asm.GetManifestResourceNames()
            .Where(n => n.EndsWith(".sql", StringComparison.Ordinal))
            .Order(StringComparer.Ordinal)
            .Select(n => (n, ReadResource(asm, n)))];
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (settings.StorageMode != "sql")
        {
            state.MarkCompleted();
            return;
        }

        var factory = services.GetRequiredService<SqlConnectionFactory>();
        for (var attempt = 1; attempt <= MaxAttempts && !stoppingToken.IsCancellationRequested; attempt++)
        {
            try
            {
                await using var connection = await factory.OpenAsync(stoppingToken).ConfigureAwait(false);
                foreach (var (name, sql) in LoadScripts())
                {
                    await using var cmd = new SqlCommand(sql, connection) { CommandTimeout = 60 };
                    await cmd.ExecuteNonQueryAsync(stoppingToken).ConfigureAwait(false);
                    LogApplied(logger, name);
                }

                state.MarkCompleted();
                return;
            }
            catch (Exception ex) when (ex is SqlException or InvalidOperationException or TimeoutException)
            {
                state.MarkFailed(ex.GetType().Name);
                LogFailed(logger, ex, attempt, MaxAttempts);
                var delay = TimeSpan.FromSeconds(Math.Min(30, Math.Pow(2, attempt)));
                await Task.Delay(delay + TimeSpan.FromMilliseconds(Random.Shared.Next(0, 500)), stoppingToken).ConfigureAwait(false);
            }
        }
    }

    private static string ReadResource(Assembly asm, string name)
    {
        using var stream = asm.GetManifestResourceStream(name) ?? throw new InvalidOperationException($"Missing resource {name}");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    [LoggerMessage(EventId = 1100, Level = LogLevel.Information, Message = "Applied SQL migration {migration}")]
    private static partial void LogApplied(ILogger logger, string migration);

    [LoggerMessage(EventId = 1101, Level = LogLevel.Warning, Message = "SQL migration attempt {attempt}/{max_attempts} failed")]
    private static partial void LogFailed(ILogger logger, Exception ex, int attempt, int max_attempts);
}
