#!/usr/bin/env bash
set -euo pipefail

# Sweep old datasets owned by this GitHub repository. For a manual sweep, set
# DBT_GCP_PROJECT_CI and GITHUB_REPOSITORY_ID. DRY_RUN=true previews removals.
# MAX_AGE_HOURS (default: 24) and DATASET_PREFIX (default: ci_pr_) narrow the sweep.
source "$(dirname "$0")/lib/ci_datasets.sh"
PROJECT="${DBT_GCP_PROJECT_CI:?Set DBT_GCP_PROJECT_CI}"
require_ci_repository
filter="labels.dbt_ci_repository:$GITHUB_REPOSITORY_ID"
run=""

case "${1:-}" in
  --current-run)
    require_ci_run_dataset
    run="$DBT_BQ_DATASET"
    prefix="$run"
    filter+=" labels.dbt_ci_run:$run"
    dry_run=false
    echo "Cleaning datasets owned by $run in $PROJECT"
    ;;
  "")
    age="${MAX_AGE_HOURS:-24}"
    if [[ ! "$age" =~ ^[0-9]+$ ]]; then
      echo "[error] MAX_AGE_HOURS must be a nonnegative integer" >&2
      exit 1
    fi
    cutoff=$(date -d "-$age hours" +%s 2>/dev/null || date -v-"${age}"H +%s)
    cutoff_ms=$((cutoff * 1000))
    prefix="${DATASET_PREFIX:-ci_pr_}"
    dry_run="${DRY_RUN:-false}"
    echo "Sweeping owned CI datasets in $PROJECT with prefix '$prefix' older than ${age}h"
    ;;
  *)
    echo "[error] Unknown cleanup mode: $1" >&2
    exit 1
    ;;
esac

dataset_ids=$(bq --project_id="$PROJECT" ls --format=json --max_results=10000 --filter="$filter" \
  | jq -r --arg project "$PROJECT" --arg prefix "$prefix" '
      .[]
      | .datasetReference
      | select(.projectId == $project)
      | .datasetId | strings
      | select(startswith($prefix) and test("\\A[A-Za-z0-9_]+\\z"))')

deleted=0
failed=0
while IFS= read -r dataset; do
  [[ -z "$dataset" ]] && continue
  if ! metadata=$(owned_ci_dataset "$dataset" "$run" 2>/dev/null); then
    echo "  [skip] $dataset (ownership could not be verified)"
    continue
  fi
  if [[ -z "$run" ]] && ! jq -e --argjson cutoff "$cutoff_ms" '
    (.creationTime | tonumber?) as $created | $created > 0 and $created < $cutoff
  ' <<< "$metadata" >/dev/null; then
    continue
  fi
  if [[ "$dry_run" == true ]]; then
    echo "  [dry-run] would delete: $dataset"
  elif bq --project_id="$PROJECT" rm -r -f -d "${PROJECT}:$dataset"; then
    echo "  [deleted] $dataset"
    deleted=$((deleted + 1))
  else
    echo "  [error] Failed to delete $dataset" >&2
    failed=$((failed + 1))
  fi
done <<< "$dataset_ids"

echo "Done. Deleted: $deleted, Failed: $failed"
[[ "$failed" -eq 0 ]]
