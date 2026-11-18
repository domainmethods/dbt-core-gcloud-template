#!/usr/bin/env bash
set -euo pipefail

echo "Starting container at $(date -Is)"
echo "DBT_TARGET=${DBT_TARGET:-prod}"
echo "Artifacts bucket: ${DBT_ARTIFACTS_BUCKET:-<unset>}"
echo "Docs bucket: ${DBT_DOCS_BUCKET:-${DBT_ARTIFACTS_BUCKET:-<unset>}}"

# Disable ANSI colors so Cloud Logging is readable
export NO_COLOR=1
export CLICOLOR=0
export TERM=dumb

# For prod, force no ANSI colors via CLI flag in addition to envs
DBT_NO_COLOR_FLAG=""
if [[ "${DBT_TARGET:-prod}" == "prod" ]]; then
  DBT_NO_COLOR_FLAG="--no-use-colors"
fi

# Ensure a usable profiles.yml; fall back to a minimal prod profile if absent
export DBT_PROFILES_DIR="${DBT_PROFILES_DIR:-/app/profiles}"
if [[ "${DEBUG:-0}" == "1" ]]; then
  echo "[debug] Listing /app and ${DBT_PROFILES_DIR}"
  ls -la /app || true
  ls -la "$DBT_PROFILES_DIR" || true
fi
if [[ -f "$DBT_PROFILES_DIR/profiles.yml" ]]; then
  echo "Using profiles at $DBT_PROFILES_DIR/profiles.yml"
else
  echo "No profiles.yml at $DBT_PROFILES_DIR; creating a minimal prod profile"
  mkdir -p "$DBT_PROFILES_DIR"
  PROJECT_VAL="${DBT_GCP_PROJECT_PROD:-}"
  DATASET_VAL="${DBT_BQ_DATASET_PROD:-analytics}"
  LOCATION_VAL="${DBT_BQ_LOCATION:-US}"
  cat > "$DBT_PROFILES_DIR/profiles.yml" <<YAML
dbt_gcloud:
  target: "prod"
  outputs:
    prod:
      type: bigquery
      method: oauth
      project: "${PROJECT_VAL}"
      dataset: "${DATASET_VAL}"
      location: "${LOCATION_VAL}"
      threads: 8
      priority: interactive
      labels: {service: dbt, env: "prod"}
YAML
fi

# Freshness toggle: default true in prod, false otherwise (can override via RUN_FRESHNESS)
if [[ -z "${RUN_FRESHNESS:-}" ]]; then
  if [[ "${DBT_TARGET:-prod}" == "prod" ]]; then
    RUN_FRESHNESS=true
  else
    RUN_FRESHNESS=false
  fi
fi

if [[ "${RUN_PRE_HOOK:-false}" == "true" ]]; then
  echo "Running pre_run.py ..."
  python hooks/pre_run.py
fi

# Use JSON logs for easier parsing in Cloud Logging
if [[ "${RUN_DBT_DEBUG:-true}" == "true" ]]; then
  echo "Running dbt debug --target ${DBT_TARGET}"
  dbt ${DBT_NO_COLOR_FLAG} debug --target "${DBT_TARGET}" && echo "dbt debug: success"
fi
dbt ${DBT_NO_COLOR_FLAG} --log-format json deps

DBT_BUILD_ARGS="${DBT_BUILD_ARGS:-}"
echo "Running dbt build --target ${DBT_TARGET} ${DBT_BUILD_ARGS}"
# Exit codes are captured, not fatal: a failed step must still emit the summary and
# upload run_results.json. The first non-zero code is re-raised at the end (#20).
BUILD_EXIT=0
dbt ${DBT_NO_COLOR_FLAG} --log-format json build --target "${DBT_TARGET}" ${DBT_BUILD_ARGS} || BUILD_EXIT=$?

# Freshness and docs can overwrite the build artifacts in target/.
build_artifacts_dir="$(mktemp -d)"
trap 'rm -rf -- "${build_artifacts_dir}"' EXIT
export DBT_RUN_RESULTS_PATH="${build_artifacts_dir}/run_results.json"
export DBT_BUILD_MANIFEST_PATH="${build_artifacts_dir}/manifest.json"
for artifact in run_results.json manifest.json; do
  if [[ -f "target/${artifact}" ]]; then
    cp "target/${artifact}" "${build_artifacts_dir}/"
  fi
done

# Optional source freshness
FRESHNESS_EXIT=0
if [[ "${RUN_FRESHNESS}" == "true" ]]; then
  echo "Running dbt source freshness"
  if [[ -n "${FRESHNESS_SELECT:-}" ]]; then
    dbt ${DBT_NO_COLOR_FLAG} --log-format json source freshness --select "${FRESHNESS_SELECT}" || FRESHNESS_EXIT=$?
  else
    dbt ${DBT_NO_COLOR_FLAG} --log-format json source freshness || FRESHNESS_EXIT=$?
  fi
  # Summarize freshness (if sources.json exists)
  python scripts/lib/freshness_summary.py
fi

# Emit summary; capture exit code without triggering set -e abort
DBT_EXIT=0
python scripts/lib/dbt_summary.py || DBT_EXIT=$?

# Docs only for a green build, so a failed night keeps the last good docs.
# A docs failure must not stop the artifact upload below, so capture it too.
DOCS_EXIT=0
if [[ "${GENERATE_DOCS:-false}" == "true" && "${BUILD_EXIT}" -eq 0 ]]; then
  dbt ${DBT_NO_COLOR_FLAG} docs generate --static || DOCS_EXIT=$?
  if [[ "${DOCS_EXIT}" -ne 0 ]]; then
    echo "dbt docs generate failed (exit ${DOCS_EXIT}); skipping docs upload" >&2
  else
    python scripts/lib/upload_docs.py || DOCS_EXIT=$?
  fi
fi

# Upload core artifacts to artifacts bucket for Slim CI deferral
export BUILD_EXIT
ARTIFACTS_EXIT=0
if [[ -n "${DBT_ARTIFACTS_BUCKET:-}" ]]; then
  echo "Uploading manifest.json, run_results.json, and sources.json (if present) to gs://${DBT_ARTIFACTS_BUCKET}/prod/"
  python scripts/lib/upload_artifacts.py || ARTIFACTS_EXIT=$?
fi

if [[ "${RUN_POST_HOOK:-false}" == "true" && "${BUILD_EXIT}" -eq 0 && "${FRESHNESS_EXIT}" -eq 0 && "${ARTIFACTS_EXIT}" -eq 0 ]]; then
  echo "Running post_run.py ..."
  python hooks/post_run.py
fi

# Propagate the first failure to Cloud Run
for STEP_EXIT in "${BUILD_EXIT}" "${FRESHNESS_EXIT}" "${DBT_EXIT}" "${DOCS_EXIT}" "${ARTIFACTS_EXIT}"; do
  if [[ "${STEP_EXIT}" -ne 0 ]]; then
    echo "dbt build=${BUILD_EXIT} freshness=${FRESHNESS_EXIT} summary=${DBT_EXIT} docs=${DOCS_EXIT} artifacts=${ARTIFACTS_EXIT}; exiting ${STEP_EXIT}" >&2
    exit "${STEP_EXIT}"
  fi
done

echo "Completed at $(date -Is)"
