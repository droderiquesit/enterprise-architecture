# Contributing

Trunk-based: short-lived branches, small pull requests into `main`, squash merge. The full model, who approves
what, and how CI stays fast with many commits per hour: [docs/guides/branching-and-development.md](docs/guides/branching-and-development.md).

## Before you push

```bash
pip install pre-commit && pre-commit install        # cheap gates on every commit
python3 -m tools.changeset explain --branch          # what your branch may do; what a run would validate/build/plan
python3 -m tools.ci run --changed                    # the tests the PR build will run, locally and in parallel
```

## Branches

| Prefix | Use |
|---|---|
| `feature/<short-name>` | new behaviour |
| `fix/<short-name>` | bug fix (prod hotfix: fix on `main` first, then cherry-pick onto `release/<yyyy.mm>`) |
| `chore/<short-name>` | maintenance, dependency bumps |
| `docs/<short-name>` | documentation only |

Other names are refused by the repository's branch-name permissions. Topic branches never deploy; `main` deploys
dev, test/prod receive the same build by promotion.

## Pull requests

* Link a work item; resolve every comment, including GitHub Copilot code review threads (requested automatically,
  advisory; [automated PR review](docs/guides/automated-pr-review.md)).
* One approval plus the automated reviewer's required status `eh-review/policy`. Low-risk allowlisted changes can
  complete with the bot's approval; everything else needs a human, and protected areas (reviewer policy,
  pipelines/registry, identity/secrets, network, prod config) need their owner group
  ([CODEOWNERS](.github/CODEOWNERS), generated from `catalog/components.yaml` `owners`).
* Validation expires when `main` moves: rebase or let auto-complete re-validate.

## Rules that CI enforces

* Ownership and contracts: [ADR-0001](docs/architecture/ADR-0001-design-contract.md) (`tools/validate/ownership.py`).
* Provider pins exactly as [versions.yaml](versions.yaml) (`tools/validate/versions.py`); `terraform fmt`.
* Generated files are regenerated, never hand-edited or hand-merged: `pipelines/generated/*`
  (`python3 tools/pipeline/generate.py`), `.github/CODEOWNERS` (`python3 tools/ado/codeowners.py`), hashed
  requirement files (`uv pip compile`, see each file's header), generated docs (`python3 tools/docs/generate.py`,
  `python3 tools/catalog/render_coverage.py`) and diagram SVGs (`tools/docs/render_diagrams.sh`).
* Documentation: start from the [docs index](docs/README.md); links are checked by `python3 tools/docs/check_links.py`.
* Impact before renaming/deleting: optional local [Graphify knowledge graph](docs/guides/graphify.md)
  (`tools/graphify/build.sh`, then `graphify affected "<symbol>"`).
* No secrets anywhere: keys live in Delinea DSV (`dsv://` references only).
* New test suites: register them in [tools/ci/suites.yaml](tools/ci/suites.yaml) (`inputs` decide when they run);
  registry components get a suite automatically.
