terraform {
  required_version = ">= 1.14.0, < 2.0.0"
  # No providers: the DelineaXPM/dsv provider cannot manage users, policies or auth providers, so this root only
  # renders the desired state and tools/secrets/dsv_apply.py converges it through the DSV REST API.
}
