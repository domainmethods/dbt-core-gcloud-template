#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

PROJECT_ID=${PROJECT_ID:?}
REGION=${REGION:?}
SCHED_REGION=${SCHED_REGION:-$REGION}
JOB_NAME=${JOB_NAME:-dbt-prod-run}
SCHED_JOB_NAME=${SCHED_JOB_NAME:-dbt-prod-nightly}
CHANNELS=${NOTIFICATION_CHANNELS:-}
BQ_BYTES_SCANNED_ALERT_GB=${BQ_BYTES_SCANNED_ALERT_GB:-}

# Validate notification channels if provided
if [[ -n "$CHANNELS" ]]; then
  echo "[info] Validating notification channels: $CHANNELS"
  IFS=',' read -r -a channel_array <<< "$CHANNELS"
  for channel in "${channel_array[@]}"; do
    channel_trim=$(echo "$channel" | awk '{$1=$1;print}')
    if [[ ! "$channel_trim" =~ ^projects/[^/]+/notificationChannels/[0-9]+$ ]]; then
      echo "[warn] Notification channel format looks invalid: $channel_trim" >&2
      echo "       Expected format: projects/PROJECT_ID/notificationChannels/ID" >&2
    fi
  done
else
  echo "[info] No notification channels configured. Alerts will be created but not sent."
fi

# Pick monitoring policies command (beta preferred, else alpha)
pick_policies_cmd() {
  if gcloud beta monitoring policies --help >/dev/null 2>&1; then
    echo "gcloud beta monitoring policies"
  elif gcloud alpha monitoring policies --help >/dev/null 2>&1; then
    echo "gcloud alpha monitoring policies"
  else
    echo ""; return 1
  fi
}

POL_CMD=$(pick_policies_cmd) || { echo "gcloud monitoring policies command not available (alpha/beta)." >&2; exit 2; }

ensure_log_metric() {
  local name="$1" filter="$2" desc="$3"
  local exists=0
  local tmp="$(mktemp)"
  if gcloud logging metrics describe "$name" --project "$PROJECT_ID" --format=json >"$tmp" 2>/dev/null; then
    exists=1
  fi
  if [[ $exists -eq 0 ]]; then
    echo "Creating log metric: $name"
    gcloud logging metrics create "$name" --description="$desc" --log-filter="$filter" --project "$PROJECT_ID"
  else
    # Compare current filter/description and update if changed
    local cur_filter cur_desc
    cur_filter=$(jq -r '.filter // ""' "$tmp")
    cur_desc=$(jq -r '.description // ""' "$tmp")
    if [[ "$cur_filter" != "$filter" || "$cur_desc" != "$desc" ]]; then
      echo "Updating log metric: $name"
      gcloud logging metrics update "$name" --description="$desc" --log-filter="$filter" --project "$PROJECT_ID"
    else
      echo "Log metric up-to-date: $name"
    fi
  fi
  rm -f "$tmp"
}

metric_policy_json() {
  local display="$1" metric="$2" resource_type="$3" alignment="$4" per_series="$5" comparison="$6" threshold="$7" duration="$8"
  cat <<JSON
{
  "displayName": "$display",
  "combiner": "OR",
  "conditions": [
    {
      "displayName": "$display condition",
      "conditionThreshold": {
        "filter": "metric.type=\"logging.googleapis.com/user/${metric}\" resource.type=\"${resource_type}\"",
        "aggregations": [
          {"alignmentPeriod": "$alignment", "perSeriesAligner": "$per_series"}
        ],
        "comparison": "$comparison",
        "thresholdValue": $threshold,
        "duration": "$duration"
      }
    }
  ]
}
JSON
}

bq_bytes_billed_policy_json() {
  local display="$1" gb_threshold="$2" bytes_threshold="$3"
  cat <<JSON
{
  "displayName": "$display",
  "documentation": {
    "content": "BigQuery scanned bytes billed in project ${PROJECT_ID} exceeded ${gb_threshold} GB in a 1-hour window. Inspect INFORMATION_SCHEMA.JOBS_BY_PROJECT to identify the principal and query.",
    "mimeType": "text/markdown"
  },
  "combiner": "OR",
  "conditions": [
    {
      "displayName": "BigQuery scanned bytes billed > ${gb_threshold} GB / 1h",
      "conditionThreshold": {
        "filter": "metric.type=\"bigquery.googleapis.com/query/scanned_bytes_billed\" resource.type=\"global\"",
        "aggregations": [
          {"alignmentPeriod": "3600s", "perSeriesAligner": "ALIGN_SUM", "crossSeriesReducer": "REDUCE_SUM"}
        ],
        "comparison": "COMPARISON_GT",
        "thresholdValue": $bytes_threshold,
        "duration": "0s"
      }
    }
  ]
}
JSON
}

ensure_policy() {
  local name="$1" file="$2"
  if $POL_CMD list --format="value(displayName)" --project "$PROJECT_ID" | grep -Fx "$name" >/dev/null 2>&1; then
    echo "Policy exists: $name"
  else
    echo "Creating policy: $name"
    if [[ -n "$CHANNELS" ]]; then
      if ! $POL_CMD create --policy-from-file="$file" --notification-channels="$CHANNELS" --project "$PROJECT_ID"; then
        echo "[error] Failed to create monitoring policy: $name" >&2
        echo "        Check that notification channels are valid and you have monitoring.alertPolicies.create permission" >&2
        return 1
      fi
    else
      if ! $POL_CMD create --policy-from-file="$file" --project "$PROJECT_ID"; then
        echo "[error] Failed to create monitoring policy: $name" >&2
        echo "        Check that you have monitoring.alertPolicies.create permission" >&2
        return 1
      fi
    fi
  fi
}

