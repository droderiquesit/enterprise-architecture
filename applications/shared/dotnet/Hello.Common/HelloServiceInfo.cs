using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.Extensions.Configuration;

namespace Hello.Common;

/// <summary>
/// Unified service identity (Datadog unified service tagging + OTel resource) resolved from environment configuration.
/// Precedence: OTEL_SERVICE_NAME &gt; DD_SERVICE &gt; default; DD_ENV; DD_VERSION; GIT_COMMIT; BUILD_TIME.
/// </summary>
public sealed record HelloServiceInfo(
    string Service,
    string Environment,
    string Version,
    string Commit,
    string BuildTime,
    string Runtime)
{
    public const string ServiceNamespace = "enterprise-hello";

    public static HelloServiceInfo FromConfiguration(IConfiguration configuration, string defaultServiceName)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        var assemblyVersion = Assembly.GetEntryAssembly()?
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        // Strip SourceLink "+<sha>" suffix: the commit is reported separately.
        if (assemblyVersion is not null && assemblyVersion.Contains('+', StringComparison.Ordinal))
        {
            assemblyVersion = assemblyVersion[..assemblyVersion.IndexOf('+', StringComparison.Ordinal)];
        }

        return new HelloServiceInfo(
            Service: First(configuration["OTEL_SERVICE_NAME"], configuration["DD_SERVICE"], defaultServiceName),
            Environment: First(configuration["DD_ENV"], "local"),
            Version: First(configuration["DD_VERSION"], assemblyVersion, "0.0.0-local"),
            Commit: First(configuration["GIT_COMMIT"], configuration["DD_GIT_COMMIT_SHA"], "unknown"),
            BuildTime: First(configuration["BUILD_TIME"], "unknown"),
            Runtime: RuntimeInformation.FrameworkDescription);
    }

    private static string First(params string?[] values)
    {
        foreach (var value in values)
        {
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value.Trim();
            }
        }

        return string.Empty;
    }
}
