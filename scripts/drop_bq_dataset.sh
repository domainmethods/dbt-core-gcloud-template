#!/usr/bin/env bash
set -euo pipefail

# Required env: DBT_GCP_PROJECT_CI, DBT_BQ_DATASET
# Gracefully handle unset vars (workflow cancellation before env is set)

if [[ -z "${DBT_GCP_PROJECT_CI:-}" || -z "${DBT_BQ_DATASET:-}" ]]; then
  echo "DBT_GCP_PROJECT_CI or DBT_BQ_DATASET not set; nothing to drop."
  exit 0
fi

bq rm -r -f -d "${DBT_GCP_PROJECT_CI}:${DBT_BQ_DATASET}" || true
echo "Dropped dataset ${DBT_GCP_PROJECT_CI}:${DBT_BQ_DATASET}"
