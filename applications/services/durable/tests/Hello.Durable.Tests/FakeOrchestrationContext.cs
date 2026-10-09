using Microsoft.DurableTask;
using Microsoft.DurableTask.Entities;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Hello.Durable.Tests;

/// <summary>
/// Hand-written TaskOrchestrationContext for unit tests: activities resolve to registered handlers; the activity
/// RetryPolicy is honoured (attempt counting, no real delay); timers complete immediately or never (per test).
/// </summary>
public sealed class FakeOrchestrationContext(object? input, string instanceId = "test-instance") : TaskOrchestrationContext
{
    private readonly Dictionary<string, Func<object?, int, Task<object?>>> _handlers = new(StringComparer.Ordinal);
    private int _guidCounter;

    public List<(string Name, object? Input)> Calls { get; } = [];

    public Dictionary<string, int> Attempts { get; } = new(StringComparer.Ordinal);

    public List<object?> CustomStatuses { get; } = [];

    /// <summary>When true, durable timers fire immediately; otherwise they never fire.</summary>
    public bool TimersFireImmediately { get; set; }

    public DateTime Now { get; set; } = new(2026, 10, 9, 12, 0, 0, DateTimeKind.Utc);

    public override TaskName Name => new("Test");

    public override string InstanceId { get; } = instanceId;

    public override ParentOrchestrationInstance? Parent => null;

    public override DateTime CurrentUtcDateTime => Now;

    public override bool IsReplaying => false;

    protected override ILoggerFactory LoggerFactory => NullLoggerFactory.Instance;

    /// <summary>Register an activity; the handler receives (input, attemptNumber starting at 1).</summary>
    public FakeOrchestrationContext On(string activity, Func<object?, int, Task<object?>> handler)
    {
        _handlers[activity] = handler;
        return this;
    }

    public FakeOrchestrationContext On(string activity, Func<object?, object?> handler) =>
        On(activity, (i, _) => Task.FromResult(handler(i)));

    public int CallCount(string activity) => Calls.Count(c => c.Name == activity);

    public override T GetInput<T>() => (T)input!;

    public override async Task<TResult> CallActivityAsync<TResult>(TaskName name, object? input = null, TaskOptions? options = null)
    {
        var maxAttempts = options?.Retry?.Policy?.MaxNumberOfAttempts ?? 1;
        for (var attempt = 1; ; attempt++)
        {
            Calls.Add((name.Name, input));
            Attempts[name.Name] = Attempts.GetValueOrDefault(name.Name) + 1;
            if (!_handlers.TryGetValue(name.Name, out var handler))
            {
                return default!;
            }

            try
            {
                var result = await handler(input, attempt);
                return result is null ? default! : (TResult)result;
            }
            catch (Exception ex) when (ex is not TaskFailedException)
            {
                if (attempt >= maxAttempts)
                {
                    throw new TaskFailedException(name.Name, attempt, TaskFailureDetails.FromException(ex));
                }
            }
        }
    }

    public override Task CreateTimer(DateTime fireAt, CancellationToken cancellationToken) =>
        TimersFireImmediately ? Task.CompletedTask : Task.Delay(Timeout.Infinite, cancellationToken).ContinueWith(_ => { }, TaskScheduler.Default);

    public override Task<T> WaitForExternalEvent<T>(string eventName, CancellationToken cancellationToken = default) =>
        throw new NotSupportedException();

    public override void SendEvent(string instanceId, string eventName, object payload) => throw new NotSupportedException();

    public override void SetCustomStatus(object? customStatus) => CustomStatuses.Add(customStatus);

    public override Task<TResult> CallSubOrchestratorAsync<TResult>(TaskName orchestratorName, object? input = null, TaskOptions? options = null) =>
        throw new NotSupportedException();

    public override void ContinueAsNew(object? newInput = null, bool preserveUnprocessedEvents = true) => throw new NotSupportedException();

    public override Guid NewGuid() => new(0, 0, 0, BitConverter.GetBytes((long)++_guidCounter));

    public override TaskOrchestrationEntityFeature Entities => throw new NotSupportedException();
}
