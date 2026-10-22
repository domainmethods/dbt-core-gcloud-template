#!/usr/bin/env bash
set -euo pipefail

# CI build strategy (git-diff-scoped):
#   1. No model changes detected                     → dbt parse only (syntax check)
#   2. No production manifest available               → full build (no --defer; cannot
#                                                        safely scope without state)
#   3. Manifest available, git-diff scope only         → build "$BUILD_SELECT" --defer
#                                                        (unchanged ancestors defer to prod)
#   4. Manifest available, macro/config change alongside
#      model changes                                   → union "$BUILD_SELECT state:modified+"
#                                                        --defer
#   5. Manifest available, macro/config/YAML-only change
#      (no scoped node)                                 → state:modified+ --defer
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

# No dbt model changes → parse only (docs-only)
if [[ "${HAS_MODEL_CHANGES:-true}" == "false" ]]; then
  echo "No dbt model changes detected in this PR. Running parse-only validation."
  dbt parse --target ci
  echo ""
  echo "=== Parse Complete (no model changes) ==="
  exit 0
fi

if [[ "${HAS_STATE}" != "true" ]]; then
  # No prod manifest → cannot defer safely → full build.
  echo "No production state available, running full build"
  dbt build --target ci --exclude-resource-type test
  CI_SELECT=""; CI_DEFER=""
elif [[ "${NEEDS_FALLBACK:-false}" == "false" && -n "${BUILD_SELECT:-}" ]]; then
  # Git-diff scoped build; unchanged ancestors defer to prod (build scope == diff scope).
  echo "Strategy: git-diff scoped build — ${BUILD_SELECT}"
  dbt build --target ci --select "${BUILD_SELECT}" --defer --state prod_state --exclude-resource-type test
  CI_SELECT="${BUILD_SELECT}"; CI_DEFER="--defer --state prod_state"
elif [[ "${NEEDS_FALLBACK:-false}" == "true" && -n "${BUILD_SELECT:-}" ]]; then
  # Macro/config change alongside model changes → union git scope with state:modified+.
  SEL="${BUILD_SELECT} state:modified+"
  echo "Strategy: git-diff + state:modified+ combined — ${SEL}"
  dbt build --target ci --select "${SEL}" --defer --state prod_state --exclude-resource-type test
  CI_SELECT="${SEL}"; CI_DEFER="--defer --state prod_state"
else
  # Macro/config/yaml-only change (no scoped node) → state comparison.
  echo "Strategy: state:modified+ fallback (macro/config/YAML-only change)"
  dbt build --target ci --select "state:modified+" --defer --state prod_state --exclude-resource-type test
  CI_SELECT="state:modified+"; CI_DEFER="--defer --state prod_state"
fi

echo ""
echo "=== Build Complete ==="

export_ci_select_defer
