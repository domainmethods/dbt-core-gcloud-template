# Tier 2 Validation: `pr_schema_diff.sh` against a real downstream manifest

**Date:** 2026-07-27
**Branch:** `fix/53-pr-schema-diff-set-u`
**Downstream repo:** `jasonbhart/weightcare-pipeline-new` (cloned read-only, depth 1, into a scratch temp dir; never pushed to, no branch/commit/PR created there)

## Method

1. Cloned `jasonbhart/weightcare-pipeline-new` (~16MB checkout) into a scratch temp directory.
2. Created a Python venv, installed `dbt-core==1.10.8` / `dbt-bigquery==1.10.1` (the versions specified in the Task 5 brief), ran `dbt deps`.
3. Ran `dbt parse` with `DBT_TARGET=ci` and dummy CI env vars. **`dbt parse` succeeded fully offline** — it never attempted a BigQuery connection, so the `dbt ls --output name` fallback was not needed. Produced `target/manifest.json` (7.6MB).
4. Copied the real manifest into `target/manifest.json` and `prod_state/manifest.json` for a `$WORK/run` scratch harness, per the brief's stub scripts (`bq` stub logs every invocation and returns canned JSON by query shape; `dbt` stub serves `dbt ls` from the real manifest).
5. Ran the fixed `scripts/pr_schema_diff.sh` unmodified against this harness, with `bq` and `dbt` fully stubbed (no GCP auth, no BigQuery spend).

## Deviation from the brief: real model count is 383, not ~40

The brief assumed "~40 real models." The manifest built from the actual repository contains:

- **69** models owned by the `dbt_gcloud` project itself (`package_name == dbt_gcloud`)
- **383** models total once installed packages are included (Fivetran `facebook_ads`/`hubspot`/`klaviyo`/`shopify`, `ga4`)

The brief's `dbt` stub selects **every** `resource_type=="model"` node in the manifest regardless of package, which is also what the real script does in its fallback path (`dbt ls --resource-type model --output name --quiet`, used whenever there is no prod-manifest-based `state:modified+` selection). Since the harness intentionally exercises "no state filtering" behavior, this is a legitimate worst-case measurement, not a mistake — but it is 6-10x larger than the brief's planning assumption. Both scales are reported below.

## New finding: `get_node_by_name` does not disambiguate by package

While auditing the raw `bq` invocation log, the naive count (`wc -l < bq_calls.log`, as literally specified in the brief's Step 4) came to **2599**, not the expected `6 × 383 + 1 = 2299`. Root cause: **10 model names are duplicated across the project and an installed package** (e.g. `stg_facebook_ads__basic_ad_actions` exists both as the project's own customized model and inside the `fivetran/facebook_ads` package it shadows). `get_node_by_name()` in `scripts/pr_schema_diff.sh` selects on `.value.name==$n` only, with no `package_name` filter, so for these 10 names it matches **two** manifest nodes and pipes a two-document JSON stream through `node_to_fqn`. Downstream `jq -r .project`/`.dataset`/`.identifier` extraction then emits multi-line, corrupted FQN strings (visible directly in `stg_facebook_ads__basic_ad_actions.txt`: `Prod:` spans 4 lines instead of 1). This inflates the naive line-count of the `bq` call log by exactly 300 lines (confirmed: `grep -c -- '--project_id='` — a marker present exactly once per genuine invocation — gives the clean **2299**, matching the formula exactly).

This is a real, previously-undetected defect that only surfaces at realistic scale (the 2-model test fixture has no name collisions across packages). It does **not** cause `unresolved > 0` (the model still resolves, just to corrupted data) so it does not trip the brief's stop condition, and per task boundaries `scripts/pr_schema_diff.sh` was not modified to fix it here. It should be filed as a follow-up defect (candidate "Defect C") alongside the already-known Defect B.

## The four measured numbers (Step 4)

| Metric | Value |
|---|---|
| Models selected (`dbt ls` over the real manifest, stubbed) | **383** |
| Unresolved (`grep -c 'Could not resolve model' stdout.txt`) | **0** |
| Summary rows (`grep -c '^\| [a-z]' schema-summary.md`) | **383** (equals models selected) |
| `bq` invocations, true count (`--project_id=` marker, one per real call) | **2299** (= 6 × 383 + 1, exact match to formula) |
| `bq` invocations, naive line count (`wc -l < bq_calls.log`, as literally specified in the brief) | 2599 (inflated by the package-name-collision defect above) |

Script exit code: **0**. No BigQuery credentials were used; `bq` and `dbt` were fully stubbed shell scripts on `PATH`.

## Extrapolated wall-clock and batching recommendation

Using the true invocation count (2299) at an assumed 2-6 seconds per real `bq` invocation (typical for a small `INFORMATION_SCHEMA` query against BigQuery):

- Low estimate: 2299 × 2s ≈ 4,598s ≈ **76.6 minutes**
- High estimate: 2299 × 6s ≈ 13,794s ≈ **229.9 minutes (3.8 hours)**

Even restricted to only the project's own 69 models (6 × 69 + 1 = 415 invocations, a more realistic ceiling for a single PR touching only its own code), the range is still 415 × 2-6s ≈ **13.8-41.5 minutes**.

Both scales are far in excess of the brief's five-minute threshold.

**Recommendation: batch the `INFORMATION_SCHEMA` queries.** At current per-model, per-query-type `bq` invocation volume, a PR that changes even a modest number of models (let alone triggers the full-manifest fallback path) will add tens of minutes to CI. Batching (e.g. one `INFORMATION_SCHEMA.COLUMNS`/`TABLE_OPTIONS`/`TABLES` query per dataset covering all target tables via `WHERE table_name IN (...)`, instead of one query per table per side) should be scoped as a follow-up task.

## Cleanup and boundaries confirmation

- The clone, venv, and scratch run directory were created entirely under a temp/scratchpad path and removed with `rm -rf` after this document was written.
- No `bq` binary was ever invoked for real; `bq` was a stub shell script logging to a local file and returning canned JSON.
- No commits, branches, PRs, or issues were created against `jasonbhart/weightcare-pipeline-new`; the clone was read-only.
- `scripts/pr_schema_diff.sh`, `tests/test_pr_schema_diff.sh`, `Makefile`, and `.github/workflows/ci.yml` were not modified.
