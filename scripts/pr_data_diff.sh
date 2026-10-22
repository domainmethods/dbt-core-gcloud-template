#!/usr/bin/env bash
set -euo pipefail

# Generates simple count + EXCEPT DISTINCT diffs for changed models in a PR.
# Assumes CI already created and built into $DBT_BQ_DATASET in $DBT_GCP_PROJECT_CI.
# Requires dbt to be installed and authenticated to BigQuery.

ARTIFACT_DIR=${ARTIFACT_DIR:-diff_reports}
DIFF_LIMIT=${DIFF_LIMIT:-100}
mkdir -p "$ARTIFACT_DIR"

DEV_PROJECT=${DBT_GCP_PROJECT_CI:?set DBT_GCP_PROJECT_CI}
DEV_DATASET=${DBT_BQ_DATASET:?set DBT_BQ_DATASET}
PROD_PROJECT=${DBT_GCP_PROJECT_PROD:-}

# Docs/config-only PRs change no models — skip the diff entirely (no gsutil, no dbt).
if [[ "${HAS_MODEL_CHANGES:-true}" == "false" ]]; then
  echo "No dbt model changes detected in this PR. No models to diff."
  exit 0
fi

# Pull prod manifest if not already present (optional, CI workflow usually does this earlier)
echo "=== Data Diff State Detection ==="
echo "Checking for production manifest for model selection..."
if [[ -n "${DBT_ARTIFACTS_BUCKET:-}" && ! -f prod_state/manifest.json ]]; then
  mkdir -p prod_state
  if gsutil ls "gs://${DBT_ARTIFACTS_BUCKET}/prod/manifest.json" >/dev/null 2>&1; then
    gsutil cp "gs://${DBT_ARTIFACTS_BUCKET}/prod/manifest.json" prod_state/manifest.json
    echo "✓ Pulled prod manifest for state selection"
  else
    echo "⚠ No production manifest found for state selection"
  fi
elif [[ -f prod_state/manifest.json ]]; then
  manifest_size=$(wc -c < prod_state/manifest.json)
  echo "✓ Production manifest already exists (${manifest_size} bytes)"
else
  echo "⚠ No DBT_ARTIFACTS_BUCKET configured for state selection"
fi

echo ""
echo "=== Model Selection ==="
if [[ -n "${DIFF_SELECT:-}" ]]; then
  echo "Using git-diff scope: ${DIFF_SELECT}"
  # DIFF_SELECT is intentionally unquoted so multiple 'name+' tokens expand as separate args.
  mapfile -t MODELS < <(dbt ls --select ${DIFF_SELECT} --resource-type model --output name --quiet 2>/dev/null || true)
elif [[ -f prod_state/manifest.json ]]; then
  echo "Using state comparison to find changed models..."
  mapfile -t MODELS < <(dbt ls --select "state:modified+" --state prod_state --resource-type model --output name --quiet 2>/dev/null || true)
else
  echo "No git scope and no production manifest; selecting all models..."
  mapfile -t MODELS < <(dbt ls --resource-type model --output name --quiet 2>/dev/null || true)
fi
echo "Selected ${#MODELS[@]} model(s)."

if (( ${#MODELS[@]} == 0 )); then
  echo "No models to diff."
  exit 0
fi

echo ""
echo "=== Running Data Diffs ==="
echo "Diffing ${#MODELS[@]} model(s) with limit=${DIFF_LIMIT}"

for m in "${MODELS[@]}"; do
  safe="${m//\//_}"
  out="${ARTIFACT_DIR}/${safe}.txt"
  echo "== ${m} ==" | tee "$out"
  # Produce and print results. We pass the CI dataset explicitly.
  # Capture both stdout and stderr to ensure we get SUMMARY lines
  echo "Running dbt operation for ${m}..."
  output=$(dbt run-operation dev_prod_diff_for_model \
    --args "{model_name: '${m}', dev_project: '${DEV_PROJECT}', prod_project: '${PROD_PROJECT}', dev_dataset: '${DEV_DATASET}', limit: ${DIFF_LIMIT}}" \
    2>&1 || true)

  # Print output to console
  echo "$output"

  # Write output to file
  echo "$output" >> "$out"
  echo >> "$out"
done

echo "Wrote diff reports to ${ARTIFACT_DIR}/"

# Build markdown summary from SUMMARY lines
SUMMARY_MD="${ARTIFACT_DIR}/summary.md"
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
echo "# dbt Data Diff Summary" > "$SUMMARY_MD"
echo >> "$SUMMARY_MD"
echo "_Generated: ${TIMESTAMP}_" >> "$SUMMARY_MD"
echo >> "$SUMMARY_MD"
echo "| Model | Dev Rows | Prod Rows | Dev-Not-In-Prod | Prod-Not-In-Dev | Status |" >> "$SUMMARY_MD"
echo "|---|---:|---:|---:|---:|---:|" >> "$SUMMARY_MD"

# Process SUMMARY lines from diff reports
if ls ${ARTIFACT_DIR}/*.txt >/dev/null 2>&1; then
  # Check if SUMMARY lines exist
  if grep -q 'SUMMARY|' ${ARTIFACT_DIR}/*.txt 2>/dev/null; then
    grep -h 'SUMMARY|' ${ARTIFACT_DIR}/*.txt | while IFS='|' read -r _ t dev prod dnp pnd; do
      model="${t#table=}"
      dev_rows="${dev#dev=}"
      prod_rows="${prod#prod=}"
      dnp_rows="${dnp#dev_not_in_prod=}"
      pnd_rows="${pnd#prod_not_in_dev=}"

      # Handle special cases
      if [[ "${prod_rows}" == "NEW_MODEL" ]]; then
        status="🆕 New Model"
        prod_rows="N/A"
        dnp_rows="N/A"
        pnd_rows="N/A"
      elif [[ "${prod_rows}" == "AUTH_ERROR" ]]; then
        status="⚠️ Auth Error"
        prod_rows="Error"
        dnp_rows="Error"
        pnd_rows="Error"
      else
        status="📊 Updated"
      fi

      echo "| ${model} | ${dev_rows} | ${prod_rows} | ${dnp_rows} | ${pnd_rows} | ${status} |" >> "$SUMMARY_MD"
    done
    echo "Summary written to ${SUMMARY_MD}"
  else
    echo "No SUMMARY lines found in diff reports" >> "$SUMMARY_MD"
  fi
else
  echo "No diff report files found" >> "$SUMMARY_MD"
fi

# Ensure script exits successfully
exit 0
