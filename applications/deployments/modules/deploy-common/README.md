# deploy-common — naming, tags and artifact metadata (pure module)

Owner: applications layer. Called from every deployment root's `common.tf` with `var.environment`, `var.artifacts`,
the component id and the naming workload segment. Outputs `names`, `suffix`, `tags`, `artifact_version` (version → tag → digest
or package-hash prefix) and `artifact_commit`. Tested through the roots' `terraform test`.
