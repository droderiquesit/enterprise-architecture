using Hello.Common;
using Hello.Common.Http;
using Hello.Common.Logging;
using Hello.Common.Secrets;
using Hello.Common.Telemetry;
using Hello.Durable;
using Hello.Durable.Services;
using Hello.Durable.Triggers;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Azure.Functions.Worker.OpenTelemetry;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;

var builder = FunctionsApplication.CreateBuilder(args);
builder.ConfigureFunctionsWebApplication();

// ADR-0001 §14: dsv:// app settings are resolved from Delinea DSV in the isolated worker before any service reads
// configuration. Settings the Functions *host* reads itself (AzureWebJobsStorage, ServiceBusConnection, ...) are
// identity-based and never dsv:// — the host cannot resolve them.
builder.Configuration.AddDsvSecrets();

// Note: the worker's default ObjectSerializer is kept on purpose. Replacing WorkerOptions.Serializer (e.g. snake_case)
// made orchestration inputs scheduled by DurableTaskClient deserialize as defaults inside the orchestrator (observed in
// the local func + Azurite smoke run), so durable payloads keep the SDK's default JSON shape.

var info = HelloServiceInfo.FromConfiguration(builder.Configuration, "hello-durable");
var services = builder.Services;
services.AddSingleton(info);
services.TryAddSingleton(TimeProvider.System);
services.AddSingleton(sp => DurableSettings.From(sp.GetRequiredService<IConfiguration>()));

// Worker logs flow to the Functions host (→ FunctionAppLogs → diagnostic settings → Event Hubs → Fluent Bit).
// No console provider here: the host already captures stdout, which would duplicate lines.
builder.Logging.SetMinimumLevel(LoggingExtensions.ParseLevel(builder.Configuration["LOG_LEVEL"]) ?? LogLevel.Information);
builder.Logging.AddFilter("Microsoft", LogLevel.Warning);
builder.Logging.AddFilter("System.Net.Http", LogLevel.Warning);
builder.Logging.AddFilter("Azure", LogLevel.Warning);

// OpenTelemetry in the worker: Functions worker invocation spans + Durable Task spans + outbound HTTP/SQL/Service Bus;
// traces and metrics via OTLP. The host's own OTel output is enabled by host.json "telemetryMode": "OpenTelemetry".
//
// Microsoft.Azure.Functions.Worker.OpenTelemetry's UseFunctionsWorkerDefaults() is OFF by default: in the local
// func 4.15.2 + Azurite smoke run (worker package 1.2.0) enabling it stopped worker ILogger output from being relayed
// to the host, i.e. application logs would disappear from FunctionAppLogs (the ADR-0001 §10 log path).
// Set FUNCTIONS_WORKER_OTEL_DEFAULTS=true to opt in (experiments only).
var otel = services.AddHelloOpenTelemetry(builder.Configuration, info, o =>
{
    o.AspNetCore = false;
    o.ConfigureTracing = t => t
        .AddSource("Microsoft.Azure.Functions.Worker")
        .AddSource("Microsoft.DurableTask")
        .AddSqlClientInstrumentation();
    o.ConfigureMetrics = m => m.AddSqlClientInstrumentation();
});
if (string.Equals(builder.Configuration["FUNCTIONS_WORKER_OTEL_DEFAULTS"], "true", StringComparison.OrdinalIgnoreCase))
{
    otel.UseFunctionsWorkerDefaults();
}

services.TryAddSingleton<HelloMetrics>();
services.TryAddSingleton<Hello.Common.Faults.FaultState>();
services.AddSingleton<ActivityFaults>();

// Outbound dependencies: per-attempt 3 s, total 8 s (inside the orchestrator's 10 s payment timer), 1 retry;
// POSTs are retried because reserve/release/payments are idempotent by order_id.
static void Resilience(HelloHttpClientOptions o)
{
    o.TotalTimeout = TimeSpan.FromSeconds(8);
    o.AttemptTimeout = TimeSpan.FromSeconds(3);
    o.MaxRetryAttempts = 1;
    o.RetryUnsafeMethods = true;
}

services.AddHelloHttpClient<IInventoryService, InventoryService>("hello-inventory-api", sp => sp.GetRequiredService<DurableSettings>().InventoryApiUrl, Resilience);
services.AddHelloHttpClient<IPaymentService, PaymentService>("hello-partner-sim", sp => sp.GetRequiredService<DurableSettings>().PartnerApiUrl, Resilience);
services.AddHelloHttpClient<IOrdersService, OrdersService>("hello-orders-api", sp => sp.GetRequiredService<DurableSettings>().OrdersApiUrl, Resilience);

services.AddSingleton<InMemoryFulfillmentStore>();
services.AddSingleton<IFulfillmentStore>(sp => sp.GetRequiredService<DurableSettings>().StorageMode switch
{
    "memory" => sp.GetRequiredService<InMemoryFulfillmentStore>(),
    "sql" => ActivatorUtilities.CreateInstance<SqlFulfillmentStore>(sp),
    var other => throw new InvalidOperationException($"Unsupported STORAGE_MODE '{other}' (sql|memory)."),
});
services.AddSingleton<IBatchItemPublisher, ServiceBusBatchItemPublisher>();
services.AddSingleton<OrderEventStarter>();

builder.Build().Run();
