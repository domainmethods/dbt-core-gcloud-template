#!/usr/bin/env bash
# Tests for infra/90-monitoring.sh: policy create-vs-update, notification channel
# handling, and the log-metric filters / policy JSON it generates.
# Dependency-free: bash 4+, coreutils, jq. Stubs gcloud on PATH. No `set -e`.
#
# Usage: bash scripts/tests/test_monitoring.sh
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$REPO_ROOT/infra/90-monitoring.sh"
PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "    ok   - $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "    FAIL - $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
assert_contains() { [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 (missing '$2')"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] && pass "$3" || fail "$3 (unexpected '$2')"; }
assert_eq() { [[ "$1" == "$2" ]] && pass "$3" || fail "$3 (got '$1', want '$2')"; }

# Sandbox layout: $SANDBOX/infra/{90-monitoring.sh,.env}, a gcloud stub on PATH, and
# state files the stub reads:
#   policies.txt   "<resource name>|<displayName>" per existing policy
#   metrics/<name> JSON for each existing log metric
# The stub appends every call to calls.log and saves each policy file it is given
# to policy_files/<n>-<create|update>.json.
make_sandbox() {
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/bin" "$SANDBOX/infra" "$SANDBOX/metrics" "$SANDBOX/policy_files"
  cp "$SCRIPT" "$SANDBOX/infra/90-monitoring.sh"
  cat > "$SANDBOX/infra/.env" <<'ENV'
PROJECT_ID=test-proj
REGION=us-central1
PROD_SA_ID=dbt-prod
ENV
  : > "$SANDBOX/policies.txt"; : > "$SANDBOX/calls.log"
  cat > "$SANDBOX/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "gcloud $*" >> "$STUB_DIR/calls.log"
args=("$@")
arg_val() { local k="$1" a; for a in "${args[@]}"; do [[ "$a" == "$k="* ]] && { echo "${a#*=}"; return; }; done; }
save_policy() {
  local n; n=$(ls "$STUB_DIR/policy_files" | wc -l | tr -d ' ')
  cp "$(arg_val --policy-from-file)" "$STUB_DIR/policy_files/$(printf '%02d' "$n")-$1.json"
}
case "$1 $2 $3" in
  "beta monitoring policies")
    case "$4" in
      --help) exit 0 ;;
      list)
        want=$(arg_val --filter); want=${want#displayName=\"}; want=${want%\"}
        while IFS='|' read -r name display; do
          [[ "$display" == "$want" ]] && echo "$name"
        done < "$STUB_DIR/policies.txt"; exit 0 ;;
      describe) printf '{"name":"%s","notificationChannels":%s}\n' "$5" "${STUB_CUR_CHANNELS:-[]}"; exit 0 ;;
      create) save_policy create; exit 0 ;;
      update) save_policy update; exit 0 ;;
    esac ;;
  "logging metrics describe")
    [[ -f "$STUB_DIR/metrics/$4" ]] && { cat "$STUB_DIR/metrics/$4"; exit 0; }; exit 1 ;;
  "logging metrics create"|"logging metrics update") exit 0 ;;
esac
echo "unexpected gcloud call: $*" >&2; exit 3
STUB
  chmod +x "$SANDBOX/bin/gcloud"
}

run_case() {  # $1 = extra env assignments; sets RUN_OUT, RUN_RC, CALLS
  RUN_OUT=$(env -i PATH="$SANDBOX/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" STUB_DIR="$SANDBOX" \
    $1 bash "$SANDBOX/infra/90-monitoring.sh" 2>&1)
  RUN_RC=$?
  CALLS=$(cat "$SANDBOX/calls.log")
}

