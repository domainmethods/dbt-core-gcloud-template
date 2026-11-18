#!/usr/bin/env bash
set -euo pipefail

# Requires a freshly parsed CI manifest and the workflow's GitHub run context.
source "$(dirname "$0")/lib/ci_datasets.sh"
require_ci_run_dataset
PROJECT="${DBT_GCP_PROJECT_CI:?Set DBT_GCP_PROJECT_CI}"
LOCATION="${DBT_BQ_LOCATION:-US}"
READONLY="${MAKE_DATASET_READONLY:-true}"

# Provision the schemas before dbt can create or write to them.
datasets=$(jq -er --arg project "$PROJECT" --arg base "$DBT_BQ_DATASET" '
  [$base, (
    .nodes[]
    | select(.database == $project and .config.materialized != "ephemeral")
    | select(.resource_type == "model" or .resource_type == "seed" or .resource_type == "snapshot"
             or (.resource_type == "test" and .config.store_failures == true))
    | .schema | strings
    | select(startswith($base + "_") and test("\\A[A-Za-z0-9_]+\\z"))
  )] | unique[]
' target/manifest.json)

acl_file=$(mktemp)
trap 'rm -f "$acl_file"' EXIT
while IFS= read -r dataset; do
  ref="${PROJECT}:$dataset"
  if bq --project_id="$PROJECT" --location="$LOCATION" mk -d \
      --label="dbt_ci_repository:$GITHUB_REPOSITORY_ID" --label="dbt_ci_run:$DBT_BQ_DATASET" "$ref" &&
    [[ "$READONLY" != true ]]; then
    continue
  fi

  # Only reuse an existing dataset if it belongs to this attempt and location.
  if ! metadata=$(owned_ci_dataset "$dataset" "$DBT_BQ_DATASET") ||
    ! jq -e --arg location "$LOCATION" '(.location | ascii_downcase) == ($location | ascii_downcase)' \
      <<< "$metadata" >/dev/null; then
    echo "[error] Could not create or verify ownership and location of $ref" >&2
    exit 1
  fi

  if [[ "$READONLY" == true ]]; then
    jq --arg ci "${CI_SA_EMAIL:-}" '{
      access: (
        (.access // [])
        | map(select(.specialGroup != "projectWriters"))
        | {"userByEmail": $ci, "role": "WRITER"} as $entry
        | if $ci == "" or any(.[]; . == $entry) then . else . + [$entry] end
      )
    }' <<< "$metadata" > "$acl_file"
    if ! bq --project_id="$PROJECT" update --source "$acl_file" "$ref" >/dev/null 2>&1; then
      echo "[warn] Failed to update ACLs for $ref" >&2
    fi
  fi
done <<< "$datasets"
