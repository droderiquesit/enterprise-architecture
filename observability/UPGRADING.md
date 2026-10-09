# Upgrading the observability package

## General procedure (any version)

1. Read the target version's section below and the `CHANGELOG.md`.
2. Update `package.lock.json` (`version`, `sha256`, `url`) or the `?ref=observability-v<version>` of git sources,
   and the `@obs` repository `ref` of the pipeline templates. Keep both on the same version.
3. `./vendor.sh` (checksum verified), then re-render every environment:
   `python3 .vendor/observability-<v>/tools/onboarding/render.py render --manifests manifests --env <env> --out rendered/<env>`.
   Review the diff of `rendered/` - it is the exact change set of monitoring content.
4. `terraform init -upgrade` (only if the provider constraint changed), `terraform plan -out tfplan`.
   The plan template prints `DESTROY: [...]`. For MINOR/PATCH upgrades this must list no monitored
   infrastructure (the package never manages it) and no monitor whose key still exists.
5. Apply the saved plan. Rollback = previous lock + re-render + apply (README section 5).

## Version-specific notes

### 1.0.0
Initial release. No migration.

## Compatibility promises

* Monitor keys (`<service>/<monitor_key>[@role]`) are part of the public interface; renaming one is a MAJOR change
  because it recreates the monitor (history and mute state are lost).
* `rendered-service/v1` is consumed by `modules/onboarding`; a new rendered schema is a MAJOR change and the
  previous major is accepted for one release.
* Manifest `apiVersion: observability/v1` stays valid for every 1.x release; new optional fields may be added.
