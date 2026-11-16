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
SCHED_SA_EMAIL="${SCHEDULER_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

# Use docs bucket as artifacts bucket by default
ARTIFACTS_BUCKET="${DBT_ARTIFACTS_BUCKET:-${DBT_DOCS_BUCKET}}"

declare -A secrets
secrets=(
  [GCP_WIF_PROVIDER]="$WIF_PROVIDER"
  [GCP_CI_SA_EMAIL]="$CI_SA_EMAIL"
  [GCP_PROJECT_CI]="$CI_PROJECT_ID"
  [DBT_ARTIFACTS_BUCKET]="$ARTIFACTS_BUCKET"
  [DBT_DOCS_BUCKET]="$DBT_DOCS_BUCKET"
  [GCP_PROD_SA_EMAIL]="$PROD_SA_EMAIL"
  [GCP_PROJECT_PROD]="$PROD_PROJECT_ID"
  [GCP_SCHEDULER_INVOKER_SA]="$SCHED_SA_EMAIL"
  # Deployment coordinates for workflows
  [GCP_REGION]="$REGION"
  [GCP_SCHED_REGION]="${SCHED_REGION:-$REGION}"
  # Nightly cron for release.yml; empty keeps its 06:00 UTC default (#64)
  [SCHED_CRON]="${SCHED_CRON:-}"
  [AR_REPO]="$AR_REPO"
  [IMAGE_NAME]="$IMAGE_NAME"
  # dbt runtime envs
  [PROD_DATASET]="$PROD_DATASET"
  [BQ_LOCATION]="$BQ_LOCATION"
  # Secret Manager mappings for release.yml's --set-secrets (#32); names only, no values
  [PROD_SECRETS]="${PROD_SECRETS:-}"
)

# Optional values: empty in .env means "use the workflow's default", so a secret
# left over from an earlier run would override it. Delete those instead of skipping.
OPTIONAL_SECRETS=" SCHED_CRON PROD_SECRETS "

for key in "${!secrets[@]}"; do
  val="${secrets[$key]}"
  if [[ -z "$val" && "$OPTIONAL_SECRETS" == *" $key "* ]]; then
    if out=$(gh secret delete "$key" -R "$GITHUB_REPO" 2>&1); then
      echo "Deleted secret $key (empty in .env)"
    elif [[ "$out" == *"404"* ]]; then
      echo "Skipping $key (empty; $key not set on GitHub)" >&2
    else
      echo "$out" >&2
      exit 1
    fi
    continue
  fi
  if [[ -z "$val" ]]; then
    echo "Skipping $key (empty)" >&2
    continue
  fi
  echo "Setting secret $key"
  gh secret set "$key" -R "$GITHUB_REPO" --body "$val" >/dev/null
done

echo "Done. Verify with: gh secret list -R $GITHUB_REPO"
