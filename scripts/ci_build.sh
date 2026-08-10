#!/usr/bin/env bash
set -euo pipefail

# CI build strategy (4-tier):
#   1. No model changes detected    → dbt parse only (syntax check)
#   2. Has state + model changes     → Slim CI (state:modified+ with --defer)
#   3. Has state, state selection fails → full build (fallback)
#   4. No state available            → full build
#
# Every `dbt build` invocation below excludes the `test` resource type:
# models are built without running dbt tests, and `dbt test` runs as a
# separate, non-blocking CI step afterward. This decouples the diff-gate
# (steps.dbt_build.outcome) from test outcome, so a single red data test no
# longer suppresses the data/schema diffs (see Risks & Trade-offs — this
# intentionally removes dbt's upstream test-blocking within a build).
# CI_SELECT / CI_DEFER are exported to $GITHUB_ENV so the downstream
# `dbt test` step can reuse the same model selection/defer state.

mkdir -p prod_state
HAS_STATE="false"

# Writes CI_SELECT / CI_DEFER to $GITHUB_ENV (when present) so the
# non-blocking `dbt test` step added after this one can reuse the same
# model selection/defer state that was used for the build.
export_ci_select_defer() {
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "CI_SELECT=${CI_SELECT:-}" >> "$GITHUB_ENV"
    echo "CI_DEFER=${CI_DEFER:-}" >> "$GITHUB_ENV"
  fi
}

echo "=== Slim CI State Detection ==="
echo "DBT_ARTIFACTS_BUCKET: ${DBT_ARTIFACTS_BUCKET:-<unset>}"
echo "Checking for production manifest at: gs://${DBT_ARTIFACTS_BUCKET:-<unset>}/prod/manifest.json"

if [[ -n "${DBT_ARTIFACTS_BUCKET:-}" ]]; then
  echo "Checking for production manifest..."
  for attempt in 1 2 3; do
    if gsutil ls "gs://${DBT_ARTIFACTS_BUCKET}/prod/manifest.json" >/dev/null 2>&1; then
      gsutil cp "gs://${DBT_ARTIFACTS_BUCKET}/prod/manifest.json" prod_state/manifest.json && break
    fi
    if [[ $attempt -lt 3 ]]; then
      echo "Attempt $attempt failed, retrying in $((2 ** attempt))s..."
      sleep $((2 ** attempt))
    fi
  done
  if [[ -f prod_state/manifest.json ]]; then
    # Validate JSON structure (not just file size)
    if python3 -c "import json; json.load(open('prod_state/manifest.json'))" 2>/dev/null; then
      HAS_STATE="true"
      echo "Valid production manifest downloaded; Slim CI will use state comparison and defer"
    else
      echo "Downloaded manifest is not valid JSON, treating as unavailable"
      rm -f prod_state/manifest.json
    fi
  else
    echo "Manifest download failed after 3 attempts"
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
    dbt build --target ci --exclude-resource-type test
    build_status=$?
    CI_SELECT=""; CI_DEFER=""
    export_ci_select_defer
    echo ""
    echo "=== Build Complete (full, state selection failed) ==="
    exit $build_status
  }

  echo ""
  echo "Starting Slim CI build with defer (models only; tests run separately)..."
  dbt build --target ci --select "state:modified+" --defer --state prod_state --exclude-resource-type test
  CI_SELECT="state:modified+"; CI_DEFER="--defer --state prod_state"
else
  echo "No production state available, running full build"
  echo "All models will be built from scratch"
  dbt build --target ci --exclude-resource-type test
  CI_SELECT=""; CI_DEFER=""
fi

echo ""
echo "=== Build Complete ==="

export_ci_select_defer
