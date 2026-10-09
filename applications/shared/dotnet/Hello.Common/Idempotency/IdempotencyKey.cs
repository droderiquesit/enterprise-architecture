using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Hello.Common.Idempotency;

/// <summary>Idempotency-Key header helpers (validation + request fingerprinting to detect key reuse with a different body).</summary>
public static class IdempotencyKey
{
    public const string HeaderName = "Idempotency-Key";
    public const string ReplayedHeaderName = "Idempotent-Replayed";
    public const int MaxLength = 128;

    public static bool IsValid(string? key, out string? error)
    {
        error = null;
        if (string.IsNullOrEmpty(key))
        {
            error = $"{HeaderName} header is required.";
            return false;
        }

        if (key.Length > MaxLength)
        {
            error = $"{HeaderName} must be at most {MaxLength} characters.";
            return false;
        }

        foreach (var c in key)
        {
            if (c is < '!' or > '~')
            {
                error = $"{HeaderName} must contain printable ASCII characters only (no spaces).";
                return false;
            }
        }

        return true;
    }

    /// <summary>SHA-256 (hex, lowercase) of the canonical JSON of the request payload.</summary>
    public static string Fingerprint<T>(T payload, JsonSerializerOptions? options = null)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(payload, options);
        return Convert.ToHexStringLower(SHA256.HashData(bytes));
    }

    public static string Fingerprint(string canonical) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)));
}
