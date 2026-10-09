using Hello.Common.Faults;
using Hello.Common.Operational;
using Hello.Common.Web;
using Hello.InventoryApi;

var builder = WebApplication.CreateBuilder(args);

// Windows: runs as a Windows Service when started by the SCM (VM install); no-op elsewhere (Linux, containers, IIS/ANCM).
builder.Services.AddWindowsService(o => o.ServiceName = "hello-inventory-api");
builder.AddHelloServiceDefaults("hello-inventory-api");

builder.Services.AddSingleton<InMemoryInventoryStore>();
builder.Services.AddSingleton<IInventoryStore>(sp =>
{
    var mode = (sp.GetRequiredService<IConfiguration>()["STORAGE_MODE"] ?? "cosmos").Trim().ToLowerInvariant();
    IInventoryStore inner = mode switch
    {
        "memory" => sp.GetRequiredService<InMemoryInventoryStore>(),
        "cosmos" => ActivatorUtilities.CreateInstance<CosmosInventoryStore>(sp),
        _ => throw new InvalidOperationException($"Unsupported STORAGE_MODE '{mode}' (cosmos|memory)."),
    };
    return new FaultingInventoryStore(inner, sp.GetRequiredService<FaultState>());
});
builder.Services.AddSingleton<IReadinessCheck>(sp => new DelegateReadinessCheck("cosmos", ct => sp.GetRequiredService<IInventoryStore>().PingAsync(ct)));

var app = builder.Build();
app.UseHelloServiceDefaults();
app.MapHelloServiceEndpoints();
app.MapInventoryEndpoints();
app.Run();

/// <summary>Entry point marker for WebApplicationFactory.</summary>
public partial class Program;
