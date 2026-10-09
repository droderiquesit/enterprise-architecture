using System.Text.Json;
using Hello.Common;
using Hello.Common.Faults;
using Hello.Common.Idempotency;
using Hello.Common.Logging;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Time.Testing;

namespace Hello.Common.Tests;

public sealed class FaultStateTests
{
    [Fact]
    public void Fault_AutoExpires()
    {
        var time = new FakeTimeProvider(DateTimeOffset.UtcNow);
        var state = new FaultState(time);
        state.Activate(FaultTypes.Http500, 1.0, 0, 30);

        Assert.True(state.ShouldInject(FaultTypes.Http500, out _));
        Assert.Single(state.Active());

        time.Advance(TimeSpan.FromSeconds(31));
        Assert.False(state.ShouldInject(FaultTypes.Http500, out _));
        Assert.Empty(state.Active());
    }

    [Fact]
    public void Duration_IsCappedAt900Seconds()
    {
        var time = new FakeTimeProvider(DateTimeOffset.UtcNow);
        var fault = new FaultState(time).Activate(FaultTypes.Latency, 0.5, 100, 100_000);
        Assert.Equal(TimeSpan.FromSeconds(900), fault.ExpiresAt - fault.CreatedAt);
    }

    [Fact]
    public void RateZero_NeverFires()
    {
        var state = new FaultState(TimeProvider.System);
        state.Activate(FaultTypes.DbError, 0, 0, 60);
        for (var i = 0; i < 100; i++)
        {
            Assert.False(state.ShouldInject(FaultTypes.DbError, out _));
        }
    }

    [Theory]
    [InlineData("token-1", "token-1", true)]
    [InlineData("token-1", "token-2", false)]
    [InlineData("", "token-1", false)]
    [InlineData("token", "token-1", false)]
    public void TokenEquals_ConstantTimeComparison(string provided, string expected, bool result) =>
        Assert.Equal(result, FaultEndpoints.TokenEquals(provided, expected));
}

public sealed class IdempotencyKeyTests
{
    [Theory]
    [InlineData("abc-123", true)]
    [InlineData("", false)]
    [InlineData("has space", false)]
    public void Validates(string key, bool valid) => Assert.Equal(valid, IdempotencyKey.IsValid(key, out _));

    [Fact]
    public void Fingerprint_IsStable() =>
        Assert.Equal(IdempotencyKey.Fingerprint(new { a = 1 }), IdempotencyKey.Fingerprint(new { a = 1 }));
}

public sealed class RotatingFileSinkTests
{
    [Fact]
    public async Task WritesJsonLines_AndRotatesBySize()
    {
        var dir = Directory.CreateTempSubdirectory("hello-logs-");
        try
        {
            var path = Path.Combine(dir.FullName, "app.log");
            var writer = new HelloJsonLogWriter(new HelloServiceInfo("svc", "dev", "1", "c", "b", "r"));
            using (var provider = new RotatingFileLoggerProvider(writer, path, maxBytes: 2048, maxFiles: 2))
            {
                var logger = provider.CreateLogger("test");
                for (var i = 0; i < 100; i++)
                {
                    logger.LogInformation("line {i} password=secret", i);
                }

                await Task.Delay(200, TestContext.Current.CancellationToken);
            }

            Assert.True(File.Exists(path));
            Assert.True(File.Exists(path + ".1"));
            Assert.False(File.Exists(path + ".3"));
            foreach (var file in Directory.GetFiles(dir.FullName))
            {
                Assert.True(new FileInfo(file).Length <= 2048 + 512);
                foreach (var line in await File.ReadAllLinesAsync(file, TestContext.Current.CancellationToken))
                {
                    using var doc = JsonDocument.Parse(line);
                    Assert.Equal("svc", doc.RootElement.GetProperty("service").GetString());
                    Assert.DoesNotContain("secret", line, StringComparison.Ordinal);
                }
            }
        }
        finally
        {
            dir.Delete(recursive: true);
        }
    }
}
