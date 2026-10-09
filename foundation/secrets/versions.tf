terraform {
  required_version = ">= 1.14.0, < 2.0.0"
  # No providers: this root only RENDERS the desired Delinea DSV state. DelineaXPM/dsv 1.13.0 (registry, checked
  # 2026-10-09) offers data sources client/role/secret and the resource dsv_client only - no users, policies or auth
  # providers - so tools/secrets/dsv_apply.py converges the rendered state through the DSV REST API.
}
