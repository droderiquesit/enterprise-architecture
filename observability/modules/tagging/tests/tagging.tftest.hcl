# Pure function module: plan-only runs, no providers.
variables {
  identity = {
    env         = "Development"
    service     = "hello-orders-api"
    version     = "4.2.0+build.7"
    team        = "orders"
    owner       = "orders@example.com"
    application = "enterprise-hello"
    domain      = "orders"
    tier        = "critical"
    region      = "swedencentral"
  }
}

run "default_policy_all_formats" {
  command = plan

  assert {
    condition     = output.unified == { env = "dev", service = "hello-orders-api", version = "4.2.0_build.7" }
    error_message = "env value_map (Development -> dev) and Datadog normalisation ('+' -> '_') must apply to unified tags"
  }
  assert {
    condition     = output.tags["owner"] == "orders_example.com" && output.tags["managed_by"] == "terraform"
    error_message = "owner e-mail normalised like Datadog; managed_by from the policy default"
  }
  assert {
    condition     = output.dd_tags == "application:enterprise-hello,domain:orders,env:dev,managed_by:terraform,owner:orders_example.com,region:swedencentral,service:hello-orders-api,team:orders,tier:critical,version:4.2.0_build.7"
    error_message = "dd_tags must be the sorted k:v list"
  }
  assert {
    condition     = !strcontains(output.dd_tags_extra, "env:") && !strcontains(output.dd_tags_extra, "service:") && strcontains(output.dd_tags_extra, "team:orders")
    error_message = "dd_tags_extra excludes the unified tags"
  }
  assert {
    condition = alltrue([
      output.otel_resource_attributes["deployment.environment.name"] == "dev",
      output.otel_resource_attributes["deployment.environment"] == "dev",
      output.otel_resource_attributes["service.name"] == "hello-orders-api",
      output.otel_resource_attributes["service.version"] == "4.2.0_build.7",
      output.otel_resource_attributes["service.namespace"] == "enterprise-hello",
      output.otel_resource_attributes["team"] == "orders",
    ])
    error_message = "OTel resource attributes must carry the semantic-convention names + the extra keys"
  }
  assert {
    condition     = output.k8s_labels["tags.datadoghq.com/env"] == "dev" && output.k8s_labels["team"] == "orders" && output.k8s_labels["owner"] == "orders_example.com"
    error_message = "label-safe tags become labels (the normalised owner is label-safe)"
  }
  assert {
    condition     = jsondecode(output.k8s_annotations["ad.datadoghq.com/tags"])["owner"] == "orders_example.com"
    error_message = "every extra tag is in the ad.datadoghq.com/tags annotation"
  }
  assert {
    condition     = output.azure_tags["env"] == "dev" && output.azure_tags["owner"] == "orders@example.com" && output.azure_tags["service"] == "hello-orders-api"
    error_message = "Azure tags carry the mapped (pre-normalisation) value under the first azure_tag_keys entry"
  }
  assert {
    condition     = join(",", output.azure_tag_key_map["environment"]) == "env" && join(",", output.azure_tag_key_map["costcenter"]) == "cost_center"
    error_message = "Azure tag key map is lowercase Azure key -> Datadog keys"
  }
  assert {
    condition     = length(output.missing_required) == 0 && contains(output.required_keys, "team") && !contains(output.required_keys, "cost_center")
    error_message = "required keys from the policy"
  }
  assert {
    condition     = output.fluent_bit_env["FLB_DD_SERVICE"] == "hello-orders-api" && output.fluent_bit_env["FLB_DD_TAGS"] == output.dd_tags
    error_message = "Fluent Bit env"
  }
  assert {
    condition     = output.pod_labels_as_tags["team"] == "team" && !contains(keys(output.pod_labels_as_tags), "env")
    error_message = "podLabelsAsTags maps the non-unified keys"
  }
}

run "customer_policy_aliases_renames_static_tags" {
  command = plan
  variables {
    policy = {
      apiVersion = "observability/tag-policy/v1"
      kind       = "TagPolicy"
      keys = {
        env     = { required = true, aliases = ["environment"], value_map = { development = "dev" } }
        service = { required = true }
        version = { required = true, default = "n/a" }
        team    = { required = true, key = "owning_team", azure_tag_keys = ["Team"] }
      }
      static_tags  = { business_unit = "Retail Banking" }
      environments = { dev = { static_tags = { datacenter = "weu" } } }
    }
    extra_tags = { component = "orders" }
  }

  assert {
    condition     = output.tags["environment"] == "dev" && output.tags["env"] == "dev"
    error_message = "alias emits the value under the additional key"
  }
  assert {
    condition     = output.tags["owning_team"] == "orders" && !contains(keys(output.tags), "team")
    error_message = "key rename"
  }
  assert {
    condition     = output.tags["business_unit"] == "retail_banking" && output.tags["datacenter"] == "weu" && output.tags["component"] == "orders"
    error_message = "static (global + per environment) and extra tags, normalised"
  }
  assert {
    condition     = output.azure_tags["Team"] == "orders" && output.azure_tags["business_unit"] == "Retail Banking"
    error_message = "Azure tags use the policy's Azure tag names"
  }
  assert {
    condition     = output.otel_resource_attributes["environment"] == "dev" && output.otel_resource_attributes["owning_team"] == "orders"
    error_message = "aliases / renamed keys are OTel attributes too"
  }
}

run "missing_required_fails_plan" {
  command = plan
  variables {
    identity = { env = "dev", service = "svc" }
  }
  expect_failures = [output.tags]
}

run "missing_required_reported_when_not_enforced" {
  command = plan
  variables {
    identity         = { env = "dev", service = "svc" }
    enforce_required = false
  }
  assert {
    condition     = contains(output.missing_required, "team") && contains(output.missing_required, "region")
    error_message = "missing keys are reported"
  }
}

run "unified_keys_cannot_be_renamed" {
  command = plan
  variables {
    policy = {
      apiVersion = "observability/tag-policy/v1"
      kind       = "TagPolicy"
      keys       = { env = { key = "environment" }, service = {}, version = {} }
    }
    identity = { env = "dev", service = "svc", version = "1" }
  }
  expect_failures = [output.tags]
}
