# Starts on local state (scripts/bootstrap.sh adds a backend_override.tf), then migrates here; README "First run".
terraform {
  backend "azurerm" {}
}
