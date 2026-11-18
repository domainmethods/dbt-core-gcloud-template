#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required. Install: https://cli.github.com/" >&2
  exit 2
fi

# Determine repo to target
REPO_ARG="${1:-}"
if [[ -n "$REPO_ARG" ]]; then
  GITHUB_REPO="$REPO_ARG"
fi
if [[ -z "${GITHUB_REPO:-}" ]]; then
  # Try to detect current repo
  if gh repo view --json nameWithOwner -q .nameWithOwner >/dev/null 2>&1; then
    GITHUB_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  else
    echo "Set GITHUB_REPO in infra/.env or pass as first arg: owner/repo" >&2
    exit 1
  fi
fi

echo "Setting secrets on repo: $GITHUB_REPO"

# Allow overrides for CI/PROD projects; default to PROJECT_ID
CI_PROJECT_ID="${CI_PROJECT_ID:-${PROJECT_ID}}"
PROD_PROJECT_ID="${PROD_PROJECT_ID:-${PROJECT_ID}}"

# Pool/Provider IDs used by 20-wif-github.sh
POOL_ID="${POOL_ID:-github-pool}"
PROVIDER_ID="${PROVIDER_ID:-github-provider}"

WIF_PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"
CI_SA_EMAIL="${CI_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
PROD_SA_EMAIL="${PROD_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
SCHED_SA_EMAIL="${SCHEDULER_SA_ID}@${PROD_PROJECT_ID}.iam.gserviceaccount.com"

# Use docs bucket as artifacts bucket by default
ARTIFACTS_BUCKET="${DBT_ARTIFACTS_BUCKET:-${DBT_DOCS_BUCKET}}"

# Optional values: empty in .env means "use the workflow's default", so a secret
# left over from an earlier run would override it. Delete those instead of skipping.
OPTIONAL_SECRETS=" SCHED_CRON GENERATE_DOCS RUN_FRESHNESS FRESHNESS_SELECT DBT_MAX_BYTES_BILLED DBT_BQ_PRIORITY DBT_JOB_EXECUTION_TIMEOUT_SEC "

# One call per secret instead of an associative array: `declare -A` needs bash 4,
# and macOS ships /bin/bash 3.2, which `#!/usr/bin/env bash` picks up by default.
set_secret() {
  local key=$1 val=$2 out
  if [[ -z "$val" && "$OPTIONAL_SECRETS" == *" $key "* ]]; then
    if out=$(gh secret delete "$key" -R "$GITHUB_REPO" 2>&1); then
      echo "Deleted secret $key (empty in .env)"
    elif [[ "$out" == *"404"* ]]; then
      echo "Skipping $key (empty; $key not set on GitHub)" >&2
    else
      echo "$out" >&2
      exit 1
    fi
    return 0
  fi
  if [[ -z "$val" ]]; then
    echo "Skipping $key (empty)" >&2
    return 0
  fi
  echo "Setting secret $key"
  gh secret set "$key" -R "$GITHUB_REPO" --body "$val" >/dev/null
}

set_secret GCP_WIF_PROVIDER "$WIF_PROVIDER"
set_secret GCP_CI_SA_EMAIL "$CI_SA_EMAIL"
set_secret GCP_PROJECT_CI "$CI_PROJECT_ID"
set_secret DBT_ARTIFACTS_BUCKET "$ARTIFACTS_BUCKET"
set_secret DBT_DOCS_BUCKET "$DBT_DOCS_BUCKET"
set_secret GCP_PROD_SA_EMAIL "$PROD_SA_EMAIL"
set_secret GCP_PROJECT_PROD "$PROD_PROJECT_ID"
set_secret GCP_SCHEDULER_INVOKER_SA "$SCHED_SA_EMAIL"
# Deployment coordinates for workflows
set_secret GCP_REGION "$REGION"
set_secret GCP_SCHED_REGION "${SCHED_REGION:-$REGION}"
# Nightly cron for release.yml; empty keeps its 06:00 UTC default (#64)
set_secret SCHED_CRON "${SCHED_CRON:-}"
set_secret AR_REPO "$AR_REPO"
set_secret IMAGE_NAME "$IMAGE_NAME"
# dbt runtime envs
set_secret PROD_DATASET "$PROD_DATASET"
set_secret BQ_LOCATION "$BQ_LOCATION"
# Initial Cloud Run Job settings for release-first installs
set_secret GENERATE_DOCS "${GENERATE_DOCS:-}"
set_secret RUN_FRESHNESS "${RUN_FRESHNESS:-}"
set_secret FRESHNESS_SELECT "${FRESHNESS_SELECT:-}"
set_secret DBT_MAX_BYTES_BILLED "${DBT_MAX_BYTES_BILLED:-}"
set_secret DBT_BQ_PRIORITY "${DBT_BQ_PRIORITY:-}"
set_secret DBT_JOB_EXECUTION_TIMEOUT_SEC "${DBT_JOB_EXECUTION_TIMEOUT_SEC:-}"

echo "Done. Verify with: gh secret list -R $GITHUB_REPO"
