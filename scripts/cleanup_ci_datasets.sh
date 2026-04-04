#!/usr/bin/env bash
set -euo pipefail

# Cleans up orphaned CI datasets (ci_pr_*) older than MAX_AGE_HOURS.
# Usage:
#   DBT_GCP_PROJECT_CI=my-project scripts/cleanup_ci_datasets.sh
#   DRY_RUN=true DBT_GCP_PROJECT_CI=my-project scripts/cleanup_ci_datasets.sh
#
# Optional env:
#   MAX_AGE_HOURS  — delete datasets older than this (default: 24)
#   DRY_RUN        — if "true", list but don't delete (default: false)
#   DATASET_PREFIX — prefix to match (default: ci_pr_)

PROJECT="${DBT_GCP_PROJECT_CI:?Set DBT_GCP_PROJECT_CI}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-24}"
DRY_RUN="${DRY_RUN:-false}"
PREFIX="${DATASET_PREFIX:-ci_pr_}"

cutoff_epoch=$(date -d "-${MAX_AGE_HOURS} hours" +%s 2>/dev/null || date -v-${MAX_AGE_HOURS}H +%s)

echo "Cleaning CI datasets in ${PROJECT} with prefix '${PREFIX}' older than ${MAX_AGE_HOURS}h"
echo "Cutoff: $(date -d "@${cutoff_epoch}" -Is 2>/dev/null || date -r "${cutoff_epoch}" -Iseconds)"
[[ "$DRY_RUN" == "true" ]] && echo "DRY RUN — no datasets will be deleted"

deleted=0
skipped=0

# List datasets, handle pagination automatically via bq ls
while IFS= read -r dataset_id; do
  [[ -z "$dataset_id" ]] && continue
  [[ "$dataset_id" != ${PREFIX}* ]] && continue

  # Get dataset creation time
  created_ms=$(bq --project_id="$PROJECT" show --format=json "${PROJECT}:${dataset_id}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('creationTime','0'))" 2>/dev/null || echo "0")

  if [[ "$created_ms" == "0" ]]; then
    echo "  [skip] ${dataset_id} — could not read creation time"
    skipped=$((skipped + 1))
    continue
  fi

  created_epoch=$((created_ms / 1000))
  if [[ $created_epoch -lt $cutoff_epoch ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  [dry-run] would delete: ${dataset_id}"
    else
      echo "  [delete] ${dataset_id}"
      bq rm -r -f -d "${PROJECT}:${dataset_id}" || echo "  [warn] failed to delete ${dataset_id}"
    fi
    deleted=$((deleted + 1))
  else
    skipped=$((skipped + 1))
  fi
done < <(bq ls --project_id="$PROJECT" --format=json --max_results=1000 2>/dev/null \
  | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for ds in data:
        ref = ds.get('datasetReference', {})
        print(ref.get('datasetId', ''))
except: pass
")

echo "Done. Deleted: ${deleted}, Skipped: ${skipped}"
