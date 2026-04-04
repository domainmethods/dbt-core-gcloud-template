# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

dbt Core project targeting BigQuery, deployed via Cloud Run Jobs + Cloud Scheduler on GCP. Uses per-developer isolated datasets for development, ephemeral datasets for CI, and a shared production dataset.

**Profile name:** `dbt_gcloud` (in `profiles/profiles.yml`)
**dbt project name:** `dbt_gcloud`
**Targets:** `dev` (local), `ci` (GitHub Actions), `prod` (Cloud Run)

## Development Setup

```bash
cp infra/.env.example infra/.env  # First time only — set PROJECT_ID, REGION, etc.
source ./setup-env.sh          # Sets DBT_USER (from gcloud email), DBT_PROFILES_DIR=profiles
make deps                      # Install Python deps + dbt packages
```

Note: `setup-env.sh` will error if `infra/.env` is missing — copy it first.

Dev dataset is named `analytics_<DBT_USER>` by default. `DBT_USER` is derived from the active gcloud account email (lowercased, sanitized for BigQuery dataset rules).

## Common Commands (via Makefile)

```bash
make build                                   # Build all models (dev target)
make run MODEL=my_model                      # Run a single model
make test                                    # Run all tests
make compare MODEL=fct_example               # Compare dev vs prod data
make docs                                    # Generate and preview dbt docs
make clean                                   # Clean target/ and packages
```

Or use dbt CLI directly:

```bash
dbt build --select model_name+               # Build model and downstream
dbt run-operation dev_prod_diff --args '{"table_name":"fct_example"}'
```

## Linting

sqlfluff runs in **manual stage** (not on every commit) to avoid slow feedback loops:

```bash
make lint                                    # Recommended: run via Makefile
make lint-fix                                # Auto-fix SQL issues
pre-commit run --hook-stage manual --all-files  # Direct pre-commit invocation
```

yamllint runs automatically on every commit for `models/**/*.yml` files.
SQLFluff config is in `.sqlfluff` — max line length 120, bigquery dialect, dbt templater.

## Architecture

### Model Layer Convention
- `models/staging/` — views (`+materialized: view`), prefixed `stg_`
- `models/marts/` — tables (`+materialized: table`), prefixed `fct_`/`dim_`
- Sources defined in `models/staging/src_*.yml`

### CI Pipeline (`.github/workflows/ci.yml`)
PR triggers: lint job (SQLFluff + yamllint via pre-commit) → `bigquery-ci` job that:
1. Creates ephemeral dataset `ci_pr_<number>_<run_id>`
2. Downloads prod manifest from GCS for Slim CI (`state:modified+` with `--defer`)
3. Runs `dbt build` against only modified models
4. Generates data diffs (`scripts/pr_data_diff.sh`) and schema diffs (`scripts/pr_schema_diff.sh`)
5. Posts diff summaries as PR comments
6. Cleans up ephemeral dataset

### Release Pipeline (`.github/workflows/release.yml`)
Push to `main` triggers: Docker build → push to Artifact Registry → update Cloud Run Job → execute immediately. The container (`entrypoint.sh`) runs `dbt build`, optional source freshness, optional docs generation, and uploads artifacts to GCS.

### Infrastructure Scripts (`infra/`)
Numbered shell scripts run in order for initial GCP setup: bootstrap → WIF → GitHub secrets → Cloud Run Job → Cloud Scheduler → docs hosting → monitoring. All read from `infra/.env`.

### Key Macros
- `macros/compare_dev_prod.sql` — `dev_prod_diff` macro for row-level dev-vs-prod comparison using `EXCEPT DISTINCT`
- `macros/generate_schema_name.sql` — Controls dataset naming; appends custom schema suffix if specified

### Python Scripts (`scripts/lib/`)
- `dbt_summary.py` — Emits JSON summary of run_results.json; exits non-zero on failures
- `freshness_summary.py` — Summarizes source freshness results
- `upload_docs.py` / `upload_artifacts.py` — Upload dbt artifacts to GCS

### Python Hooks
- `hooks/pre_run.py` / `hooks/post_run.py` — Optional hooks invoked by `entrypoint.sh` when `RUN_PRE_HOOK=true` / `RUN_POST_HOOK=true`

## Environment Variables

Key variables loaded from `infra/.env`:
- `DBT_GCP_PROJECT_DEV` / `DBT_GCP_PROJECT_PROD` / `DBT_GCP_PROJECT_CI` — GCP project IDs per environment
- `DBT_BQ_DATASET_PROD` — Production dataset (default: `analytics`)
- `DBT_ARTIFACTS_BUCKET` — GCS bucket for manifest/run_results (enables Slim CI)
- `DBT_DOCS_BUCKET` — GCS bucket for static docs site
