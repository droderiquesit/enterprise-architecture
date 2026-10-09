# Providers are configured by the CALLER (cluster host, CA, exec/kubelogin credentials); this module only
# declares helm/kubernetes resources so it works against any existing cluster.
terraform {
  required_version = ">= 1.14.0, < 2.0.0"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.3"
    }
  }
}
