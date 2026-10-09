using Azure.Core;
using Hello.Common.Azure;
using Microsoft.Data.SqlClient;

namespace Hello.OrdersApi.Data;

/// <summary>
/// Opens pooled SqlConnections. Authentication options:
/// (a) connection string with Authentication=Active Directory Managed Identity|Default (driver-provided, needs
///     Microsoft.Data.SqlClient.Extensions.Azure, referenced) — App Service/Functions/ACA/VM;
/// (b) SQL_USE_AZURE_CREDENTIAL=true and no Authentication keyword — token from <see cref="AzureCredentialFactory"/>
///     (supports AKS workload identity);
/// (c) SQL auth (local docker only).
/// </summary>
public sealed class SqlConnectionFactory
{
    private static readonly string[] Scopes = ["https://database.windows.net/.default"];
    private readonly string _connectionString;
    private readonly TokenCredential? _credential;

    public SqlConnectionFactory(OrdersSettings settings, IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (string.IsNullOrWhiteSpace(settings.SqlConnectionString))
        {
            throw new InvalidOperationException("SQL_CONNECTION_STRING is required when STORAGE_MODE=sql.");
        }

        var builder = new SqlConnectionStringBuilder(settings.SqlConnectionString)
        {
            ApplicationName = "hello-orders-api",
            ConnectTimeout = 15,
            CommandTimeout = 10,
        };
        if (builder.MaxPoolSize > 100)
        {
            builder.MaxPoolSize = 100;
        }

        _connectionString = builder.ConnectionString;
        if (settings.SqlUseAzureCredential && builder.Authentication == SqlAuthenticationMethod.NotSpecified)
        {
            _credential = AzureCredentialFactory.Create(configuration);
        }
    }

    public async Task<SqlConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connection = new SqlConnection(_connectionString);
        if (_credential is not null)
        {
            var credential = _credential;
            connection.AccessTokenCallback = async (_, ct) =>
            {
                var token = await credential.GetTokenAsync(new TokenRequestContext(Scopes), ct).ConfigureAwait(false);
                return new SqlAuthenticationToken(token.Token, token.ExpiresOn);
            };
        }

        try
        {
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }
}
