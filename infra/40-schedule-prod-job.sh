#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

require_env(){
  local v
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then
      echo "Missing env: $v"
      exit 1
    fi
  done
  return 0
}
require_env PROJECT_ID REGION SCHEDULER_SA_ID

# Use consistent region for scheduler (defaults to same as Cloud Run Job region)
SCHED_REGION="${SCHED_REGION:-$REGION}"
SCHED_SA_EMAIL="${SCHEDULER_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "== Ensure Scheduler SA can invoke the Cloud Run job =="
TMP_RUN_POLICY="$(mktemp)"
gcloud run jobs get-iam-policy dbt-prod-run --region "${REGION}" --project "${PROJECT_ID}" --format=json >"$TMP_RUN_POLICY"
if jq -e --arg m "serviceAccount:${SCHED_SA_EMAIL}" '.bindings[]? | select(.role=="roles/run.invoker") | .members[]? | select(.==$m)' "$TMP_RUN_POLICY" >/dev/null; then
  echo "Run invoker already granted."
else
  gcloud run jobs add-iam-policy-binding dbt-prod-run \
    --region "${REGION}" \
    --member "serviceAccount:${SCHED_SA_EMAIL}" \
    --role "roles/run.invoker" \
    --project "${PROJECT_ID}"
fi
rm -f "$TMP_RUN_POLICY"

echo "== Ensure Cloud Scheduler job (runs daily at 06:00 UTC) =="
echo "[info] Using Scheduler region: ${SCHED_REGION}, Cloud Run region: ${REGION}"

# Common scheduler args: retry on transient failures
SCHED_ARGS=(
  --location "${SCHED_REGION}"
  --schedule="0 6 * * *"
  --http-method=POST
  --uri="https://run.googleapis.com/v2/projects/${PROJECT_ID}/locations/${REGION}/jobs/dbt-prod-run:run"
  --oauth-service-account-email "${SCHED_SA_EMAIL}"
  --oauth-token-scope "https://www.googleapis.com/auth/cloud-platform"
  --project "${PROJECT_ID}"
  --attempt-deadline=600s
  --max-retry-duration=1800s
  --min-backoff=30s
  --max-backoff=300s
  --max-doublings=3
)

if gcloud scheduler jobs describe dbt-prod-nightly --location "${SCHED_REGION}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud scheduler jobs update http dbt-prod-nightly "${SCHED_ARGS[@]}"
else
  gcloud scheduler jobs create http dbt-prod-nightly "${SCHED_ARGS[@]}"
fi

echo "Scheduler configured."
