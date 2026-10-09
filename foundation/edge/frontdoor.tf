# Azure Front Door Standard/Premium with a WAF policy. Premium adds managed rule sets + Private Link origins.
locals {
  afd         = local.s.front_door
  afd_on      = local.afd.enabled
  afd_premium = local.afd.sku_name == "Premium_AzureFrontDoor"
  afd_origins = { for o in local.afd.origins : o.name => o }
}

resource "azurerm_cdn_frontdoor_profile" "this" {
  count = local.afd_on ? 1 : 0

  name                     = local.names.front_door
  resource_group_name      = local.rg_name
  sku_name                 = local.afd.sku_name
  response_timeout_seconds = 60
  tags                     = local.tags
}

resource "azurerm_cdn_frontdoor_firewall_policy" "this" {
  count = local.afd_on ? 1 : 0

  name                = "${replace(local.names.front_door, "-", "")}waf"
  resource_group_name = local.rg_name
  sku_name            = local.afd.sku_name
  enabled             = true
  mode                = local.afd.waf_mode
  tags                = local.tags

  # Standard SKU supports custom rules only; keep a rate limit so the policy is never empty.
  custom_rule {
    name                           = "RateLimitPerIp"
    enabled                        = true
    priority                       = 100
    type                           = "RateLimitRule"
    rate_limit_duration_in_minutes = 1
    rate_limit_threshold           = 1000
    action                         = "Block"

    match_condition {
      match_variable = "RemoteAddr"
      operator       = "IPMatch"
      match_values   = ["0.0.0.0/0", "::/0"]
    }
  }

  dynamic "managed_rule" {
    for_each = local.afd_premium ? [
      { type = "Microsoft_DefaultRuleSet", version = "2.1", action = "Block" },
      { type = "Microsoft_BotManagerRuleSet", version = "1.1", action = "Block" },
    ] : []
    content {
      type    = managed_rule.value.type
      version = managed_rule.value.version
      action  = managed_rule.value.action
    }
  }
}

resource "azurerm_cdn_frontdoor_endpoint" "this" {
  count = local.afd_on ? 1 : 0

  name                     = "${var.environment.name_prefix}-${var.environment.name}-${module.naming.suffix}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this[0].id
  tags                     = local.tags
}

resource "azurerm_cdn_frontdoor_origin_group" "this" {
  count = local.afd_on ? 1 : 0

  name                     = "default"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this[0].id
  session_affinity_enabled = false

  load_balancing {
    sample_size                 = 4
    successful_samples_required = 3
  }

  health_probe {
    interval_in_seconds = 60
    path                = local.afd.probe_path
    protocol            = "Https"
    request_type        = "GET"
  }
}

resource "azurerm_cdn_frontdoor_origin" "this" {
  for_each = local.afd_on ? local.afd_origins : {}

  name                           = each.key
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.this[0].id
  enabled                        = true
  host_name                      = each.value.host_name
  origin_host_header             = coalesce(each.value.origin_host_header, each.value.host_name)
  https_port                     = 443
  http_port                      = 80
  priority                       = 1
  weight                         = 1000
  certificate_name_check_enabled = true

  dynamic "private_link" {
    for_each = each.value.private_link == null ? [] : [each.value.private_link]
    content {
      private_link_target_id = private_link.value.target_id
      location               = private_link.value.location
      target_type            = private_link.value.target_type
      request_message        = "Front Door ${local.names.front_door} (approve in the origin's Networking blade)"
    }
  }
}

resource "azurerm_cdn_frontdoor_route" "this" {
  count = local.afd_on ? 1 : 0

  name                          = "default"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.this[0].id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.this[0].id
  cdn_frontdoor_origin_ids      = [for o in azurerm_cdn_frontdoor_origin.this : o.id]
  patterns_to_match             = ["/*"]
  supported_protocols           = ["Http", "Https"]
  https_redirect_enabled        = true
  forwarding_protocol           = "HttpsOnly"
  link_to_default_domain        = true
}

resource "azurerm_cdn_frontdoor_security_policy" "this" {
  count = local.afd_on ? 1 : 0

  name                     = "waf"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this[0].id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.this[0].id
      association {
        patterns_to_match = ["/*"]
        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.this[0].id
        }
      }
    }
  }
}
