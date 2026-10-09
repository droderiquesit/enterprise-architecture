mock_provider "datadog" {}

run "renders_v3_entity" {
  command = plan
  variables {
    services = {
      api = {
        team       = "shop", owner = "shop@example.com", env = "prod", runbook_url = "https://rb.example.com/api"
        depends_on = ["datastore:shop-sql"], repository = "https://example.com/api.git"
        contacts   = [{ type = "email", contact = "shop@example.com" }]
      }
    }
    systems = { shop = { owner = "shop", components = ["service:api"] } }
  }
  assert {
    condition     = yamldecode(output.entities_yaml["api"]).apiVersion == "v3" && yamldecode(output.entities_yaml["api"]).kind == "service"
    error_message = "v3 service entity expected"
  }
  assert {
    condition     = yamldecode(output.entities_yaml["api"]).spec.dependsOn == ["datastore:shop-sql"]
    error_message = "dependsOn expected"
  }
  assert {
    condition     = length([for l in yamldecode(output.entities_yaml["api"]).metadata.links : l if l.type == "runbook"]) == 1
    error_message = "runbook link expected"
  }
  assert {
    condition     = length(datadog_software_catalog.system) == 1
    error_message = "system entity expected"
  }
}
