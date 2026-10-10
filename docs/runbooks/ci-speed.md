# CI speed and the test result cache

What the fast-CI machinery does is described in [pipelines/README.md "Fast CI"](../../pipelines/README.md#fast-ci).
This page is for when it misbehaves. Nothing here has been run in a real Azure DevOps organisation yet.

| Symptom | Check | Fix |
|---|---|---|
| A PR took longer than its budget | run summary "CI speed" (`ci-report-*/timing.json`): critical leg, slowest units, cache hit rate | slowest unit = one big test file: split it; low hit rate after a `versions.yaml` / `tools/ci` change is expected (global input) |
| A suite you expected did not run | `selection/ci-plan.json` -> `suites.<id>.reasons`; locally `python3 -m tools.ci plan --worktree` | add the missing path to the suite's `inputs` (or `covers`) in `tools/ci/suites.yaml` |
| Suspected bad cached pass ("it passed but it is broken") | `suites.<id>.cache_hit` (run id) | queue a run with a full plan (any `release/*` run or the nightly schedule ignores the cache), or locally `python3 -m tools.ci run --all`; to drop every entry change the Cache@2 key prefix `ci-testcache` in `validate.yml` / `universal-stages.yml` |
| A leg is much slower than estimated | `legs[].seconds` vs `estimate_seconds` | timings adapt (EWMA) after a run; for a new suite add its duration to `tools/ci/timings.json` |
| The gates leg cancelled the run | the gates leg log (`tools.ci gates`: one line per check) | fix the failing static check; `pre-commit run --all-files` catches most of them locally |
| `terraform init` fails with "provider not found in mirror" | the `tf-mirror` step log | a lock file references a provider version not yet mirrored: the step downloads it (network); re-run |
