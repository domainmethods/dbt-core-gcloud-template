#!/usr/bin/env bash
set -euo pipefail

# Required env: DBT_GCP_PROJECT_CI, DBT_BQ_LOCATION, DBT_BQ_DATASET
# Optional env: CI_SA_EMAIL (writer), MAKE_DATASET_READONLY (default true)

if ! bq --project_id="${DBT_GCP_PROJECT_CI}" --location="${DBT_BQ_LOCATION}" mk -d "${DBT_GCP_PROJECT_CI}:${DBT_BQ_DATASET}" 2>&1; then
  # Dataset may already exist from a previous run attempt; verify it exists
  if bq --project_id="${DBT_GCP_PROJECT_CI}" show "${DBT_GCP_PROJECT_CI}:${DBT_BQ_DATASET}" >/dev/null 2>&1; then
    echo "Dataset ${DBT_GCP_PROJECT_CI}:${DBT_BQ_DATASET} already exists; continuing."
  else
    echo "[error] Failed to create dataset ${DBT_GCP_PROJECT_CI}:${DBT_BQ_DATASET}" >&2
    exit 1
  fi
else
  echo "Created dataset ${DBT_GCP_PROJECT_CI}:${DBT_BQ_DATASET}"
fi

# Optionally make the dataset read-only for everyone except CI SA (writer)
MAKE_DATASET_READONLY=${MAKE_DATASET_READONLY:-true}
if [[ "$MAKE_DATASET_READONLY" == "true" ]]; then
  tmpRaw=$(mktemp)
  tmpJson=$(mktemp)
  newJson=$(mktemp)
  # Some environments print warnings to stdout before the JSON (e.g., auth scopes warnings).
  # Capture all output, then extract from the first '{' onward to ensure valid JSON for jq.
  if bq --project_id="${DBT_GCP_PROJECT_CI}" show --format=prettyjson "${DBT_BQ_DATASET}" >"$tmpRaw" 2>&1; then
    # Extract JSON starting from the first line that begins with '{'
    awk 'found || /^\s*\{/ {found=1} found {print}' "$tmpRaw" > "$tmpJson"
    if [[ -s "$tmpJson" ]] && head -n1 "$tmpJson" | grep -q "^\s*{"; then
      # Remove projectWriters, keep projectReaders/Owners, add CI SA as WRITER if provided
      jq --arg ci "${CI_SA_EMAIL:-}" '
        .access = (
          (.access // [])
          | map(select(.specialGroup != "projectWriters"))
          | (if ($ci|length) > 0 then . + [{"userByEmail": $ci, "role":"WRITER"}] else . end)
          | unique_by(.role, (.userByEmail // ""), (.groupByEmail // ""), (.specialGroup // ""))
        )
      ' "$tmpJson" > "$newJson"
      if ! diff -q "$tmpJson" "$newJson" >/dev/null 2>&1; then
        if bq --project_id="${DBT_GCP_PROJECT_CI}" update --source "$newJson" "${DBT_BQ_DATASET}" >/dev/null 2>&1; then
          echo "Hardened dataset ACLs for ${DBT_GCP_PROJECT_CI}:${DBT_BQ_DATASET} (read-only except CI writer)"
        else
          echo "[warn] Failed to update ACLs for ${DBT_GCP_PROJECT_CI}:${DBT_BQ_DATASET}" >&2
        fi
      fi
    else
      echo "[warn] Did not receive valid JSON from bq show; skipping ACL hardening" >&2
    fi
  fi
  rm -f "$tmpRaw" "$tmpJson" "$newJson"
fi
