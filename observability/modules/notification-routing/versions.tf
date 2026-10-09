terraform {
  required_version = ">= 1.14.0, < 2.0.0"
  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 4.25"
    }
  }
}
