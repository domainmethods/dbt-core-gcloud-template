# CI Slim-Build Diff & Test Accuracy — Learnings

A single reference for how the template's PR CI produces **data diffs** and **schema diffs**,
why "no-op" PRs can show phantom differences or false test failures, and how the template's
design mitigates each. Distilled from the multi-phase effort on this template (PRs #55, #56) and
validated end-to-end against a real downstream consumer (`weightcare-pipeline-new`).

## How the check is built

On a PR, CI builds only the changed models and **defers everything else to prod**:

```
dbt build --select <scope> --defer --state prod_state --exclude-resource-type test
```

- **Selected** models are rebuilt **fresh** in an ephemeral CI dataset, from **current** sources.
- **Unselected** ancestors resolve to the **last prod build's tables** (older snapshot).

The data diff then compares each built model (dev, now) against its prod counterpart (built
earlier). **The two sides are not built from the same source snapshot** — so any difference that
isn't caused by the PR's code is a *false positive*. The sections below are the classes of false
positive and how to keep them out of the signal.

## Selection: build scope == diff scope

`scripts/get_changed_models.sh` derives the scope from the **git diff**, emitting:

- `HAS_MODEL_CHANGES` — false for docs/config-only PRs.
- `DIFF_SELECT` / `BUILD_SELECT` — `name+` per changed model/seed/snapshot (model + downstream;
  no leading `+`, so ancestors defer). These are **identical**, so build and diff cover the same
  models.
- `NEEDS_FALLBACK` — true for macro / `dbt_project.yml` / `packages.yml` / yaml-only changes that
  can't be scoped by filename.

`scripts/ci_build.sh` consumes these: git-diff-scoped build for model changes; a combined
`"$BUILD_SELECT state:modified+"` tier when a macro/config change accompanies model changes;
`state:modified+` for macro/config/yaml-only; and a full build only when no prod manifest exists.

## The false-positive classes (and the fix)

1. **Ancestor rebuild → drift.** If the build selects ancestors too (e.g. `+model+` with a leading
   `+`), they rebuild from *current* sources while prod used *older* ones → the whole downstream
   differs. **Fix:** scope to `model+` (no leading `+`) and `--defer` unchanged ancestors to prod,
   so both sides read the same upstream tables. (This template already does this.)

2. **FLOAT64 non-associativity.** Floating-point `SUM`/aggregation is **not associative**;
   BigQuery may combine partitions in a different order across builds, so a byte-identical model
   yields slightly different `FLOAT64` values each run. `EXCEPT DISTINCT` then reports thousands of
   "changed" rows for a no-op (observed: ~11k phantom rows in a monthly-aggregation model).
   **Fix (in the models):** round/quantize `FLOAT64` columns before they're compared
   (e.g. `ROUND(x, 6)`), or store money as `NUMERIC`. This is a **data-modeling** fix in the
   consumer's models, not a CI change.

3. **Non-deterministic row selection (`ROW_NUMBER`/`QUALIFY`).** A `QUALIFY ROW_NUMBER() OVER
   (... ORDER BY <non-unique>) = 1` breaks ties differently across builds → different rows survive
   → diff noise for a no-op. **Fix (in the models):** add a unique tiebreaker to the `ORDER BY`.

4. **Defer boundary + eager indirect selection.** `--defer` does **not** freeze `source()` reads
   or **view** (ephemeral/view-materialized) ancestors — those still read live data. And dbt's
   default **eager** indirect selection runs a data test if **any** referenced model is selected,
   even when the test also spans a **deferred** (stale) model → it reconciles fresh-vs-stale and
   fails on non-code drift. **Fix:** run tests with **`--indirect-selection cautious`**, which
   runs a data test only when **every** model it references is selected. Cross-boundary tests are
   skipped in PR CI (they still run in the nightly/prod build against one consistent snapshot).
   Single-model tests (`not_null`/`unique`/`accepted_values`) and both-sides-selected tests still
   run — it cannot mask a real regression.

## Test gating: don't let a red data test suppress the diff

`ci_build.sh` builds with `--exclude-resource-type test`; `dbt test` runs as a **separate,
non-blocking** CI step. So a failing data test surfaces as its own (red) check without skipping the
diff/comment steps (which gate on model-build success only).

> **Resolved:** the non-blocking `dbt test` step passes **`--indirect-selection cautious`**, so the
> class-4 cross-boundary tests (fresh-vs-deferred) stay out of the report. PR #56 added this flag to
> `main`'s inline build; here it lives on the separate `dbt test` step, and #56 was folded into this
> PR rather than merged on its own.

## Docs-only PRs

`HAS_MODEL_CHANGES=false` short-circuits both `pr_data_diff.sh` and `pr_schema_diff.sh` before any
`bq`/`dbt` call, so a docs-only PR posts no diff. Note: a **scripts/workflow-only** PR is also
"no model changes" — useful, because it means a CI-infra PR won't try to diff.

## Offline verification tricks

- **Which tests will run:** `dbt ls --select <scope> --indirect-selection eager|cautious
  --resource-type test` shows exactly which tests each mode includes — deterministic, no BigQuery.
- **Don't validate with a scripts-only PR.** A PR that changes only `scripts/`/workflow yields
  `HAS_MODEL_CHANGES=false` → nothing is built/diffed. To exercise the diff, the test PR must touch
  a **model** (a no-op CTE rename is ideal for the "expect ~0 diff" check).
- **Workflow trigger:** the CI workflow runs on `pull_request` to `main` only — a PR based on a
  feature branch won't trigger it (rebase onto `main`, or push a trigger commit).

## Known limitations (accepted)

- **Macro+model PRs: build ⊋ diff.** The build unions `state:modified+` for macro coverage, but the
  diff uses the git scope only — macro-affected models are built but not diffed.
- **Fallback path is manifest-dependent.** Model-change PRs are manifest-independent for build
  scoping; macro/config/yaml-only PRs still use `state:modified+` and can over-select if the prod
  manifest is stale.
- **Classes 2 & 3 are data-modeling fixes**, not CI features — the template can't fix a consumer's
  non-deterministic models; this doc is the guidance.

## Cross-references

- Design/plan: `docs/superpowers/specs/2026-08-12-template-build-selection-parity-design.md`,
  `docs/superpowers/plans/2026-08-12-template-build-selection-parity.md`.
- Downstream consolidation (weightcare): `docs/ci_slim_build_accuracy_learnings.md` (that repo's
  PR #142), covering the same classes with issue-level history (#117, #128–#131, #138, #140).
