# Pure function module: renders the validated OTel gateway configs (observability/config/otel) as
# collector config-provider env vars + command line for the chosen distribution.
terraform {
  required_version = ">= 1.14.0, < 2.0.0"
}
