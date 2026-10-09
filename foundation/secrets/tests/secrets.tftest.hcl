# Plan-only tests of the rendered DSV desired state (no providers are involved).
variables {
  environment = {
    name            = "dev"
    location        = "swedencentral"
    subscription_id = "00000000-0000-0000-0000-000000000000"
    tenant_id       = "00000000-0000-0000-0000-000000000000"
    name_prefix     = "eh"
    owner           = "platform-team@example.com"
    team            = "platform-engineering"
    cost_center     = "lab-0001"
    expires_on      = "2026-12-31"
    tags            = {}
  }
  foundation_identity = {
    identities = {
      "hello-bff" = {
        id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-identity-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/eh-id-hello-bff-dev-sec"
        name    = "eh-id-hello-bff-dev-sec"
        secrets = ["fault-token", "datadog-api-key"]
      }
      "obs-collector" = {
        id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-identity-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/eh-id-obs-collector-dev-sec"
        name    = "eh-id-obs-collector-dev-sec"
        secrets = ["datadog-api-key", "fluentbit-shared-key", "eventhub-fluentbit-listen"]
      }
      "deploy-agent" = {
        id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-identity-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/eh-id-deploy-agent-dev-sec"
        name    = "eh-id-deploy-agent-dev-sec"
        secrets = ["datadog-api-key", "datadog-app-key"]
      }
      "aks-kubelet" = {
        id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-identity-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/eh-id-aks-kubelet-dev-sec"
        name    = "eh-id-aks-kubelet-dev-sec"
        secrets = []
      }
    }
    secrets = {
      tenant        = "example-lab"
      tld           = "com"
      base_url      = "https://example-lab.secretsvaultcloud.com/v1"
      base_path     = "eh/dev"
      auth_provider = "azure-eh"
      refs = {
        "fault-token"               = "dsv://eh/dev/fault-token#value"
        "datadog-api-key"           = "dsv://eh/dev/datadog-api-key#value"
        "datadog-app-key"           = "dsv://eh/dev/datadog-app-key#value"
        "fluentbit-shared-key"      = "dsv://eh/dev/fluentbit-shared-key#value"
        "eventhub-fluentbit-listen" = "dsv://eh/dev/eventhub-fluentbit-listen#value"
      }
    }
  }
}

run "desired_state" {
  command = plan

  assert {
    condition     = output.dsv_desired_state.auth_provider.type == "azure" && output.dsv_desired_state.auth_provider.tenant_id == var.environment.tenant_id && output.dsv_desired_state.auth_provider.name == "azure-eh"
    error_message = "Azure auth provider bound to the Entra tenant"
  }
  assert {
    condition     = length(output.dsv_desired_state.users) == 3 && !contains(keys(output.dsv_desired_state.users), "eh-dev-aks-kubelet")
    error_message = "one DSV user per identity that reads secrets"
  }
  assert {
    condition     = output.dsv_desired_state.users["eh-dev-hello-bff"].external_id == var.foundation_identity.identities["hello-bff"].id && output.dsv_desired_state.users["eh-dev-hello-bff"].provider == "azure-eh"
    error_message = "users map to the user-assigned identity resource id"
  }
  assert {
    condition     = output.dsv_desired_state.policy.path == "secrets:eh:dev"
    error_message = "single policy at the environment base path"
  }
  assert {
    condition     = jsonencode(one([for p in output.dsv_desired_state.policy.permissions : p if p.key == "read:hello-bff"]).resources) == jsonencode(["secrets:eh:dev:datadog-api-key", "secrets:eh:dev:fault-token"])
    error_message = "hello-bff reads exactly its two paths"
  }
  assert {
    condition     = alltrue([for p in output.dsv_desired_state.policy.permissions : startswith(p.key, "publish:") || startswith(p.key, "list:") || jsonencode(p.actions) == jsonencode(["read"])])
    error_message = "workload permissions are read-only"
  }
  assert {
    condition     = jsonencode(one([for p in output.dsv_desired_state.policy.permissions : p if p.key == "publish:deploy-agent"]).resources) == jsonencode(["secrets:eh:dev:eventhub-fluentbit-listen"])
    error_message = "the publisher may create/update only generated paths"
  }
  assert {
    condition     = jsonencode(one([for p in output.dsv_desired_state.policy.permissions : p if p.key == "list:deploy-agent"]).actions) == jsonencode(["list"])
    error_message = "the checker lists metadata, it does not read"
  }
  assert {
    condition     = alltrue([for p in output.dsv_desired_state.policy.permissions : startswith(p.description, "managed-by:foundation-secrets ")])
    error_message = "every managed permission carries the marker"
  }
  assert {
    condition     = output.dsv_desired_state.secrets["eventhub-fluentbit-listen"].source == "generated" && output.dsv_desired_state.secrets["eventhub-fluentbit-listen"].publisher == "obs-telemetry-transport" && jsonencode(output.dsv_desired_state.secrets["eventhub-fluentbit-listen"].readers) == jsonencode(["obs-collector"])
    error_message = "secret metadata from the catalogue"
  }
}

run "bad_identity_id_rejected" {
  command = plan
  variables {
    foundation_identity = {
      identities = { "x" = { id = "not-an-arm-id", name = "x", secrets = ["fault-token"] } }
      secrets = {
        tenant        = "example-lab", tld = "com", base_url = "https://example-lab.secretsvaultcloud.com/v1", base_path = "eh/dev",
        auth_provider = "azure-eh", refs = { "fault-token" = "dsv://eh/dev/fault-token#value" }
      }
    }
  }
  expect_failures = [terraform_data.desired_state]
}