policy_file() {  # $1 = displayName -> path of the last policy file sent with that name
  local f
  for f in $(ls -r "$SANDBOX"/policy_files/*.json 2>/dev/null); do
    [[ "$(jq -r .displayName "$f")" == "$1" ]] && { echo "$f"; return; }
  done
}

metric_filter() {  # $1 = log metric name -> the --log-filter it was created with
  grep "logging metrics create $1 " <<<"$CALLS" | sed 's/.*--log-filter=//; s/ --project test-proj$//'
}

POLICIES=("Cloud Run Job Errors (dbt-prod-run)" "Cloud Scheduler Job Errors (dbt-prod-nightly)" \
  "BigQuery Job Errors (Production)" "Cloud Run Job Failures (dbt-prod-run)")

seed_existing_policies() {
  local i=1 p
  for p in "${POLICIES[@]}"; do echo "projects/test-proj/alertPolicies/10$i|$p" >> "$SANDBOX/policies.txt"; i=$((i + 1)); done
}

echo "scenario 1: fresh project creates every metric and policy"
make_sandbox
run_case ''
assert_eq "$RUN_RC" "0" "script exits 0"
assert_contains "$RUN_OUT" "Monitoring alerts ensured." "script runs to the end"
assert_eq "$(grep -c 'logging metrics create' <<<"$CALLS")" "4" "creates 4 log metrics"
assert_eq "$(grep -c 'policies create' <<<"$CALLS")" "4" "creates 4 policies"
assert_eq "$(grep -c 'policies update' <<<"$CALLS")" "0" "updates none"
all_valid=1
for f in "$SANDBOX"/policy_files/*.json; do jq -e . "$f" >/dev/null 2>&1 || { all_valid=0; echo "      invalid JSON: $f"; }; done
assert_eq "$all_valid" "1" "every policy file is valid JSON"

echo "scenario 2: log metric filters (#58, #59)"
f=$(metric_filter cloud_run_job_errors)
assert_contains "$f" 'NOT logName=~"cloudaudit"' "job errors exclude audit logs"
f=$(metric_filter cloud_scheduler_job_errors)
assert_not_contains "$f" "cloudaudit" "scheduler errors keep audit logs (403s on invoke)"
f=$(metric_filter bigquery_job_errors)
assert_contains "$f" "-protoPayload.status.code=14" "BigQuery errors exclude code 14 (UNAVAILABLE)"
assert_contains "$f" "-protoPayload.status.code=6" "BigQuery errors exclude code 6 (ALREADY_EXISTS)"
assert_contains "$f" '-protoPayload.status.message:"Google Sheets service overloaded"' "BigQuery errors exclude Sheets overload by message"
assert_not_contains "$f" "status.code=3" "BigQuery errors still count code 3 (real SQL errors)"
assert_contains "$(metric_filter cloud_run_job_failures)" "exited with status" "task-level failure metric kept for dashboards"

echo "scenario 3: job failure policy counts failed executions, not task attempts (#58)"
pf=$(policy_file "Cloud Run Job Failures (dbt-prod-run)")
cond=$(jq -c '.conditions[0].conditionThreshold' "$pf")
assert_contains "$cond" 'run.googleapis.com/job/completed_execution_count' "uses built-in execution metric"
assert_contains "$cond" 'metric.labels.result=\"failed\"' "counts result=failed"
assert_contains "$cond" 'resource.labels.job_name=\"dbt-prod-run\"' "scoped to the job"
assert_contains "$cond" 'resource.labels.location=\"us-central1\"' "scoped to the region"
assert_eq "$(jq -r '.conditions[0].conditionThreshold.aggregations[0] | [.perSeriesAligner,.crossSeriesReducer,.groupByFields[0]] | join(" ")' "$pf")" \
  "ALIGN_DELTA REDUCE_SUM resource.label.job_name" "ALIGN_DELTA + REDUCE_SUM by job_name"
assert_not_contains "$cond" "logging.googleapis.com/user/cloud_run_job_failures" "no longer alerts on the log-text metric"

echo "scenario 4: runbooks"
pf=$(policy_file "BigQuery Job Errors (Production)")
assert_contains "$(jq -r '.documentation.content' "$pf")" "INFORMATION_SCHEMA.JOBS_BY_PROJECT" "BigQuery runbook says how to spot a retried transient"
assert_eq "$(jq -r '.documentation.mimeType' "$pf")" "text/markdown" "runbook is markdown"
pf=$(policy_file "Cloud Run Job Failures (dbt-prod-run)")
assert_contains "$(jq -r '.documentation.content' "$pf")" "after all task retries" "failure runbook explains execution-level semantics"
pf=$(policy_file "Cloud Run Job Errors (dbt-prod-run)")
assert_eq "$(jq 'has("documentation")' "$pf")" "false" "policies without a runbook carry no documentation key"

echo "scenario 5: re-run updates existing policies in place (#54)"
make_sandbox; seed_existing_policies
run_case ''
assert_eq "$RUN_RC" "0" "script exits 0"
assert_contains "$RUN_OUT" "Monitoring alerts ensured." "script runs to the end"
assert_eq "$(grep -c 'policies create' <<<"$CALLS")" "0" "creates none"
assert_eq "$(grep -c 'policies update' <<<"$CALLS")" "4" "updates all 4"
assert_contains "$CALLS" "policies update projects/test-proj/alertPolicies/103 --policy-from-file=" "updates by resource name"
assert_not_contains "$RUN_OUT" "Policy exists" "no silent no-op"
assert_contains "$(jq -c '.conditions[0].conditionThreshold.filter' "$(policy_file "Cloud Run Job Failures (dbt-prod-run)")")" \
  "completed_execution_count" "existing failure policy is switched to the execution metric"

echo "scenario 6: re-run without NOTIFICATION_CHANNELS keeps the live policy's channels"
make_sandbox; seed_existing_policies
run_case 'STUB_CUR_CHANNELS=["projects/test-proj/notificationChannels/77"]'
assert_eq "$(jq -c '.notificationChannels' "$(policy_file "BigQuery Job Errors (Production)")")" \
  '["projects/test-proj/notificationChannels/77"]' "update file carries the existing channel"
assert_not_contains "$CALLS" "set-notification-channels" "does not pass channel flags"

echo "scenario 7: re-run with NOTIFICATION_CHANNELS sets them"
make_sandbox; seed_existing_policies
run_case 'NOTIFICATION_CHANNELS=projects/test-proj/notificationChannels/9'
assert_contains "$CALLS" "--set-notification-channels=projects/test-proj/notificationChannels/9" "update sets configured channels"
assert_not_contains "$CALLS" "policies describe" "no need to read live channels"

echo "scenario 8: duplicate display names warn and update one"
make_sandbox; seed_existing_policies
echo "projects/test-proj/alertPolicies/999|BigQuery Job Errors (Production)" >> "$SANDBOX/policies.txt"
run_case ''
assert_contains "$RUN_OUT" '2 policies named "BigQuery Job Errors (Production)"' "warns about the duplicate"
assert_contains "$RUN_OUT" "projects/test-proj/alertPolicies/999" "lists the duplicate's name"
assert_eq "$(grep -c 'policies update projects/test-proj/alertPolicies/103 ' <<<"$CALLS")" "1" "updates the first match"
assert_not_contains "$CALLS" "policies update projects/test-proj/alertPolicies/999" "leaves the duplicate alone"

echo "scenario 9: existing log metric with an old filter is updated"
make_sandbox; seed_existing_policies
echo '{"filter":"resource.type=\"cloud_run_job\" severity>=ERROR","description":"old"}' > "$SANDBOX/metrics/cloud_run_job_errors"
run_case ''
assert_contains "$CALLS" "logging metrics update cloud_run_job_errors" "updates the drifted metric"

echo "results: passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
