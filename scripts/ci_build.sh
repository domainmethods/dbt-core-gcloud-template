#!/usr/bin/env bash
set -euo pipefail

# CI build strategy (4-tier):
#   1. No model changes detected    → dbt parse only (syntax check)
#   2. Has state + model changes     → Slim CI (state:modified+ with --defer)
#   3. Has state, state selection fails → full build (fallback)
#   4. No state available            → full build

mkdir -p prod_state
HAS_STATE="false"

echo "=== Slim CI State Detection ==="
echo "DBT_ARTIFACTS_BUCKET: ${DBT_ARTIFACTS_BUCKET:-<unset>}"
echo "Checking for production manifest at: gs://${DBT_ARTIFACTS_BUCKET:-<unset>}/prod/manifest.json"

if [[ -n "${DBT_ARTIFACTS_BUCKET:-}" ]]; then
  if gsutil ls "gs://${DBT_ARTIFACTS_BUCKET}/prod/manifest.json" >/dev/null 2>&1; then
    echo "Production manifest found, downloading..."
    gsutil cp "gs://${DBT_ARTIFACTS_BUCKET}/prod/manifest.json" prod_state/manifest.json
    if [[ -f prod_state/manifest.json ]]; then
      manifest_size=$(wc -c < prod_state/manifest.json)
      echo "Successfully downloaded manifest (${manifest_size} bytes)"
      if [[ ${manifest_size} -gt 100 ]]; then
        HAS_STATE="true"
        echo "Slim CI will use state comparison and defer"
      else
        echo "Downloaded manifest is too small (${manifest_size} bytes), treating as unavailable"
      fi
    else
      echo "Manifest download failed — file not found after copy"
    fi
  else
    echo "No production manifest found at gs://${DBT_ARTIFACTS_BUCKET}/prod/manifest.json"
  fi
else
  echo "DBT_ARTIFACTS_BUCKET not set, skipping production manifest download"
fi

dbt deps

echo ""
echo "=== dbt Build Strategy ==="

# Tier 1: No model changes → parse only
if [[ "${HAS_MODEL_CHANGES:-true}" == "false" ]]; then
  echo "No dbt model changes detected in this PR. Running parse-only validation."
  dbt parse --target ci
  echo ""
  echo "=== Parse Complete (no model changes) ==="
  exit 0
fi

# Tier 2-4: Model changes detected, build required
if [[ "${HAS_STATE}" == "true" ]]; then
  echo "Using Slim CI with state comparison and defer"
  echo "Checking which models dbt detects as changed..."

  echo "Models selected by state:modified+:"
  dbt ls --select "state:modified+" --state prod_state --resource-type model --output name --target ci || {
    echo "Error running dbt ls with state selection, falling back to full build"
    echo "Running full build due to state selection error"
    dbt build --target ci
    echo ""
    echo "=== Build Complete (full, state selection failed) ==="
    exit $?
  }

  echo ""
  echo "Starting Slim CI build with defer..."
  dbt build --target ci --select "state:modified+" --defer --state prod_state
else
  echo "No production state available, running full build"
  echo "All models will be built from scratch"
  dbt build --target ci
fi

echo ""
echo "=== Build Complete ==="
