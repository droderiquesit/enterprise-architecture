output "tags" {
  description = "Datadog tags of this signal source: key -> normalised value (canonical keys incl. aliases + static tags)."
  value       = local.tags
  precondition {
    condition     = !local.enforce || length(local.missing_required) == 0
    error_message = "Tag policy: required tag(s) without a value: ${join(", ", local.missing_required)}. Supply them in identity (or a policy default)."
  }
  precondition {
    condition     = length(local.renamed_unified) == 0
    error_message = "Tag policy: env, service and version cannot be renamed (Datadog unified service tagging); use aliases instead: ${join(", ", local.renamed_unified)}."
  }
  precondition {
    condition     = !local.enforce || length(local.invalid_values) == 0
    error_message = "Tag policy: value(s) outside allowed_values: ${join(", ", local.invalid_values)}."
  }
  precondition {
    condition     = local.normalize || alltrue([for v in values(local.tags) : !can(regex("[, ]", v))])
    error_message = "Tag policy with normalize = none: values must not contain commas or spaces (DD_TAGS / ddtags separators)."
  }
}

output "unified" {
  description = "Unified service tags {env, service, version} (DD_ENV / DD_SERVICE / DD_VERSION, tags.datadoghq.com/*)."
  value       = { for k in local.unified : k => lookup(local.tags, k, "") }
}

output "extra_tags" {
  description = "All tags except env/service/version (DD_TAGS next to DD_ENV/DD_SERVICE/DD_VERSION, RUM global context, k8s annotation)."
  value       = local.extra
}

output "dd_tags" {
  description = "Comma separated k:v list of all tags, sorted (Fluent Bit ddtags / FLB_DD_TAGS, DBM)."
  value       = join(",", local.dd_list)
}

output "dd_tags_list" {
  description = "Sorted k:v list of all tags (Agent `tags:`, DBM instance tags, Helm datadog.tags)."
  value       = local.dd_list
}

output "dd_tags_extra" {
  description = "Comma separated k:v list without env/service/version (DD_TAGS of tracers/SDKs; DD_ENV etc. carry the unified ones)."
  value       = join(",", local.dd_extra)
}

output "dd_tags_space" {
  description = "Space separated k:v list of all tags (Datadog Agent DD_TAGS environment variable)."
  value       = join(" ", local.dd_list)
}

output "otel_resource_attributes" {
  description = "OTel resource attributes (map): deployment.environment.name, service.name, service.version + every other policy key / alias / static tag."
  value       = local.otel
}

output "otel_resource_attributes_string" {
  description = "OTEL_RESOURCE_ATTRIBUTES value (sorted k=v, comma separated; ',' and '=' percent-encoded)."
  value       = local.otel_string
}

output "k8s_labels" {
  description = "Pod/workload labels: tags.datadoghq.com/{env,service,version} + label-safe extra tags (mapped by podLabelsAsTags)."
  value       = local.k8s_labels
}

output "k8s_annotations" {
  description = "Pod annotations: ad.datadoghq.com/tags = JSON of every extra tag (Datadog Agent tag autodiscovery; covers values that are not label-safe)."
  value       = local.k8s_annotations
}

output "pod_labels_as_tags" {
  description = "Policy-wide pod label -> Datadog tag mapping (Helm datadog.podLabelsAsTags / DD_KUBERNETES_POD_LABELS_AS_TAGS; Fluent Bit DaemonSet)."
  value       = local.pod_labels_as_tags
}

output "azure_tags" {
  description = "Azure resource tags carrying the same identity (first azure_tag_keys entry per key + static tags). The Datadog Azure integration imports Azure resource tags onto the resource's metrics."
  value       = local.azure_tags
}

output "azure_tag_key_map" {
  description = "Lowercase Azure tag key -> Datadog tag keys, for Azure platform logs that carry resource tags (Fluent Bit aggregator FLB_AZURE_TAG_MAP)."
  value       = local.azure_tag_key_map
}

output "fluent_bit_env" {
  description = "Fluent Bit tag env of the shipped configs: FLB_DD_TAGS (all tags) and FLB_DD_SERVICE."
  value = merge(
    { FLB_DD_TAGS = join(",", local.dd_list) },
    lookup(local.tags, "service", "") == "" ? {} : { FLB_DD_SERVICE = local.tags["service"] },
  )
}

output "rum_global_context" {
  description = "RUM SDK global context (datadogRum.setGlobalContextProperty): every extra tag. env/service/version go to datadogRum.init."
  value       = local.extra
}

output "missing_required" {
  description = "Required Datadog keys without a value (empty when the policy is satisfied)."
  value       = local.missing_required
}

output "required_keys" {
  description = "Datadog keys (primary + aliases) the policy requires on every signal."
  value       = sort(distinct(flatten([for k, s in local.pkeys : local.dd_keys[k] if try(s.required, false)])))
}

output "policy" {
  description = "The decoded policy in use (pass it on to nested modules)."
  value       = local.policy
}
