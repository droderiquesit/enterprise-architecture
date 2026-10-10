---
applyTo: "**/*.cs"
---
# C# (.NET 10)

- Use `Hello.Common` for logging, OpenTelemetry, DSV reference resolution and resilient `HttpClient`s
  (`IHttpClientFactory`; never `new HttpClient()` per call).
- Async all the way (no `.Result`/`.Wait()`), `CancellationToken` passed through, timeouts on outbound calls.
- Parameterised SQL only; EF/Dapper queries must not concatenate input.
- Structured logging with message templates; never log secrets or tokens.
- New behaviour needs xUnit tests.
