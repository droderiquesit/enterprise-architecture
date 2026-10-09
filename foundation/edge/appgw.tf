# Application Gateway WAF_v2: HTTPS listener (PFX certificate from Delinea DSV via the pipeline), HTTP->HTTPS redirect,
# backend pool of FQDNs (e.g. ACA environment / AKS ingress internal hostnames), health probe on /healthz.
locals {
  agw    = local.s.app_gateway
  agw_on = local.agw.enabled
  agw_cfg = {
    gateway_ip  = "gateway-ip"
    frontend_ip = "public-frontend"
    port_https  = "https-443"
    port_http   = "http-80"
    pool        = "backend-fqdns"
    settings    = "backend-https"
    probe       = "healthz"
    listener    = "https"
    listener80  = "http"
    redirect    = "http-to-https"
    cert        = "listener-tls"
  }
}

# TLS certificate: Key Vault references are not available (all lab secrets live in Delinea DSV, ADR-0001 section 14).
# The listener certificate is passed as `ssl_certificate.data` (base64 PFX) + `password` from the ephemeral pipeline
# inputs var.tls_certificate_pfx / var.tls_certificate_password (DSV appgw-tls-pfx, elements value/password, fetched
# by tools/secrets/fetch.py). azurerm 5.9 has NO write-only form of ssl_certificate.data/password, so the PFX and
# its password ARE stored in Terraform state and in the saved plan (protected containers) - docs/known-limitations.md.
# Recommended alternative without any secret: Front Door (settings.front_door) with its Microsoft-managed certificate.
resource "azurerm_public_ip" "appgw" {
  count = local.agw_on ? 1 : 0

  name                = "${local.names.public_ip}-agw"
  resource_group_name = local.rg_name
  location            = local.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.agw.zones
  tags                = local.tags
}

resource "azurerm_web_application_firewall_policy" "appgw" {
  #checkov:skip=CKV_AZURE_135:Microsoft_DefaultRuleSet 2.1 includes the Log4j (CVE-2021-44228) rules (944240 et al.); the check only recognises OWASP CRS versions.
  count = local.agw_on ? 1 : 0

  name                = "${replace(local.names.application_gateway, "-", "")}waf"
  resource_group_name = local.rg_name
  location            = local.location
  tags                = local.tags

  policy_settings {
    enabled                     = true
    mode                        = local.agw.waf_mode
    request_body_check          = true
    max_request_body_size_in_kb = 128
  }

  managed_rules {
    managed_rule_set {
      type    = "Microsoft_DefaultRuleSet"
      version = "2.1"
    }
    managed_rule_set {
      type    = "Microsoft_BotManagerRuleSet"
      version = "1.1"
    }
  }
}

resource "azurerm_application_gateway" "this" {
  #checkov:skip=CKV_AZURE_218:Predefined policy AppGwSslPolicy20220101 enforces TLS 1.2 minimum with modern ciphers.
  count = local.agw_on ? 1 : 0

  name                              = local.names.application_gateway
  resource_group_name               = local.rg_name
  location                          = local.location
  zones                             = local.agw.zones
  firewall_policy_id                = azurerm_web_application_firewall_policy.appgw[0].id
  force_firewall_policy_association = true
  tags                              = local.tags

  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }

  autoscale_configuration {
    min_capacity = local.agw.min_capacity
    max_capacity = local.agw.max_capacity
  }

  gateway_ip_configuration {
    name      = local.agw_cfg.gateway_ip
    subnet_id = local.subnets["appgw"].id
  }

  frontend_ip_configuration {
    name                 = local.agw_cfg.frontend_ip
    public_ip_address_id = azurerm_public_ip.appgw[0].id
  }

  frontend_port {
    name = local.agw_cfg.port_https
    port = 443
  }

  frontend_port {
    name = local.agw_cfg.port_http
    port = 80
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  ssl_certificate {
    name     = local.agw_cfg.cert
    data     = var.tls_certificate_pfx
    password = var.tls_certificate_password
  }

  backend_address_pool {
    name  = local.agw_cfg.pool
    fqdns = local.agw.backend_fqdns
  }

  probe {
    name                                      = local.agw_cfg.probe
    protocol                                  = local.agw.backend_protocol
    path                                      = local.agw.probe_path
    interval                                  = 30
    timeout                                   = 10
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = true
  }

  backend_http_settings {
    name                                = local.agw_cfg.settings
    cookie_based_affinity               = "Disabled"
    port                                = local.agw.backend_port
    protocol                            = local.agw.backend_protocol
    request_timeout                     = 30
    pick_host_name_from_backend_address = true
    probe_name                          = local.agw_cfg.probe
  }

  http_listener {
    name                           = local.agw_cfg.listener
    frontend_ip_configuration_name = local.agw_cfg.frontend_ip
    frontend_port_name             = local.agw_cfg.port_https
    protocol                       = "Https"
    ssl_certificate_name           = local.agw_cfg.cert
    host_name                      = local.agw.listener_host_name
  }

  http_listener {
    name                           = local.agw_cfg.listener80
    frontend_ip_configuration_name = local.agw_cfg.frontend_ip
    frontend_port_name             = local.agw_cfg.port_http
    protocol                       = "Http"
    host_name                      = local.agw.listener_host_name
  }

  redirect_configuration {
    name                 = local.agw_cfg.redirect
    redirect_type        = "Permanent"
    target_listener_name = local.agw_cfg.listener
    include_path         = true
    include_query_string = true
  }

  request_routing_rule {
    name                       = "https-to-backend"
    rule_type                  = "Basic"
    priority                   = 100
    http_listener_name         = local.agw_cfg.listener
    backend_address_pool_name  = local.agw_cfg.pool
    backend_http_settings_name = local.agw_cfg.settings
  }

  request_routing_rule {
    name                        = "http-redirect"
    rule_type                   = "Basic"
    priority                    = 200
    http_listener_name          = local.agw_cfg.listener80
    redirect_configuration_name = local.agw_cfg.redirect
  }

  lifecycle {
    precondition {
      condition     = var.tls_certificate_pfx != null && var.tls_certificate_password != null
      error_message = "Application Gateway needs the listener certificate: DSV <prefix>/<env>/appgw-tls-pfx (value = base64 PFX, password) passed by the pipeline as TF_VAR_tls_certificate_pfx / TF_VAR_tls_certificate_password."
    }
    precondition {
      condition     = contains(keys(local.subnets), "appgw")
      error_message = "Application Gateway needs the appgw subnet (foundation-network settings.appgw_subnet = true)."
    }
  }
}
