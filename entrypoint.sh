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
dbt ${DBT_NO_COLOR_FLAG} --log-format json build --target "${DBT_TARGET}" ${DBT_BUILD_ARGS}

# Optional source freshness
if [[ "${RUN_FRESHNESS}" == "true" ]]; then
  echo "Running dbt source freshness"
  if [[ -n "${FRESHNESS_SELECT:-}" ]]; then
    dbt ${DBT_NO_COLOR_FLAG} --log-format json source freshness --select "${FRESHNESS_SELECT}"
  else
    dbt ${DBT_NO_COLOR_FLAG} --log-format json source freshness
  fi
  # Summarize freshness (if sources.json exists)
  python - << 'PY'
import json, os
sp = os.path.join('target','sources.json')
if os.path.exists(sp):
    try:
        with open(sp) as f:
            doc = json.load(f)
        statuses = {}
        for src in doc.get('sources', []):
            st = (src.get('freshness') or {}).get('status') or src.get('status') or 'unknown'
            statuses[st] = statuses.get(st, 0) + 1
        print(json.dumps({"dbt_freshness": {"statuses": statuses}}))
        parts = ", ".join(f"{k}={v}" for k, v in sorted(statuses.items())) or "no entries"
        print(f"dbt freshness: {parts}")
    except Exception as e:
        print(json.dumps({"dbt_freshness": {"status": "error_reading_sources", "error": str(e)}}))
        print(f"dbt freshness: failed to read sources.json ({e})")
else:
    print(json.dumps({"dbt_freshness": {"status": "missing_sources_json"}}))
    print("dbt freshness: missing target/sources.json")
PY
fi

# Emit a one-line JSON summary for alerting/observability
python - << 'PY'
import json, os, sys
path = os.path.join('target','run_results.json')
try:
    with open(path) as f:
        doc = json.load(f)
except Exception as e:
    print(json.dumps({"dbt_summary": {"status": "missing_run_results", "error": str(e)}}))
    print(f"dbt summary: missing run_results.json ({e})")
    sys.exit(0)

results = doc.get('results', [])
status_counts = {}
for r in results:
    s = r.get('status', 'unknown')
    status_counts[s] = status_counts.get(s, 0) + 1

summary = {
    "total": len(results),
    "elapsed": doc.get('elapsed_time'),
    "statuses": status_counts,
}

# Backward-compatible booleans
summary["failed"] = status_counts.get('error', 0) + status_counts.get('fail', 0)
summary["successful"] = status_counts.get('success', 0)

print(json.dumps({"dbt_summary": summary}))
# Human-friendly one-liner
failed = summary.get("failed", 0)
succ = summary.get("successful", 0)
elapsed = summary.get("elapsed")
print(f"dbt summary: {succ} succeeded, {failed} failed, total={summary['total']}, elapsed={elapsed}s")
PY

if [[ "${GENERATE_DOCS:-false}" == "true" ]]; then
  dbt ${DBT_NO_COLOR_FLAG} docs generate --static
  echo "Docs generated at ./target/index.html"
  # Prefer DBT_DOCS_BUCKET; fall back to DBT_ARTIFACTS_BUCKET if not set
  EXPORT_DOCS_BUCKET="${DBT_DOCS_BUCKET:-${DBT_ARTIFACTS_BUCKET:-}}"
  if [[ -n "${EXPORT_DOCS_BUCKET}" ]]; then
    echo "Uploading docs to gs://${EXPORT_DOCS_BUCKET}/index.html"
    python - << 'PY'
import os
from google.cloud import storage

bucket_name = os.environ.get("DBT_DOCS_BUCKET") or os.environ.get("DBT_ARTIFACTS_BUCKET")
path = os.path.join("target", "index.html")
client = storage.Client()
bucket = client.bucket(bucket_name)
blob = bucket.blob("index.html")
blob.cache_control = "no-cache"
blob.content_type = "text/html"
with open(path, "rb") as f:
    blob.upload_from_file(f, content_type="text/html")
print(f"Uploaded to gs://{bucket_name}/index.html")
PY
  fi
fi

# Upload core artifacts to artifacts bucket for Slim CI deferral
if [[ -n "${DBT_ARTIFACTS_BUCKET:-}" ]]; then
  echo "Uploading manifest.json, run_results.json, and sources.json (if present) to gs://${DBT_ARTIFACTS_BUCKET}/prod/"
  python - << 'PY'
import os
from google.cloud import storage

bucket_name = os.environ["DBT_ARTIFACTS_BUCKET"]
client = storage.Client()
bucket = client.bucket(bucket_name)
for name in ("manifest.json", "run_results.json", "sources.json"):
    p = os.path.join("target", name)
    if os.path.exists(p):
        blob = bucket.blob(f"prod/{name}")
        blob.cache_control = "no-cache"
        blob.content_type = "application/json"
        with open(p, "rb") as f:
            blob.upload_from_file(f, content_type="application/json")
        print(f"Uploaded gs://{bucket_name}/prod/{name}")
    else:
        print(f"Skipping missing {p}")
PY
fi

if [[ "${RUN_POST_HOOK:-false}" == "true" ]]; then
  echo "Running post_run.py ..."
  python hooks/post_run.py
fi

echo "Completed at $(date -Is)"
