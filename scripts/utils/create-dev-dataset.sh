#!/usr/bin/env bash
set -euo pipefail

# Create or ensure a developer BigQuery dataset and dataset-level IAM.
# Usage: create-dev-dataset.sh <email> [dataset] [--grant-job-user]
#
# - If [dataset] is omitted, defaults to "analytics_${short}", where
#   short is the email local-part lowercased with non-alnum replaced by '_'.
# - Grants roles/bigquery.dataEditor on the dataset to the user.
# - Grants roles/bigquery.dataViewer on the dataset to CI and Prod service accounts.
# - With --grant-job-user, grants roles/bigquery.jobUser on the project to the user.

ROOT_DIR=$(cd "$(dirname "$0")"/../.. && pwd)
cd "$ROOT_DIR"

source infra/.env
source scripts/lib/bigquery_acl.sh

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <developer_email> [dataset] [--grant-job-user]" >&2
  exit 1
fi

DEV_EMAIL="$1"; shift || true
REQ_DATASET="${1:-}"
if [[ -n "${1:-}" && "${1:-}" != --* ]]; then shift || true; fi

GRANT_JOB_USER=0
for arg in "$@"; do
  case "$arg" in
    --grant-job-user) GRANT_JOB_USER=1 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# Tools
command -v gcloud >/dev/null || { echo "gcloud not found"; exit 1; }
command -v bq >/dev/null || { echo "bq not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }

# Derive default dataset name if not provided
localpart="${DEV_EMAIL%@*}"
short=$(printf '%s' "$localpart" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
DEV_DS="${REQ_DATASET:-analytics_${short}}"

info(){ echo "[info] $*"; }

# Ensure dataset exists
if bq --location="${BQ_LOCATION}" show --format=none "${PROJECT_ID}:${DEV_DS}" >/dev/null 2>&1; then
  info "Dataset exists: ${DEV_DS}"
else
  info "Creating dataset: ${DEV_DS}"
  bq --location="${BQ_LOCATION}" mk -d --description "Dev dataset for ${DEV_EMAIL}" "${PROJECT_ID}:${DEV_DS}"
fi

CI_SA_EMAIL="${CI_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
PROD_SA_EMAIL="${PROD_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
add_dataset_acl_entry "${PROJECT_ID}:${DEV_DS}" WRITER "${DEV_EMAIL}"
add_dataset_acl_entry "${PROJECT_ID}:${DEV_DS}" READER "${CI_SA_EMAIL}"
add_dataset_acl_entry "${PROJECT_ID}:${DEV_DS}" READER "${PROD_SA_EMAIL}"

if (( GRANT_JOB_USER == 1 )); then
  if gcloud projects get-iam-policy "${PROJECT_ID}" --format=json | jq -e --arg m "user:${DEV_EMAIL}" '.bindings[]? | select(.role=="roles/bigquery.jobUser") | .members[]? | select(.==$m)' >/dev/null 2>&1; then
    info "Project IAM already set: roles/bigquery.jobUser -> user:${DEV_EMAIL}"
  else
    info "Granting roles/bigquery.jobUser to user:${DEV_EMAIL}"
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
      --member="user:${DEV_EMAIL}" \
      --role="roles/bigquery.jobUser" >/dev/null
  fi
fi

echo "Created/updated dev dataset ${DEV_DS} for ${DEV_EMAIL}."
