# Tag rendering: ONE pure function for every collection path of the package (no providers, no resources).
# Input: the tag policy (config/tag-policy.yaml by default) + raw identity values of one signal source (a service,
# a host, a cluster, a database, the collectors). Output: the same tag set in every format a path needs:
#   Datadog tags (map / "k:v,k:v" / space separated), unified service tags, OTel resource attributes, Kubernetes
#   labels + ad.datadoghq.com/tags annotation + podLabelsAsTags mapping, Azure resource tags, Azure tag key ->
#   Datadog key map (platform logs), Fluent Bit env, RUM global context.
# Semantics are mirrored 1:1 by tools/tags/tag_policy.py (parity test: tests/tags/test_parity.py).
locals {
  # (tuple + index: a conditional would require both policies to have the same object type)
  policy    = [for p in [var.policy, yamldecode(file("${path.module}/../../config/tag-policy.yaml"))] : p if p != null][0]
  pkeys     = local.policy.keys
  normalize = try(local.policy.normalize, "datadog") == "datadog"
  enforce   = var.enforce_required != null ? var.enforce_required : try(local.policy.enforce_required, true)
  unified   = ["env", "service", "version"]

  # raw value -> policy default -> value_map (case-insensitive) -> Datadog normalisation
  raw = { for k, s in local.pkeys : k => (
    try(trimspace(var.identity[k]), "") != "" ? trimspace(var.identity[k]) : try(tostring(s.default), "")
  ) }
  mapped = { for k, s in local.pkeys : k => try(tostring(lookup(s.value_map, lower(local.raw[k]), local.raw[k])), local.raw[k]) }
  value = { for k, v in local.mapped : k => (
    local.normalize ? trim(replace(replace(lower(v), "/[^\\p{L}\\p{N}_:./-]/", "_"), "/_+/", "_"), "_") : v
  ) }

  primary = { for k, s in local.pkeys : k => try(tostring(s.key), k) }
  aliases = { for k, s in local.pkeys : k => try(tolist(s.aliases), []) }
  dd_keys = { for k, s in local.pkeys : k => distinct(concat([local.primary[k]], local.aliases[k])) }

  env_name = local.value["env"]
  static_raw = merge(
    try(local.policy.static_tags, {}),
    try(local.policy.environments[local.env_name].static_tags, {}),
    var.extra_tags,
  )
  static = { for k, v in local.static_raw : k => (
    local.normalize ? trim(replace(replace(lower(tostring(v)), "/[^\\p{L}\\p{N}_:./-]/", "_"), "/_+/", "_"), "_") : tostring(v)
  ) if tostring(v) != "" }

  canonical_tags = merge(concat([{}], [for k, s in local.pkeys : {
    for dk in local.dd_keys[k] : dk => local.value[k] if local.value[k] != ""
  }])...)
  # canonical keys win over static / extra tags; tag length (key:value) capped at Datadog's 200 characters
  tags = { for dk, v in merge(local.static, local.canonical_tags) : dk => substr(v, 0, max(1, 199 - length(dk))) }

  extra    = { for dk, v in local.tags : dk => v if !contains(local.unified, dk) }
  dd_list  = [for dk in sort(keys(local.tags)) : "${dk}:${local.tags[dk]}"]
  dd_extra = [for dk in sort(keys(local.extra)) : "${dk}:${local.extra[dk]}"]

  missing_required = sort([for k, s in local.pkeys : local.primary[k] if try(s.required, false) && local.value[k] == ""])
  invalid_values = sort([for k, s in local.pkeys : "${local.primary[k]}:${local.value[k]}"
  if local.value[k] != "" && length(try(s.allowed_values, [])) > 0 && !contains(try(s.allowed_values, []), local.value[k])])
  renamed_unified = [for k in local.unified : k if try(local.primary[k], k) != k]

  # ------------------------------------------------------------------ OpenTelemetry resource attributes
  otel = merge(
    local.static,
    merge(concat([{}], [for k, s in local.pkeys : {
      for a in distinct(concat(try(tolist(s.otel_attributes), [local.primary[k]]), local.aliases[k])) : a => local.value[k]
      if local.value[k] != ""
    }])...),
  )
  otel_string = join(",", [for a in sort(keys(local.otel)) : "${a}=${replace(replace(local.otel[a], ",", "%2C"), "=", "%3D")}"])

  # ------------------------------------------------------------------ Kubernetes
  label_value_re = "^(([A-Za-z0-9][-A-Za-z0-9_.]*)?[A-Za-z0-9])?$"
  label_key_re   = "^[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$"
  no_label_keys  = flatten([for k, s in local.pkeys : local.dd_keys[k] if try(s.k8s_label, true) == false])
  k8s_labels = merge(
    { for k in local.unified : "tags.datadoghq.com/${k}" => local.tags[k]
    if can(local.tags[k]) && length(try(local.tags[k], "")) <= 63 && can(regex(local.label_value_re, try(local.tags[k], ""))) },
    { for dk, v in local.extra : dk => v
    if !contains(local.no_label_keys, dk) && can(regex(local.label_key_re, dk)) && length(v) <= 63 && can(regex(local.label_value_re, v)) },
  )
  # every non-unified tag, label-safe or not (owner e-mails, long values): Datadog Agent tag autodiscovery
  k8s_annotations = length(local.extra) == 0 ? {} : { "ad.datadoghq.com/tags" = jsonencode(local.extra) }
  # policy-wide label -> tag mapping for the Agent (podLabelsAsTags) and the Fluent Bit DaemonSet
  label_keys = distinct(concat(
    flatten([for k, s in local.pkeys : local.dd_keys[k] if !contains(local.unified, k) && try(s.k8s_label, true) != false]),
    keys(local.static),
  ))
  pod_labels_as_tags = { for dk in local.label_keys : dk => dk if can(regex(local.label_key_re, dk)) }

  # ------------------------------------------------------------------ Azure
  # Azure resource tags (first azure_tag_keys entry per key, value before Datadog normalisation: Datadog
  # normalises imported Azure tags itself, so both sides end up identical) + static tags.
  azure_tags = merge(
    local.static_raw,
    { for k, s in local.pkeys : try(tostring(s.azure_tag_keys[0]), local.primary[k]) => (local.normalize ? local.mapped[k] : local.value[k])
    if local.value[k] != "" },
  )
  # lowercase Azure tag key -> Datadog keys (platform logs that carry resource tags; Fluent Bit aggregator)
  azure_tag_key_map = merge(concat([{}], [for k, s in local.pkeys : {
    for az in distinct([for a in try(tolist(s.azure_tag_keys), [local.primary[k]]) : lower(a)]) : az => local.dd_keys[k]
  }])...)
}
