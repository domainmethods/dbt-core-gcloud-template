#!/usr/bin/env bash
# Tests infra/90-monitoring.sh policy creation including optional BQ bytes-billed alert.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir "$SANDBOX/bin" "$SANDBOX/policies"
cp "$REPO_ROOT/infra/90-monitoring.sh" "$SANDBOX/"
for tool in awk bash cat cp dirname grep jq mktemp rm tr; do
  ln -s "$(command -v "$tool")" "$SANDBOX/bin/$tool"
done

cat > "$SANDBOX/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> calls.log
case "$*" in
  'beta monitoring policies --help')
    exit 0
    ;;
  'logging metrics describe '*)
    exit 1
    ;;
  'logging metrics create '*)
    exit 0
    ;;
  'beta monitoring policies list '*)
    cat existing_policies.txt 2>/dev/null || true
    ;;
  'beta monitoring policies create '*)
    policy_file=""
    for arg in "$@"; do
      case "$arg" in
        --policy-from-file=*) policy_file="${arg#--policy-from-file=}" ;;
      esac
    done
    [[ -n "$policy_file" ]]
    name=$(jq -r '.displayName' "$policy_file")
    safe=$(printf '%s' "$name" | tr -cs 'A-Za-z0-9._-' '_')
    cp "$policy_file" "policies/${safe}.json"
    echo "$name" >> created_policies.txt
    ;;
  *)
    echo "Unexpected gcloud command: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$SANDBOX/bin/gcloud"

write_env() {
  local bq_gb="$1"
  cat > "$SANDBOX/.env" <<ENV
PROJECT_ID=fixture-project
REGION=us-west1
PROD_SA_ID=dbt-prod
NOTIFICATION_CHANNELS=projects/fixture-project/notificationChannels/12345
BQ_BYTES_SCANNED_ALERT_GB=${bq_gb}
ENV
}

run_script() {
  : > "$SANDBOX/calls.log"
  : > "$SANDBOX/created_policies.txt"
  : > "$SANDBOX/existing_policies.txt"
  rm -f "$SANDBOX"/policies/*.json
  (cd "$SANDBOX" && env -i PATH="$SANDBOX/bin" bash "$SANDBOX/90-monitoring.sh")
}

# 1. Unset BQ_BYTES_SCANNED_ALERT_GB skips bytes-billed alert
write_env ""
run_script > /dev/null
test "$(wc -l < "$SANDBOX/created_policies.txt")" -eq 4
if grep -q 'BigQuery Bytes Billed' "$SANDBOX/created_policies.txt"; then
  echo "Bytes-billed alert should be skipped when unset" >&2
  exit 1
fi

# 2. Zero BQ_BYTES_SCANNED_ALERT_GB skips bytes-billed alert
write_env "0"
run_script > /dev/null
test "$(wc -l < "$SANDBOX/created_policies.txt")" -eq 4

# 3. Positive integer creates exact BigQuery Bytes Billed alert policy
write_env "25"
run_script > /dev/null
test "$(wc -l < "$SANDBOX/created_policies.txt")" -eq 5
grep -Fqx 'BigQuery Bytes Billed (>25 GB/hr)' "$SANDBOX/created_policies.txt"
jq -e '
  .displayName == "BigQuery Bytes Billed (>25 GB/hr)" and
  .conditions[0].conditionThreshold.filter == "metric.type=\"bigquery.googleapis.com/query/scanned_bytes_billed\" resource.type=\"global\"" and
  .conditions[0].conditionThreshold.aggregations[0].alignmentPeriod == "3600s" and
  .conditions[0].conditionThreshold.aggregations[0].perSeriesAligner == "ALIGN_SUM" and
  .conditions[0].conditionThreshold.aggregations[0].crossSeriesReducer == "REDUCE_SUM" and
  .conditions[0].conditionThreshold.comparison == "COMPARISON_GT" and
  .conditions[0].conditionThreshold.thresholdValue == 25000000000 and
  .conditions[0].conditionThreshold.duration == "0s"
' "$SANDBOX/policies/BigQuery_Bytes_Billed_25_GB_hr_.json" > /dev/null

# 4. Invalid non-integer fails fast
write_env "25gb"
if run_script > /dev/null 2>&1; then
  echo "Invalid BQ_BYTES_SCANNED_ALERT_GB should fail" >&2
  exit 1
fi

echo "Monitoring tests passed."
