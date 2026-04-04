# dbt-core-gcloud-template

A starter template for **dbt Core on BigQuery** with:

* Per‑developer isolated datasets (dev), **integration (optional INT_DATASET)**, and **production**
* **GitHub Actions** for CI (Slim CI + `--defer`) and containerized CD
* **Cloud Run Jobs** orchestrated by **Cloud Scheduler** for prod
* Optional **Python pre/post hooks** and **dbt docs** artifacts (static)

> Why these choices:
> • Per‑developer sandboxes and environment separation are well‑established best practices to reduce blast radius during development. Data teams often use developer‑specific schemas/datasets for isolation. ([Datafold][1])
> • "Slim CI" with `state:modified+` and `--defer` is a widely used pattern to speed up PR checks and validate only the impacted parts of the DAG. ([Medium][2], [Klaviyo Engineering][3])
> • Cloud Run **Jobs** + Cloud Scheduler provide serverless batch orchestration without maintaining servers; Jobs are designed for run‑to‑completion tasks and can be triggered on a schedule.

## 🚀 Choose Your Path

**New to this template?** Start with [Template Setup](#template-setup-new-deployment) to deploy the infrastructure and CI/CD pipeline.

**Developer joining an existing project?** Jump to [Developer Quick Start](#developer-quick-start) to get your local environment running.

**Need detailed reference?** See the [Complete Documentation](#complete-documentation) below.

---

## 📋 Table of Contents

* [Template Setup (New Deployment)](#template-setup-new-deployment)
* [Developer Quick Start](#developer-quick-start)
* [Dev Container Setup](#dev-container-setup)
* [Daily Development Workflow](#daily-development-workflow)
* [Troubleshooting](#troubleshooting)
* [Complete Documentation](#complete-documentation)

---

## Template Setup (New Deployment)

*Use this section if you're setting up this template for the first time.*

### Prerequisites Check

Before starting, verify you have these tools installed:

```bash
# Check versions
python --version    # Should be 3.9-3.12
pip --version
gcloud version      # Google Cloud SDK
docker --version    # For building images
jq --version        # JSON processing
gh --version        # GitHub CLI (optional)
```

**GCP Requirements:**

* GCP project with billing enabled
* Owner permissions (temporarily for setup)
* APIs will be enabled automatically by the bootstrap script

### Quick Setup (4 Steps)

#### Step 1: Configure Environment

```bash
# Copy and edit the configuration
cp infra/.env.example infra/.env
$EDITOR infra/.env   # Set PROJECT_ID, REGION, GITHUB_REPO, etc.
```

**💡 Essential variables to set:**

* `PROJECT_ID` - Your GCP project ID
* `PROJECT_NUMBER` - Your GCP project number
* `REGION` - GCP region (e.g., us-central1)
* `GITHUB_REPO` - Your repo (e.g., myorg/my-dbt-project)
* `DBT_DOCS_BUCKET` - Globally unique bucket name

#### Step 2: Bootstrap GCP Infrastructure

```bash
(cd infra && ./10-bootstrap.sh)
```

**✅ Success criteria:** Script completes without errors, shows "Bootstrap complete."

#### Step 3: Configure GitHub Integration

```bash
(cd infra && ./20-wif-github.sh)      # Set up OIDC
(cd infra && ./25-set-github-secrets.sh)  # Auto-configure repo secrets
```

**✅ Success criteria:** GitHub repo secrets are set (check in GitHub Settings > Secrets)

#### Step 4: Deploy Production Job

```bash
(cd infra && ./30-deploy-cloud-run-job.sh)
(cd infra && ./40-schedule-prod-job.sh)
```

**✅ Success criteria:** Cloud Run job exists and is scheduled

### Verify Your Setup

1. **Check GitHub Actions:** Push to main branch - CI/CD should trigger
2. **Check Cloud Run Job:** Should appear in GCP Console > Cloud Run > Jobs
3. **Check Scheduler:** Should appear in GCP Console > Cloud Scheduler

**🎉 Setup Complete!** Your template is now deployed. Developers can now use the [Developer Quick Start](#developer-quick-start).

---

## Developer Quick Start

*Use this section if you're joining an existing project that's already deployed.*

**Choose your development environment:**

* **Local Development**: Continue with the steps below
* **Dev Container**: See [Dev Container Setup](#dev-container-setup) for containerized development

### Prerequisites Check

Verify your local environment:

```bash
python --version    # 3.9-3.12
pip --version
gcloud version      # Google Cloud SDK
```

### Local Development (8 Steps)

#### Step 1: Set Up Python Environment

```bash
python -m venv .venv
source .venv/bin/activate  # On Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

#### Step 2: Configure Environment

```bash
cp infra/.env.example infra/.env
$EDITOR infra/.env    # Ask your team lead for the correct values
```

**💡 Key variables for developers:**

* `DBT_GCP_PROJECT_DEV` - Development project
* `DBT_BQ_LOCATION` - BigQuery location
* Your `DBT_USER` will be auto-generated from your gcloud authenticated email

#### Step 3: Authenticate with GCP

```bash
gcloud auth login
gcloud auth application-default login
```

#### Step 4: Load Environment

```bash
# Load environment variables and generate DBT_USER
source ./setup-env.sh
```

#### Step 5: Set Up Your Development Dataset

```bash
./infra/50-ensure-dev-datasets.sh
```

**✅ Success criteria:** Your personal dataset is created (e.g., `analytics_yourname`)

#### Step 6: Install dbt Dependencies

```bash
# Install packages defined in packages.yml
dbt deps
```

**✅ Success criteria:** Dependencies installed successfully (e.g., GA4 dbt package)

#### Step 7: Verify dbt Setup

```bash
# Test dbt connection
dbt debug
```

**✅ Success criteria:** `dbt debug` shows all connections OK

### VS Code Setup (Optional)

1. **Command Palette** → "Python: Select Interpreter" → Choose `.venv`
2. **Run/Debug:** Use built-in configurations for `dbt: debug`, `dbt: run`, `dbt: test`

**Note:** Remember to run `source ./setup-env.sh` in your terminal before using dbt commands directly in the terminal.

**🎉 Development Ready!** See [Daily Development Workflow](#daily-development-workflow) for your next steps.

---

## Dev Container Setup

*Use this section if you prefer containerized development with VS Code.*

### Prerequisites Check

Ensure you have:

```bash
# Required tools
docker --version        # Docker Desktop
```

**VS Code Extensions:**

* Dev Containers extension (`ms-vscode-remote.remote-containers`)

### Container Setup (3 Steps)

#### Step 1: Open in Container

```bash
# Clone and open in VS Code
git clone <your-repo-url>
cd <your-repo-name>
code .
```

When VS Code opens, click "**Reopen in Container**" when prompted, or use:

* `Ctrl+Shift+P` → "Dev Containers: Reopen in Container"

#### Step 2: Configure Environment

The dev container automatically:

* Installs dbt-core and dbt-bigquery from `requirements.txt`
* Sets `DBT_PROFILES_DIR=profiles`
* Installs pre-commit hooks
* **Generates `DBT_USER`** from your gcloud authenticated email (for dataset isolation)
* **Loads `infra/.env`** variables into terminal sessions

You still need to configure your project variables:

```bash
cp infra/.env.example infra/.env
# Edit infra/.env with your project values
```

**Environment Notes:**

* The container runs a setup script that provides the same environment setup as local development
* Your `DBT_USER` will be automatically generated from your gcloud email and sanitized for BigQuery dataset naming
* All `infra/.env` variables are available in both terminal and VS Code debug sessions

#### Step 3: Authenticate with Google Cloud

```bash
# In the container terminal
gcloud auth login
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
```

### Container Development

The dev container provides:

* **Debugging**: Use F5 or the Debug panel to run `dbt run`, `dbt test`, `dbt debug`
* **Integrated Terminal**: All dbt commands work directly
* **Extensions**: Python and dbt Power User extensions pre-installed

**Testing Your Setup:**

```bash
# Install dependencies first
dbt deps

# Test connection and run
dbt debug        # Should show all green checkmarks
dbt run --limit 1

# Verify environment is loaded
echo $DBT_USER   # Should show your sanitized username
echo $PROJECT_ID # Should show your GCP project
```

**Troubleshooting:**

* If `DBT_USER` is empty, restart the container to trigger the setup script
* If `infra/.env` variables aren't loaded, check that the file exists and is readable
* Environment setup logs appear in the container startup output

**🎉 Container Ready!** See [Daily Development Workflow](#daily-development-workflow) for your next steps.

---

## Daily Development Workflow

### Making Changes

```bash
# 1. Install/update dependencies (if packages.yml changed)
dbt deps

# 2. Create feature branch
git checkout -b feature/my-new-model

# 3. Make changes to models/
# Edit your .sql files...

# 4. Test changes locally
dbt build --select state:modified+

# 5. Compare dev vs prod data (optional)
dbt run-operation dev_prod_diff --args '{"table_name":"my_model", "limit": 100}'

# 6. Push and create PR
git push origin feature/my-new-model
gh pr create
```

### Common Commands

```bash
# Build only changed models and their dependencies
dbt build --select state:modified+

# Test everything
dbt test

# Generate docs locally
dbt docs generate --static
# Open target/index.html in browser

# Check data freshness
dbt source freshness
```

### Working with Data

* **Your data:** `analytics_yourname` dataset
* **Production data:** `analytics` dataset (read-only)
* **Compare environments:** Use the `dev_prod_diff` macro

---

## Troubleshooting

### Template Setup Issues

#### "Permission denied" during bootstrap

**Solution:** Ensure you have Project Owner role temporarily

```bash
# Check your permissions
(cd infra && ./check-operator-iam.sh)
```

#### "Bucket name already taken"

**Solution:** Change `DBT_DOCS_BUCKET` to something globally unique

```bash
# Edit infra/.env
DBT_DOCS_BUCKET=my-company-dbt-docs-$(date +%s)
```

#### GitHub secrets not set

**Solution:** Run the secrets script manually

```bash
(cd infra && ./25-set-github-secrets.sh)
```

### Developer Issues

#### `dbt debug` fails

**Solutions:**

1. Check authentication: `gcloud auth application-default login`
2. Verify project access: `gcloud projects describe YOUR_PROJECT_ID`
3. Ensure dataset exists: `(cd infra && ./50-ensure-dev-datasets.sh)`

#### "Dataset not found" error

**Solution:** Create your dev dataset

```bash
(cd infra && ./50-ensure-dev-datasets.sh)
```

#### VS Code not recognizing Python environment

**Solution:** Select the correct interpreter

1. **Cmd/Ctrl + Shift + P** → "Python: Select Interpreter"
2. Choose `.venv/bin/python`

---

## Complete Documentation

*The sections below provide comprehensive reference information.*

## Prerequisites

* Python 3.9–3.12 with pip (or pipx). Verify: `python --version`, `pip --version`.
* Google Cloud SDK installed (provides `gcloud`, `bq`, and `gcloud storage`).
* Docker (to build/push the dbt image).
* jq (JSON CLI used by infra scripts).
* GitHub CLI (optional; required if you want to auto-set GitHub Actions secrets via `infra/25-set-github-secrets.sh`).
* GCP access to create IAM, BigQuery datasets, Artifact Registry repos, Cloud Run Jobs, and Cloud Scheduler jobs.
* APIs: BigQuery, Artifact Registry, Cloud Run, Cloud Scheduler, IAM (enabled by `infra/10-bootstrap.sh` if not already).

## Script Index & Typical Order

Core flow (typical first run):

* [infra/10-bootstrap.sh](#infra-bootstrap-one-time-per-gcp-project) — Enable APIs; create SAs, Artifact Registry, datasets, docs bucket; set IAM.
* [infra/20-wif-github.sh](#infra-bootstrap-one-time-per-gcp-project) — Configure GitHub OIDC / Workload Identity Federation.
* [infra/25-set-github-secrets.sh](#infra-bootstrap-one-time-per-gcp-project) — Optional: set GitHub Actions repo secrets via gh.
* [infra/30-deploy-cloud-run-job.sh](#release-main-prod-container) — Create/update the Cloud Run Job (prod runner).
* [infra/40-schedule-prod-job.sh](#release-main-prod-container) — Create/update Cloud Scheduler trigger for the job.

Optional helpers (as needed):

* [infra/50-ensure-dev-datasets.sh](#developer-onboarding) — Ensure per‑developer datasets + IAM (reads infra/devs.txt; supports --grant-job-user).
* [infra/70-configure-docs-website.sh](#serve-dbt-docs-http) — Configure docs bucket website index; set PUBLIC=true for public read.
* [infra/80-deploy-docs-viewer.sh](#docs-viewer-cloud-run-iam-only) — Deploy private Cloud Run docs viewer service (reads index.html from GCS).
* [infra/81-grant-docs-viewer-access.sh](#docs-viewer-cloud-run-iam-only) — Grant run.invoker to users/groups for the docs viewer.
* [infra/85-ensure-notification-channels.sh](#monitoring) — Create/reuse Monitoring email channels; writes NOTIFICATION_CHANNELS.
* [infra/90-monitoring.sh](#monitoring) — Ensure alerting policies for Run Job, Scheduler, and BigQuery errors.
* [infra/15-artifacts-lifecycle.sh](#docs--artifacts) — Set GCS lifecycle on artifacts/docs bucket (e.g., delete objects >30 days).
* [infra/check-operator-iam.sh](#operator-iam-to-run-infra-scripts) — Check current operator’s project roles; helpful before running bootstrap.

Tip: 25/50/70/80/81/85/90/15 are optional and can be run any time after 10 (and when their prerequisites exist).

---

## Repo Layout

* `.github/workflows/ci.yml` — PR validation on ephemeral BigQuery dataset (Slim CI, deferral) ([Medium][2], [Klaviyo Engineering][3])
* `.github/workflows/release.yml` — Build & publish container → update Cloud Run Job → keep schedule in sync
* `Dockerfile`, `entrypoint.sh` — Containerized dbt runner (supports optional hooks & docs)
* `profiles/profiles.yml` — Env‑var driven dbt profiles for dev/ci/prod
* `models/` — Example models/tests (staging → marts)
* `scripts/` — CI helpers (create/drop dataset, Slim CI, compare template)
* `infra/` — One‑time GCP bootstrap (APIs, SAs, WIF/OIDC, datasets, Artifact Registry, Cloud Run Job, Scheduler)

  * Uses **Workload Identity Federation** for GitHub Actions (no long‑lived keys).

### Local Development (Detailed Reference)

The sections above provide quick-start guides. For detailed reference:

**Environment Setup:**

* Configure variables in `infra/.env` (copied from `infra/.env.example`)
* `setup-env.sh` loads `infra/.env`, sets `DBT_PROFILES_DIR=profiles`, and generates `DBT_USER` from your gcloud email
* Ensure the profile name in `profiles/profiles.yml` matches `dbt_project.yml` (profile: `dbt_gcloud`)

**Environment Variables:**

```bash
# Required
DBT_TARGET=dev
DBT_GCP_PROJECT_DEV=<your-dev-project>
DBT_BQ_LOCATION=US

# Optional overrides
# DBT_BQ_DATASET=analytics_${DBT_USER}
# DBT_MAX_BYTES_BILLED=
# DBT_JOB_EXECUTION_TIMEOUT_SEC=
```

> Tip: Use a per‑developer dataset like `${PROD_DATASET}_${DBT_USER}` so multiple engineers never collide. Per‑developer schemas/datasets are a common pattern. ([Datafold][1])

**Documentation Generation:**

```bash
dbt docs generate --static
# then open target/index.html
```

> The `--static` flag produces a single HTML doc you can host or share easily (no extra assets). See community write‑ups on hosting dbt docs as a static site. ([Hiflylabs][4], [Metaplane][5])

---

## Compare **Dev ↔ Prod**

Option A — ad‑hoc SQL in BigQuery UI:

* Use `scripts/compare_template.sql` (set `dev_project`, `dev_dataset`, `prod_project`, `prod_dataset`, and `table_name`).

Option B — parameterized macro or helper:

* Export `DBT_USER` so the chosen naming (`${PROD_DATASET}_${DBT_USER}`) is stable in dev.
* Run one of:

```
dbt run-operation dev_prod_diff --args '{"table_name":"fct_example", "limit": 100}'
dbt run-operation dev_prod_diff_for_model --args '{"model_name":"fct_example", "limit": 100}'
scripts/compare.sh fct_example [dev_project] [prod_project]
```

* Override defaults with args: `dev_project`, `prod_project`, `dev_dataset_prefix`, `prod_dataset`, `execute_query`.

CI PR summary:

* The PR workflow runs diffs on changed models and publishes:
  * Per‑model text files under the “data‑diff” artifact
  * A PR comment titled “DBT Data Diff Summary” with a table of row counts and diff counts
  * Set `DIFF_LIMIT` in CI to control how many differing rows are sampled in logs (default 200 in this template)

For deeper diffs, consider a **data‑diff** approach (row‑level compare) to verify parity between environments. ([Datafold][6])

### Schema Diff in CI

In addition to row/data diffs, the CI pipeline can generate a schema comparison between the PR’s ephemeral dataset and production for changed models:

* Produces per‑model reports under `schema_diff_reports/` with:
  * Column changes (added/removed/changed type/nullability)
  * Table type changes (TABLE ↔ VIEW)
  * Partitioning/clustering option changes
  * Movement detection (dataset/identifier changes via manifests)
* Writes a PR comment titled “dbt Schema Diff Summary”
* Generates `schema_diff_reports/orphans.md` listing prod relations not covered by dbt models/sources
* Controlled by env: `DBT_GCP_PROJECT_CI`, `DBT_BQ_DATASET`, `DBT_GCP_PROJECT_PROD`, `DBT_BQ_DATASET_PROD`, optional `SCHEMA_DIFF_PROD_DATASETS`

---

## CI (Pull Requests with GitHub Actions)

**Secrets required**

* `GCP_WIF_PROVIDER` — Workload Identity Federation provider resource
* `GCP_CI_SA_EMAIL` — CI runner service account email
* `GCP_PROJECT_CI` — GCP project to host ephemeral CI datasets
* `DBT_ARTIFACTS_BUCKET` — GCS bucket for manifests/docs

**Flow**

1. OIDC auth in GitHub Actions (no JSON keys). Ensure `permissions: id-token: write`.
2. Create ephemeral BigQuery dataset `ci_pr_<PR>_<runid>` (cleaned up at end). The bootstrap grants the CI service account `roles/bigquery.user` so it can create datasets. The workflow then hardens ACLs so only the CI service account is `WRITER` on the dataset (removes `projectWriters`); everyone else is read‑only.
3. **Slim CI**: `dbt build --select state:modified+ --defer --state <prod_artifacts>` so only changed nodes + dependents run, resolving upstream refs to prod objects. ([Medium][2], [Klaviyo Engineering][3])
4. Generate docs and upload to `gs://$DBT_ARTIFACTS_BUCKET/ci/...`.
5. Always drop the ephemeral dataset.

> These Slim CI patterns (state selector + deferral) are documented in community engineering posts and case studies. ([Klaviyo Engineering][3], [Medium][2])

Note on INT_DATASET:

* INT_DATASET is optional. If set, the bootstrap script will create a standing non‑prod dataset and grant the CI SA editor on it. If left empty, no integration dataset is created or bound; CI continues to use ephemeral per‑run datasets only. If your CI runs in a different GCP project than the one you bootstrapped, ensure `roles/bigquery.user` is granted to the CI SA in that CI project.

---

## Release (main → prod container)

**Secrets required**

* `GCP_WIF_PROVIDER`
* `GCP_PROD_SA_EMAIL` — prod runner SA
* `GCP_PROJECT_PROD` — prod project id
* `GCP_SCHEDULER_INVOKER_SA` — Scheduler invoker SA email

**Flow**

1. Build Docker image and push to **Artifact Registry** (requires `roles/artifactregistry.writer` on the repo).
2. Create/update **Cloud Run Job** (e.g., `dbt-prod`) with that image.
3. Create/update **Cloud Scheduler** trigger on the job (“Triggers” tab in the Job UI), or via CLI, to run on a cron schedule.
4. (Optional) Execute once after deploy to refresh prod artifacts.

Runtime defaults (Cloud Run Job):

* Runs `dbt build` then `dbt source freshness` by default in prod (set `RUN_FRESHNESS=false` to disable, or scope with `FRESHNESS_SELECT`).
* Uploads `manifest.json`, `run_results.json`, and `sources.json` to `gs://$DBT_ARTIFACTS_BUCKET/prod/`.
* Optionally generates docs (`GENERATE_DOCS=true`) and uploads `target/index.html` to `gs://$DBT_DOCS_BUCKET/index.html` (falls back to `DBT_ARTIFACTS_BUCKET` if `DBT_DOCS_BUCKET` is unset).

> Cloud Run **Jobs** are built for batch/ETL: they run to completion and can be executed on a schedule by Cloud Scheduler without standing up servers.

---

## Infra Bootstrap (one‑time per GCP project)

**Prereqs**: `gcloud`, `bq`, `jq`; logged in with `gcloud auth login` and billing enabled.

1. Copy and edit env

```bash
cp infra/.env.example infra/.env
$EDITOR infra/.env
```

2. Enable APIs, create SAs, **Artifact Registry** repo, datasets, docs bucket, and IAM:

```bash
(cd infra && ./10-bootstrap.sh)
```

* Artifact Registry repo creation uses `gcloud artifacts repositories create ...`.

Key env toggles (`infra/.env`):

* `INT_DATASET` (optional): create a standing non‑prod dataset; leave blank for ephemeral‑only CI.
* `MANAGE_DATASET_IAM` (default true): manage dataset grants; set false if dataset IAM/ACLs are centrally managed.
* `PROD_HARDEN_ACL` (default true): ensure only the prod runner SA can write to the prod dataset; everyone else is query‑only.
* `INT_HARDEN_ACL` (default true): ensure only the CI SA can write to the standing integration dataset.

3. Configure GitHub **OIDC / Workload Identity Federation** (no keys):

```bash
(cd infra && ./20-wif-github.sh)
```

* Put the printed `workload_identity_provider` and `service_account` into GitHub Secrets (`GCP_WIF_PROVIDER`, `GCP_CI_SA_EMAIL`).
* We rely on the official `google-github-actions/auth` Action; OIDC requires `permissions: id-token: write` in the workflow.

3a. Set GitHub Actions secrets automatically (optional helper):

```
(cd infra && ./25-set-github-secrets.sh)           # uses GITHUB_REPO from infra/.env
# or pass repo explicitly
(cd infra && ./25-set-github-secrets.sh your-org/your-repo)
```

This sets:

* `GCP_WIF_PROVIDER`, `GCP_CI_SA_EMAIL`, `GCP_PROJECT_CI`, `DBT_ARTIFACTS_BUCKET`, `DBT_DOCS_BUCKET`
* `GCP_PROD_SA_EMAIL`, `GCP_PROJECT_PROD`, `GCP_SCHEDULER_INVOKER_SA`

Notes:

* The script uses `gh secret set` and values from `infra/.env`. It derives `GCP_WIF_PROVIDER` using the same pool/provider IDs as `20-wif-github.sh` (default `github-pool`/`github-provider`).
* `DBT_ARTIFACTS_BUCKET` defaults to `DBT_DOCS_BUCKET` unless `DBT_ARTIFACTS_BUCKET` is already exported in your shell.

4. After the first image exists (from the release workflow) you can deploy/update the job & Scheduler locally if needed:

```bash
(cd infra && ./30-deploy-cloud-run-job.sh)
(cd infra && ./40-schedule-prod-job.sh)
```

* Scheduling Cloud Run **Jobs** can be done directly from the Job’s **Triggers** tab or with API/CLI; the console path is explicit in Google’s docs.

5. Notification channels (optional helper for alerts):

```bash
(cd infra && ./85-ensure-notification-channels.sh)          # creates/reuses channels and updates .env + writes helper env file
# specify emails explicitly (otherwise uses DEV_GROUP_EMAIL or your active gcloud account)
(cd infra && ./85-ensure-notification-channels.sh --email [email protected],[email protected])
# export into current shell: source the script (it also writes infra/.notification_channels.env)
source infra/85-ensure-notification-channels.sh
```

6. Create a developer dataset (optional helper):

```bash
(cd infra && ./50-ensure-dev-datasets.sh)                 # operator + optional infra/devs.txt
(cd scripts/utils && ./create-dev-dataset.sh user@example.com dbt_alice_dev)   # one-off
```

* BigQuery IAM tip: **BigQuery Job User** at project level to run jobs, plus dataset‑level roles to read/write the target dataset (least privilege).

---

## IAM & Security (minimal, least‑privilege)

* **CI SA**:

  * Project: `roles/bigquery.jobUser` to run jobs.
  * Dataset (CI dataset(s)): writer/editor as needed.
* **Prod SA** (Cloud Run Job runtime):

  * Project: `roles/bigquery.jobUser`
  * Prod datasets: writer/editor as needed.
* **Artifact Registry**:

  * GitHub build/publish needs `roles/artifactregistry.writer` on the target repo; runners log in via OIDC.
* **Scheduler → Cloud Run Job**:

  * Give the Scheduler’s SA permission to invoke the job trigger (use the UI “Add Scheduler Trigger” flow to wire this securely).

---

## Developer Onboarding

Ensure developers have a per‑dev dataset and the minimal IAM needed to work safely.

1. Optional: grant project‑level BigQuery Job User to a dev group once

   * Set `DEV_GROUP_EMAIL` in `infra/.env` (e.g., `data-devs@your-domain.com`).
   * Run `./infra/10-bootstrap.sh` (idempotent). This grants `roles/bigquery.jobUser` to the group.

   Alternatively, grant per-user Job User during dataset creation with `--grant-job-user`.

2. Add developers in `infra/devs.txt`

   * One entry per line: `email[,dataset]`. The dataset is optional.
   * If omitted, the script defaults to `${PROD_DATASET}_${short}`, where `short` is the email local-part lowercased and sanitized to `[a-z0-9_]`.

   Example `infra/devs.txt`:

   ```
   alice@example.com,analytics_alice
   bob@example.com
   # carol defaults to ${PROD_DATASET}_carol
   carol@example.com
   ```

3. Ensure datasets

   ```bash
   (cd infra && ./50-ensure-dev-datasets.sh)
   # or, to also grant project-level Job User per-user
   (cd infra && ./50-ensure-dev-datasets.sh --grant-job-user)
   ```

4. One-off: create a single dev dataset

   ```bash
   (cd scripts/utils && ./create-dev-dataset.sh dev@example.com [dataset] [--grant-job-user])
   ```

Notes:

* Datasets and IAM settings are idempotent; you can re-run safely after editing `infra/devs.txt`.
* Group-based Job User is recommended at scale. Use `--grant-job-user` for exceptions.

---

## Operator IAM (to run infra scripts)

The person/service running scripts in `infra/` needs elevated, temporary permissions to create resources and set IAM. Easiest is Project Owner during bootstrap; for least‑privilege, grant these roles to the operator and remove afterward:

* Project-wide roles:
  * `roles/serviceusage.serviceUsageAdmin` (enable required APIs)
  * `roles/iam.serviceAccountAdmin` (create service accounts)
  * `roles/iam.serviceAccountIamAdmin` (set IAM policy on service accounts)
  * `roles/iam.workloadIdentityPoolAdmin` (create/update WIF pool/provider)
  * `roles/artifactregistry.admin` (create Artifact Registry repo)
  * `roles/storage.admin` (create bucket + set IAM)
  * `roles/bigquery.admin` (create datasets + set dataset IAM)
  * `roles/run.admin` (create/update Cloud Run Jobs + set IAM)
  * `roles/cloudscheduler.admin` (create/update Scheduler jobs)
* On the specific service accounts created by bootstrap:
  * `roles/iam.serviceAccountUser` on the prod runner SA (required to deploy a Run Job with `--service-account`)
  * `roles/iam.serviceAccountUser` on the scheduler invoker SA (if you need to impersonate it during setup)

Notes:

* These are for the operator only. Runtime SAs (CI and Prod) use the minimal roles listed above in “IAM & Security”.
* Many orgs grant Project Owner to the bootstrapper, run `infra/10-bootstrap.sh` and `infra/20-wif-github.sh`, then revoke and keep least‑privilege going forward.
* Important: Project Owner does not implicitly include BigQuery dataset admin. To change dataset IAM (e.g., grant the CI/Prod SAs reader/editor on `analytics`), the operator needs `roles/bigquery.admin` (or dataset‑level ownership). If missing, `infra/10-bootstrap.sh` will warn with `bigquery.datasets.setIamPolicy` and continue.
* You can disable dataset IAM management entirely by setting `MANAGE_DATASET_IAM=false` in `infra/.env`. The bootstrap will then skip those bindings and avoid warnings in locked‑down environments.

Check your current permissions:

```
(cd infra && bash ./check-operator-iam.sh)
```

The script compares your active gcloud principal against the required project roles and flags any missing ones. It also suggests `serviceAccountUser` bindings on specific SAs if needed. It checks direct bindings; if you receive roles via a group, it may not detect that.

### Troubleshooting: dataset IAM warnings in bootstrap

If you see lines like:

```
[warn] Failed to set IAM on dataset dm-website-426721:analytics. Check your permissions (need bigquery.datasets.setIamPolicy). Continuing.
```

This means the operator does not have permission to modify dataset IAM. Options:

* Grant the operator `roles/bigquery.admin` temporarily and re‑run `infra/10-bootstrap.sh`.
* Have a privileged admin grant the CI SA `roles/bigquery.dataViewer` on prod datasets and the Prod SA `roles/bigquery.dataEditor`.
* Ignore the warnings if dataset IAM is managed centrally; the rest of bootstrap (APIs, SAs, bucket IAM, etc.) proceeds.

---

## Docs & Artifacts

* CI publishes `manifest.json` and optional static docs to your `DBT_ARTIFACTS_BUCKET`.
* For static docs, we use `dbt docs generate --static` and host a single HTML file if needed (see community examples of static hosting). ([Hiflylabs][4], [Metaplane][5])

---

## Serve dbt Docs (HTTP)

The job can generate a single-file site (`target/index.html`) via `dbt docs generate --static` and upload it to the docs bucket. You have a few options to view it over HTTP:

* Option A — Simple public website (fastest)
  * Make the docs bucket a static website and grant public read.
  * Configure and print URL:
    * `(cd infra && PUBLIC=true ./70-configure-docs-website.sh)`
    * Then open: `https://storage.googleapis.com/${DBT_DOCS_BUCKET}/index.html`
  * Caution: Public means world-readable. Use only if acceptable.

* Option B — Private access (no public read)
  * Keep the bucket private (default). View via Cloud Console (Storage > Buckets > your bucket > `index.html` > Open in browser) when authenticated.
  * For a private HTTP endpoint, consider a Cloud Run proxy or Load Balancer + CDN with IAM integration. Ask if you want me to add a tiny Cloud Run service that serves the file from GCS using the service account.

* Option C — Load Balancer + CDN (prod-grade)
  * Create an HTTPS Load Balancer with a backend bucket pointing to your docs bucket, enable Cloud CDN, and add a managed certificate for a custom domain (e.g., `docs.example.com`).
  * This keeps the bucket private to Google and exposes content via the edge proxy; can be combined with Identity-Aware Proxy (IAP) for auth.

Note: The infra bootstrap script creates the docs bucket but does not make it public. Use `infra/70-configure-docs-website.sh` to enable static website and optional public access.

### Docs Viewer (Cloud Run, IAM‑only)

For private, simple access without IAP or a load balancer, deploy a small Cloud Run service that reads `index.html` from your docs bucket:

1) Ensure the Docs Viewer service account exists and has read access (created by `infra/10-bootstrap.sh` as `DOCS_VIEWER_SA_ID`).
2) Build and deploy the service:

```
(cd infra && ./80-deploy-docs-viewer.sh)
```

3) Grant users/groups access to view (run.invoker):

```
(cd infra && ./81-grant-docs-viewer-access.sh group:[email protected])
```

4) Open the Cloud Run service URL printed by the deploy script.

Runtime envs:

* `DBT_DOCS_BUCKET` (required): bucket that contains `index.html`.
* `DOCS_INDEX_OBJECT` (optional): defaults to `index.html`.
* `DOCS_CACHE_CONTROL` (optional): default `public, max-age=60`.

Automatic upload on prod runs:

* If the prod job sets `GENERATE_DOCS=true` and `DBT_DOCS_BUCKET=<bucket>`, the dbt container uploads `target/index.html` to `gs://<bucket>/index.html` automatically after generation.

---

## Monitoring

Set up basic monitoring for failures across the stack using log‑based metrics and alerting policies.

* Metrics: `cloud_run_job_errors`, `cloud_run_job_failures` (text match), `cloud_scheduler_job_errors`, `bigquery_job_errors`.
* Policies: alert when count > 0 over 5 minutes; uses `gcloud beta/alpha monitoring policies`.
* Channels: optional but recommended via `infra/85-ensure-notification-channels.sh` (sets `NOTIFICATION_CHANNELS`).

Usage

* Create channels (optional):
  * `(cd infra && ./85-ensure-notification-channels.sh --email [email protected],[email protected])`
  * The script updates `infra/.env` and can export a helper file `.notification_channels.env`.
* Create metrics + policies:
  * `(cd infra && ./90-monitoring.sh)`
* Override names/regions (optional):
  * `JOB_NAME=dbt-prod-run SCHED_JOB_NAME=dbt-prod-nightly REGION=us-central1 SCHED_REGION=us-central1 (cd infra && ./90-monitoring.sh)`

Notes

* Requires an up‑to‑date `gcloud` with Monitoring alpha/beta commands.
* Safe to re‑run; existing metrics/policies are left in place.

## Operational Notes

* **BigQuery mapping**: In BigQuery, datasets are the logical containers for tables/views; this template uses dataset boundaries to isolate environments and developers.
* **Slim CI + deferral** keeps PR runs fast and realistic by resolving unchanged upstream refs to prod objects. Community case studies detail this approach and command flags. ([Medium][2], [Klaviyo Engineering][3])
* **Cloud Run Job timeouts**: Jobs are designed for long‑running work with configurable task timeouts (much longer than Cloud Run services’ request timeouts).
* **Docker auth to Artifact Registry**: If you push locally, configure Docker credential helper: `gcloud auth configure-docker <region>-docker.pkg.dev`.

---

## Next Steps

* Replace placeholder IDs in workflows and `infra/.env`.
* Decide on the dataset naming convention. This template uses `${PROD_DATASET}_${DBT_USER}` for dev by default.
* Add models/tests and any packages to `packages.yml`.
* Consider a formal **data diff** step in CI to compare dev vs prod tables on changed models. ([Datafold][6])

---

## Acknowledgements (Inspiration & References)

* **Per‑developer environments & environment strategy** — Datafold’s guide on dbt development environments. ([Datafold][1])
* **Slim CI with `state:modified+` & `--defer`** — Implementation notes and examples from melbdataguy and Klaviyo Engineering. ([Medium][2], [Klaviyo Engineering][3])
* **Data Diff Concept** — Overview of table‑level diffing for dev vs prod validation. ([Datafold][6])

---

### References

[1]: https://www.datafold.com/blog/how-to-setup-dbt-development-environments "Optimizing dbt development environments | Datafold"
[2]: https://melbdataguy.medium.com/implementing-ci-cd-for-dbt-core-with-bigquery-and-github-actions-f930d48a674b "Implementing CI/CD for dbt-core with BigQuery and Github Actions | by melbdataguy | Medium"
[3]: https://klaviyo.tech/continuous-integration-with-dbt-part-2-47c093a0548e "Continuous Integration with dbt (Part 2) | by Corey Angers | Klaviyo Engineering"
[4]: https://hiflylabs.com/blog/2023/3/16/dbt-docs-as-a-static-website?utm_source=chatgpt.com "dbt Docs as a Static Website"
[5]: https://www.metaplane.dev/blog/host-and-share-dbt-docs?utm_source=chatgpt.com "3 ways to host and share dbt docs"
[6]: https://www.datafold.com/blog/what-the-heck-is-data-diffing?utm_source=chatgpt.com "What the heck is data diffing?!"
