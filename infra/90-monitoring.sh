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

# Optional 9th arg: markdown runbook shown in the alert notification.
documentation_json() {
  local doc="$1"
  [[ -z "$doc" ]] && return 0
  printf '  "documentation": {"mimeType": "text/markdown", "content": %s},\n' "$(jq -Rsn --arg d "$doc" '$d')"
}

metric_policy_json() {
  local display="$1" metric="$2" resource_type="$3" alignment="$4" per_series="$5" comparison="$6" threshold="$7" duration="$8" doc="${9:-}"
  cat <<JSON
{
  "displayName": "$display",
  "combiner": "OR",
$(documentation_json "$doc")
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

# Alert on whole Cloud Run executions that failed after all task retries, using the
# built-in run.googleapis.com/job/completed_execution_count metric (result="failed").
# A task attempt that exits non-zero and is retried successfully does not count.
execution_failure_policy_json() {
  local display="$1" job="$2" region="$3" doc="${4:-}"
  cat <<JSON
{
  "displayName": "$display",
  "combiner": "OR",
$(documentation_json "$doc")
  "conditions": [
    {
      "displayName": "$display condition",
      "conditionThreshold": {
        "filter": "metric.type=\"run.googleapis.com/job/completed_execution_count\" resource.type=\"cloud_run_job\" resource.labels.job_name=\"${job}\" resource.labels.location=\"${region}\" metric.labels.result=\"failed\"",
        "aggregations": [
          {
            "alignmentPeriod": "300s",
            "perSeriesAligner": "ALIGN_DELTA",
            "crossSeriesReducer": "REDUCE_SUM",
            "groupByFields": ["resource.label.job_name"]
          }
        ],
        "comparison": "COMPARISON_GT",
        "thresholdValue": 0,
        "duration": "0s"
      }
    }
  ]
}
JSON
}

# jq helpers for ensure_policy.
#   merge_live: the live policy ($live) with the fields this script manages taken
#     from the template (.): displayName, combiner, conditions, documentation when
#     the template has a runbook, and notificationChannels when $ch is set. Every
#     other field (enabled, severity, userLabels, alertStrategy, console-written
#     docs, channels when $ch is unset) is kept as it is live. Output-only records
#     are dropped.
#   comparable: a policy minus server-assigned bits (condition names, records) and
#     default-valued fields the API omits (e.g. a 0 thresholdValue), so a template
#     and the policy the API echoes back compare equal when nothing changed.
POLICY_JQ_DEFS='
def merge_live($live; $ch):
  . as $t
  | $live
  | del(.creationRecord, .mutationRecord, .validity)
  | .displayName = $t.displayName
  | .combiner = $t.combiner
  | .conditions = $t.conditions
  | (if $t | has("documentation") then .documentation = $t.documentation else . end)
  | (if $ch != "" then .notificationChannels = [$ch | split(",")[] | gsub("^\\s+|\\s+$"; "")] else . end);
def prune:
  if type == "object" then
    with_entries(.value |= prune | select(.value | . != null and . != "" and . != [] and . != {} and . != 0 and . != false and . != "0s"))
  elif type == "array" then map(prune)
  else . end;
def comparable:
  del(.creationRecord, .mutationRecord, .validity)
  | .conditions = [(.conditions // [])[] | del(.name)]
  | .notificationChannels = ((.notificationChannels // []) | sort)
  | prune;
'

# Create the policy, or update it in place if one with this displayName exists, so
# edits to filters, thresholds or runbooks reach existing deployments on re-run (#54).
# `policies update --policy-from-file` replaces the whole policy (its --fields only
# accepts disabled/notificationChannels), so the update is the live policy with the
# managed fields swapped in: a policy disabled or edited in the console keeps those
# settings. With NOTIFICATION_CHANNELS unset, it keeps its current channels. If the
# result matches the live policy, no update is sent (an update can open a transient
# incident on some conditions).
ensure_policy() {
  local name="$1" file="$2"
  local existing count
  existing=$($POL_CMD list --filter="displayName=\"$name\"" --format="value(name)" --project "$PROJECT_ID")
  count=$(grep -c . <<<"$existing" || true)
  if (( count > 1 )); then
    echo "[warn] $count policies named \"$name\"; updating the first. Delete the duplicates:" >&2
    echo "$existing" | sed 's/^/         /' >&2
  fi
  existing=$(head -n1 <<<"$existing")
  if [[ -n "$existing" ]]; then
    local live="${file}.live"
    if ! $POL_CMD describe "$existing" --format=json --project "$PROJECT_ID" > "$live"; then
      echo "[error] Failed to read monitoring policy: $name ($existing)" >&2
      return 1
    fi
    jq --slurpfile live "$live" --arg ch "$CHANNELS" "$POLICY_JQ_DEFS"' merge_live($live[0]; $ch)' "$file" > "${file}.merged" \
      && mv "${file}.merged" "$file"
    if jq -e --slurpfile live "$live" "$POLICY_JQ_DEFS"' (comparable) == ($live[0] | comparable)' "$file" >/dev/null; then
      echo "Policy unchanged: $name"
      return 0
    fi
    echo "Updating policy: $name"
    if ! $POL_CMD update "$existing" --policy-from-file="$file" --project "$PROJECT_ID"; then
      echo "[error] Failed to update monitoring policy: $name" >&2
      echo "        Check that notification channels are valid and you have monitoring.alertPolicies.update permission" >&2
      return 1
    fi
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
#
# `NOT logName=~"cloudaudit"` keeps this on the job's execution logs. The cloud_run_job
# resource also emits Cloud Audit logs, so a transient GCP error on the release's
# `gcloud run jobs update` (logged as ERROR, then retried by gcloud) would otherwise
# page. Only audit logs are dropped: the job's own logs still count at severity>=ERROR
# (dbt's JSON logs on run.googleapis.com/stdout, anything on run.googleapis.com/stderr,
# and Cloud Run's task-exit messages on run.googleapis.com/varlog/system).
ensure_log_metric "cloud_run_job_errors" \
  "resource.type=\"cloud_run_job\" severity>=ERROR resource.labels.location=\"${REGION}\" resource.labels.job_name=\"${JOB_NAME}\" NOT logName=~\"cloudaudit\"" \
  "Errors from Cloud Run Job ${JOB_NAME} (execution logs, severity>=ERROR)"

# Task-level failure text, kept for dashboards and retry tracking. The failure alert
# below uses the built-in execution metric instead, since this also matches task
# attempts that Cloud Run retried successfully.
ensure_log_metric "cloud_run_job_failures" \
  "resource.type=\"cloud_run_job\" resource.labels.location=\"${REGION}\" resource.labels.job_name=\"${JOB_NAME}\" (textPayload:\"Container called exit\" OR textPayload:\"Execution failed\" OR textPayload:\"exited with status\" OR textPayload:\"non-zero exit\" OR jsonPayload.message:\"Container called exit\" OR jsonPayload.message:\"Execution failed\" OR jsonPayload.message:\"exited with status\" OR jsonPayload.message:\"non-zero exit\") AND NOT (textPayload:\"exit(0)\" OR textPayload:\"exited with status 0\" OR textPayload:\"status 0\" OR textPayload:\"exit code: 0\" OR jsonPayload.message:\"exit(0)\" OR jsonPayload.message:\"exited with status 0\" OR jsonPayload.message:\"status 0\" OR jsonPayload.message:\"exit code: 0\")" \
  "Cloud Run Job ${JOB_NAME} task-level failures (excludes exit(0)/status 0; for dashboards)"

# Audit logs stay in here: scheduler invocation failures (e.g. a 403 from a missing
# run.invoker grant) are audit-logged and must keep counting.
ensure_log_metric "cloud_scheduler_job_errors" \
  "resource.type=\"cloud_scheduler_job\" severity>=ERROR resource.labels.location=\"${SCHED_REGION}\" resource.labels.job_id=\"${SCHED_JOB_NAME}\"" \
  "Errors from Cloud Scheduler job ${SCHED_JOB_NAME}"

# Skip errors that dbt-bigquery retries past (job_retries). The metric counts attempts,
# not outcomes, so these paged on green builds. A failure that exhausts retries fails
# the dbt node and the execution, which pages through the job failure alert.
#   - 14 (UNAVAILABLE): "retrying may solve the problem"
#   - 6 (ALREADY_EXISTS): the retry re-submitting its own job id
#   - Sheets "overloaded" uses 3 (INVALID_ARGUMENT), the same code as real SQL
#     errors, so it is matched by message, not by code
ensure_log_metric "bigquery_job_errors" \
  "resource.type=\"bigquery_project\" severity>=ERROR protoPayload.authenticationInfo.principalEmail=\"${PROD_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com\" -protoPayload.status.code=14 -protoPayload.status.code=6 -protoPayload.status.message:\"Google Sheets service overloaded\"" \
  "BigQuery job errors from production service account (${PROD_SA_ID})"

TMP=$(mktemp)
trap 'rm -f "$TMP" "${TMP}.live" "${TMP}.merged"' EXIT

# read -d '' (not $(cat <<EOF)) so bash 3.2 parses quotes in the text
read -r -d '' BIGQUERY_ERRORS_DOC <<'EOF' || true
BigQuery jobs run by the production service account logged an error.

1. Find the job id near the alert time and look it up in `INFORMATION_SCHEMA.JOBS_BY_PROJECT` (in the dataset's region). If it ended `DONE` with no `error_result`, it was a transient that dbt retried: no action needed.
2. Otherwise, read the error text and check the tables and datasets it names.
3. Check permissions and upstream freshness before re-running the job.
EOF

read -r -d '' CLOUD_RUN_FAILURES_DOC <<'EOF' || true
A Cloud Run execution failed after all task retries. A task attempt that failed and was retried successfully does not fire this alert.

1. Open the failed execution's logs and find the exit code and the failing dbt node.
2. Check the dbt target and arguments the run used.
3. If it is a source or auth problem, check the upstream load before re-running.
EOF

# Policies (count > 0 over 5m). Use DELTA to count new events in window.
metric_policy_json "Cloud Run Job Errors (${JOB_NAME})" "cloud_run_job_errors" "cloud_run_job" "300s" "ALIGN_DELTA" "COMPARISON_GT" 0 "300s" > "$TMP"
ensure_policy "Cloud Run Job Errors (${JOB_NAME})" "$TMP"

metric_policy_json "Cloud Scheduler Job Errors (${SCHED_JOB_NAME})" "cloud_scheduler_job_errors" "cloud_scheduler_job" "300s" "ALIGN_DELTA" "COMPARISON_GT" 0 "300s" > "$TMP"
ensure_policy "Cloud Scheduler Job Errors (${SCHED_JOB_NAME})" "$TMP"

metric_policy_json "BigQuery Job Errors (Production)" "bigquery_job_errors" "bigquery_project" "300s" "ALIGN_DELTA" "COMPARISON_GT" 0 "300s" "$BIGQUERY_ERRORS_DOC" > "$TMP"
ensure_policy "BigQuery Job Errors (Production)" "$TMP"

# Alert on executions that failed after all task retries (#58)
execution_failure_policy_json "Cloud Run Job Failures (${JOB_NAME})" "$JOB_NAME" "$REGION" "$CLOUD_RUN_FAILURES_DOC" > "$TMP"
ensure_policy "Cloud Run Job Failures (${JOB_NAME})" "$TMP"

echo "Monitoring alerts ensured."
