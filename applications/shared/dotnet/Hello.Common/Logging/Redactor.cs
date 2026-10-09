using System.Text.RegularExpressions;

namespace Hello.Common.Logging;

/// <summary>
/// Redacts secrets from log text: key=value / key: value pairs whose key looks like a credential
/// (password, secret, token, *key, ...) and bearer tokens. Structured fields with sensitive names are
/// replaced entirely.
/// </summary>
public static partial class Redactor
{
    public const string Mask = "***";

    public static string Redact(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return value ?? string.Empty;
        }

        try
        {
            var result = KeyValuePattern().Replace(value, m => m.Groups["name"].Value + m.Groups["sep"].Value + Mask);
            result = BearerPattern().Replace(result, "Bearer " + Mask);
            return result;
        }
        catch (RegexMatchTimeoutException)
        {
            return "[redaction-timeout]";
        }
    }

    /// <summary>True when a structured field name itself denotes a secret.</summary>
    public static bool IsSensitiveName(string name) =>
        !string.IsNullOrEmpty(name) && SensitiveNamePattern().IsMatch(name);

    [GeneratedRegex(
        @"(?<name>[A-Za-z0-9_.\-]*(?:password|passwd|pwd|secret|token|key|signature|sig))(?<sep>[""']?\s*[=:]\s*[""']?)(?<value>[^\s;,&""'}]+)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant,
        matchTimeoutMilliseconds: 200)]
    private static partial Regex KeyValuePattern();

    [GeneratedRegex(
        @"\bbearer\s+[A-Za-z0-9\-._~+/]+=*",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant,
        matchTimeoutMilliseconds: 200)]
    private static partial Regex BearerPattern();

    [GeneratedRegex(
        @"(password|passwd|pwd|secret|token|apikey|api_key|api-key|accountkey|account_key|sharedaccesskey|connectionstring|connection_string|authorization|credential)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant,
        matchTimeoutMilliseconds: 200)]
    private static partial Regex SensitiveNamePattern();
}