# Metrics
ensure_log_metric "cloud_run_job_errors" \
  "resource.type=\"cloud_run_job\" severity>=ERROR resource.labels.location=\"${REGION}\" resource.labels.job_name=\"${JOB_NAME}\"" \
  "Errors from Cloud Run Job ${JOB_NAME} (severity>=ERROR)"

# Capture common failure text even if severity is not elevated
ensure_log_metric "cloud_run_job_failures" \
  "resource.type=\"cloud_run_job\" resource.labels.location=\"${REGION}\" resource.labels.job_name=\"${JOB_NAME}\" (textPayload:\"Container called exit\" OR textPayload:\"Execution failed\" OR textPayload:\"exited with status\" OR textPayload:\"non-zero exit\" OR jsonPayload.message:\"Container called exit\" OR jsonPayload.message:\"Execution failed\" OR jsonPayload.message:\"exited with status\" OR jsonPayload.message:\"non-zero exit\") AND NOT (textPayload:\"exit(0)\" OR textPayload:\"exited with status 0\" OR textPayload:\"status 0\" OR textPayload:\"exit code: 0\" OR jsonPayload.message:\"exit(0)\" OR jsonPayload.message:\"exited with status 0\" OR jsonPayload.message:\"status 0\" OR jsonPayload.message:\"exit code: 0\")" \
  "Cloud Run Job ${JOB_NAME} failures (excludes exit(0)/status 0)"

ensure_log_metric "cloud_scheduler_job_errors" \
  "resource.type=\"cloud_scheduler_job\" severity>=ERROR resource.labels.location=\"${SCHED_REGION}\" resource.labels.job_id=\"${SCHED_JOB_NAME}\"" \
  "Errors from Cloud Scheduler job ${SCHED_JOB_NAME}"

ensure_log_metric "bigquery_job_errors" \
  "resource.type=\"bigquery_project\" severity>=ERROR protoPayload.authenticationInfo.principalEmail=\"${PROD_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com\"" \
  "BigQuery job errors from production service account (${PROD_SA_ID})"

TMP=$(mktemp)

# Policies (count > 0 over 5m). Use DELTA to count new events in window.
metric_policy_json "Cloud Run Job Errors (${JOB_NAME})" "cloud_run_job_errors" "cloud_run_job" "300s" "ALIGN_DELTA" "COMPARISON_GT" 0 "300s" > "$TMP"
ensure_policy "Cloud Run Job Errors (${JOB_NAME})" "$TMP"

metric_policy_json "Cloud Scheduler Job Errors (${SCHED_JOB_NAME})" "cloud_scheduler_job_errors" "cloud_scheduler_job" "300s" "ALIGN_DELTA" "COMPARISON_GT" 0 "300s" > "$TMP"
ensure_policy "Cloud Scheduler Job Errors (${SCHED_JOB_NAME})" "$TMP"

metric_policy_json "BigQuery Job Errors (Production)" "bigquery_job_errors" "bigquery_project" "300s" "ALIGN_DELTA" "COMPARISON_GT" 0 "300s" > "$TMP"
ensure_policy "BigQuery Job Errors (Production)" "$TMP"

# Also alert on text-matched job failures
metric_policy_json "Cloud Run Job Failures (${JOB_NAME})" "cloud_run_job_failures" "cloud_run_job" "300s" "ALIGN_DELTA" "COMPARISON_GT" 0 "300s" > "$TMP"
ensure_policy "Cloud Run Job Failures (${JOB_NAME})" "$TMP"

# Optional: BigQuery bytes-billed alert (project-wide scanned bytes billed per 1h window)
if [[ -n "$BQ_BYTES_SCANNED_ALERT_GB" && "$BQ_BYTES_SCANNED_ALERT_GB" != "0" ]]; then
  if [[ ! "$BQ_BYTES_SCANNED_ALERT_GB" =~ ^[1-9][0-9]*$ ]]; then
    echo "[error] BQ_BYTES_SCANNED_ALERT_GB must be a positive integer (or 0/empty to skip): $BQ_BYTES_SCANNED_ALERT_GB" >&2
    rm -f "$TMP"
    exit 1
  fi
  BQ_BYTES_THRESHOLD=$(( BQ_BYTES_SCANNED_ALERT_GB * 1000000000 ))
  BQ_BYTES_POLICY_NAME="BigQuery Bytes Billed (>${BQ_BYTES_SCANNED_ALERT_GB} GB/hr)"
  bq_bytes_billed_policy_json "$BQ_BYTES_POLICY_NAME" "$BQ_BYTES_SCANNED_ALERT_GB" "$BQ_BYTES_THRESHOLD" > "$TMP"
  ensure_policy "$BQ_BYTES_POLICY_NAME" "$TMP"
else
  echo "[info] Skipping BigQuery bytes-billed alert (BQ_BYTES_SCANNED_ALERT_GB unset or 0)."
fi

rm -f "$TMP"
echo "Monitoring alerts ensured."
