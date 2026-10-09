# Entity definition v3: https://docs.datadoghq.com/internal_developer_portal/software_catalog/entity_model/
locals {
  entities = {
    for name, s in var.services : name => {
      apiVersion = "v3"
      kind       = "service"
      metadata = {
        name        = name
        displayName = coalesce(s.display_name, name)
        description = s.description
        owner       = s.team
        tags        = sort(distinct(concat(s.tags, ["env:${s.env}"])))
        contacts    = [for c in s.contacts : { name = coalesce(c.name, c.contact), type = c.type, contact = c.contact }]
        links = concat(
          [{ name = "Runbook", type = "runbook", url = s.runbook_url }],
          s.repository == null ? [] : [{ name = "Repository", type = "repo", url = s.repository }],
          s.dashboard_url == null ? [] : [{ name = "Service dashboard", type = "dashboard", url = s.dashboard_url }],
        )
      }
      spec = merge(
        { lifecycle = s.lifecycle, tier = s.tier, type = s.type, languages = s.languages },
        length(s.depends_on) > 0 ? { dependsOn = s.depends_on } : {},
        length(s.component_of) > 0 ? { componentOf = s.component_of } : {},
      )
    }
  }
  systems = {
    for name, s in var.systems : name => {
      apiVersion = "v3"
      kind       = "system"
      metadata   = { name = name, displayName = coalesce(s.display_name, name), owner = s.owner }
      spec       = { components = s.components }
    }
  }
}

resource "datadog_software_catalog" "service" {
  for_each = local.entities
  entity   = yamlencode(each.value)
}

resource "datadog_software_catalog" "system" {
  for_each = local.systems
  entity   = yamlencode(each.value)
}
