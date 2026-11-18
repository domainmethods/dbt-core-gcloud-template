#!/usr/bin/env bash
set -euo pipefail

# Required env: DBT_GCP_PROJECT_CI, DBT_BQ_DATASET
# Gracefully handle unset vars (workflow cancellation before env is set)

if [[ -z "${DBT_GCP_PROJECT_CI:-}" || -z "${DBT_BQ_DATASET:-}" ]]; then
  echo "DBT_GCP_PROJECT_CI or DBT_BQ_DATASET not set; nothing to drop."
  exit 0
fi

exec bash "$(dirname "$0")/cleanup_ci_datasets.sh" --current-run
