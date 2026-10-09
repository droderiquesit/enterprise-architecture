using Azure.Core;
using Azure.Identity;
using Microsoft.Extensions.Configuration;

namespace Hello.Common.Azure;

/// <summary>
/// Picks the narrowest credential for the hosting platform:
/// AKS workload identity (AZURE_FEDERATED_TOKEN_FILE) → WorkloadIdentityCredential;
/// AZURE_CLIENT_ID (user-assigned managed identity on App Service/Functions/ACA/VM) → ManagedIdentityCredential;
/// otherwise DefaultAzureCredential (developer machine).
/// </summary>
public static class AzureCredentialFactory
{
    public static TokenCredential Create(IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        var clientId = configuration["AZURE_CLIENT_ID"];
        var federatedTokenFile = configuration["AZURE_FEDERATED_TOKEN_FILE"];

        if (!string.IsNullOrWhiteSpace(federatedTokenFile) && !string.IsNullOrWhiteSpace(clientId))
        {
            return new WorkloadIdentityCredential(new WorkloadIdentityCredentialOptions
            {
                ClientId = clientId,
                TokenFilePath = federatedTokenFile,
                TenantId = configuration["AZURE_TENANT_ID"],
            });
        }

        if (!string.IsNullOrWhiteSpace(clientId))
        {
            return new ManagedIdentityCredential(ManagedIdentityId.FromUserAssignedClientId(clientId));
        }

        return new DefaultAzureCredential();
    }
}
