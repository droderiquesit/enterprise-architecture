using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Console;

namespace Hello.Common.Logging;

public static class LoggingExtensions
{
    /// <summary>
    /// Replaces default providers with the JSON console formatter (stdout) plus the optional LOG_FILE_PATH sink.
    /// LOG_LEVEL (trace|debug|information|warning|error) sets the minimum level; framework noise is capped at Warning.
    /// </summary>
    public static ILoggingBuilder AddHelloJsonLogging(this ILoggingBuilder logging, IConfiguration configuration, HelloServiceInfo info)
    {
        ArgumentNullException.ThrowIfNull(logging);
        ArgumentNullException.ThrowIfNull(configuration);
        var writer = new HelloJsonLogWriter(info);
        logging.Services.TryAddSingleton(writer);

        logging.ClearProviders();
        logging.AddConsole(o => o.FormatterName = HelloJsonConsoleFormatter.FormatterName);
        logging.Services.TryAddEnumerable(ServiceDescriptor.Singleton<ConsoleFormatter, HelloJsonConsoleFormatter>());

        var level = ParseLevel(configuration["LOG_LEVEL"]) ?? LogLevel.Information;
        logging.SetMinimumLevel(level);
        logging.AddFilter("Microsoft", LogLevel.Warning);
        logging.AddFilter("System", LogLevel.Warning);
        logging.AddFilter("Azure", LogLevel.Warning);
        logging.AddFilter("Microsoft.Hosting.Lifetime", LogLevel.Information);
        logging.AddFilter("Polly", LogLevel.Warning);

        var filePath = configuration["LOG_FILE_PATH"];
        if (!string.IsNullOrWhiteSpace(filePath))
        {
            var maxBytes = long.TryParse(configuration["LOG_FILE_MAX_BYTES"], out var b) ? b : 10L * 1024 * 1024;
            var maxFiles = int.TryParse(configuration["LOG_FILE_MAX_FILES"], out var f) ? f : 3;
            logging.Services.AddSingleton<ILoggerProvider>(_ => new RotatingFileLoggerProvider(writer, filePath, maxBytes, maxFiles));
        }

        return logging;
    }

    public static LogLevel? ParseLevel(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        "trace" or "verbose" => LogLevel.Trace,
        "debug" => LogLevel.Debug,
        "info" or "information" => LogLevel.Information,
        "warn" or "warning" => LogLevel.Warning,
        "error" => LogLevel.Error,
        "critical" or "fatal" => LogLevel.Critical,
        _ => null,
    };
}
