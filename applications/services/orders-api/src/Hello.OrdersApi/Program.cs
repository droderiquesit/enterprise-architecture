using Hello.Common.Http;
using Hello.Common.Operational;
using Hello.Common.Web;
using Hello.OrdersApi;
using Hello.OrdersApi.Catalog;
using Hello.OrdersApi.Data;
using Hello.OrdersApi.Messaging;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;

var builder = WebApplication.CreateBuilder(args);
builder.AddHelloServiceDefaults("hello-orders-api", t =>
{
    t.ConfigureTracing = tracing => tracing.AddSqlClientInstrumentation();
    t.ConfigureMetrics = metrics => metrics.AddSqlClientInstrumentation();
});

var services = builder.Services;
services.AddSingleton(sp => OrdersSettings.From(sp.GetRequiredService<IConfiguration>()));
services.AddSingleton<MigrationState>();
services.AddSingleton<SqlConnectionFactory>();
services.AddSingleton<InMemoryOrderRepository>();
services.AddSingleton<IOrderRepository>(sp => sp.GetRequiredService<OrdersSettings>().StorageMode switch
{
    "memory" => sp.GetRequiredService<InMemoryOrderRepository>(),
    "sql" => ActivatorUtilities.CreateInstance<SqlOrderRepository>(sp),
    var other => throw new InvalidOperationException($"Unsupported STORAGE_MODE '{other}' (sql|memory)."),
});
services.AddSingleton<LogOrderEventPublisher>();
services.AddSingleton<IOrderEventPublisher>(sp => sp.GetRequiredService<OrdersSettings>().MessagingMode switch
{
    "log" => sp.GetRequiredService<LogOrderEventPublisher>(),
    "servicebus" => ActivatorUtilities.CreateInstance<ServiceBusOrderEventPublisher>(sp),
    var other => throw new InvalidOperationException($"Unsupported MESSAGING_MODE '{other}' (servicebus|log)."),
});
services.AddHelloHttpClient<ICatalogClient, CatalogClient>(
    "hello-catalog-api",
    sp => sp.GetRequiredService<OrdersSettings>().CatalogApiUrl is { } u ? new Uri(u.ToString().TrimEnd('/') + "/") : null);
services.AddScoped<OrderService>();
services.AddHostedService<SqlMigrationService>();
services.AddSingleton<IReadinessCheck>(sp => new DelegateReadinessCheck("sql", async ct =>
{
    var state = sp.GetRequiredService<MigrationState>();
    if (!state.Completed)
    {
        throw new InvalidOperationException($"migrations pending ({state.LastError ?? "starting"})");
    }

    await sp.GetRequiredService<IOrderRepository>().PingAsync(ct).ConfigureAwait(false);
}));

var app = builder.Build();
app.UseHelloServiceDefaults();
app.MapHelloServiceEndpoints();
app.MapOrderEndpoints();
app.Run();

/// <summary>Entry point marker for WebApplicationFactory.</summary>
public partial class Program;
