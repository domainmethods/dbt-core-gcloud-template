#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox"/{infra,scripts/utils,bin}
cp "$repo/infra/10-bootstrap.sh" "$sandbox/infra/"
cp "$repo/scripts/create_bq_dataset.sh" "$sandbox/scripts/"
cp "$repo/scripts/utils/create-dev-dataset.sh" "$sandbox/scripts/utils/"
cp -R "$repo/scripts/lib" "$sandbox/scripts/"

cat > "$sandbox/infra/.env" <<'ENV'
PROJECT_ID=fixture-project
PROJECT_NUMBER=123456
REGION=us-central1
BQ_LOCATION=US
AR_REPO=dbt
PROD_DATASET=analytics
PROD_HARDEN_ACL=false
DBT_DOCS_BUCKET=fixture-docs
CI_SA_ID=dbt-ci
PROD_SA_ID=dbt-prod
SCHEDULER_SA_ID=dbt-scheduler
OPERATOR_GRANT_ACTAS=false
ENV

cat > "$sandbox/bin/bq" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "bq $*" >> "$FIXTURE/calls"
case " $* " in
  *' show '*--format=none*) ;;
  *' get-iam-policy '*) exit 1 ;;
  *' show '*)
    cat "$FIXTURE/dataset.json"
    [[ "${FAIL_READ:-}" != dataset ]]
    ;;
  *' set-iam-policy '*) exit 1 ;;
  *' update '*)
    dataset=${!#}
    source_file=
    etag=
    while (( $# )); do
      case "$1" in
        --source) source_file="$2"; shift ;;
        --source=*) source_file=${1#*=} ;;
        --etag=*) etag=${1#*=} ;;
      esac
      shift
    done
    if [[ "$dataset" != ci_pr_fixture ]]; then
      [[ -n "$etag" && "$etag" == "$(jq -r .etag "$FIXTURE/dataset.json")" ]]
    fi
    jq --slurpfile source "$source_file" '.access = $source[0].access' \
      "$FIXTURE/dataset.json" > "$FIXTURE/dataset.next"
    mv "$FIXTURE/dataset.next" "$FIXTURE/dataset.json"
    ;;
esac
STUB
cat > "$sandbox/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "gcloud $*" >> "$FIXTURE/calls"
case "$*" in
  'storage buckets get-iam-policy '*)
    cat "$FIXTURE/bucket.json"
    [[ "${FAIL_READ:-}" != bucket ]]
    ;;
  'storage buckets set-iam-policy '*)
    etag=$(jq -r .etag "$FIXTURE/bucket.json")
    [[ "$etag" != null && "$etag" == "$(jq -r .etag "$5")" ]]
    cp "$5" "$FIXTURE/bucket.json"
    ;;
  *'get-iam-policy'*) echo '{"bindings":[]}' ;;
esac
STUB
cat > "$sandbox/bin/gsutil" <<'STUB'
#!/usr/bin/env bash
echo "gsutil $*" >> "$FIXTURE/calls"
exit 1
STUB
chmod +x "$sandbox"/bin/*
for tool in bash awk cat cp diff dirname grep head jq mktemp mv rm sed tr; do
  ln -s "$(command -v "$tool")" "$sandbox/bin/$tool"
done

run_script() {
  local script="$1"
  shift
  env -i PATH="$sandbox/bin" FIXTURE="$sandbox" FAIL_READ="${fail_read:-}" \
    bash "$sandbox/$script" "$@" > "$sandbox/output" 2>&1
}

fail() {
  echo "FAIL: $*" >&2
  cat "$sandbox/output" "$sandbox/calls" >&2
  exit 1
}

reset_policies() {
  : > "$sandbox/calls"
  echo '{"etag":"dataset-etag","access":[{"role":"READER","domain":"example.test"}]}' > "$sandbox/dataset.json"
  cat > "$sandbox/bucket.json" <<'JSON'
{"etag":"bucket-etag","version":3,"bindings":[
  {"role":"roles/storage.objectAdmin","members":["group:ops@example.test"],
   "condition":{"title":"existing","expression":"resource.name.endsWith('/fixture')"}}
]}
JSON
}

assert_no_write() {
  local forbidden="$1"
  shift
  local status=0
  run_script "$@" || status=$?
  if grep -Eq "$forbidden" "$sandbox/calls"; then
    fail "script attempted to write an unknown policy"
  fi
  [[ $status != 0 ]] || fail "script accepted an unreadable or unversioned policy"
}

echo "scenario: failed dataset reads block bootstrap and developer ACL writes"
reset_policies
fail_read=dataset assert_no_write '^bq .* (update|set-iam-policy) ' infra/10-bootstrap.sh
reset_policies
fail_read=dataset assert_no_write '^bq .* (update|set-iam-policy) ' scripts/utils/create-dev-dataset.sh dev@example.test analytics_dev

echo "scenario: failed bucket read blocks replacement and fallbacks"
reset_policies
fail_read=bucket assert_no_write '^gcloud storage buckets (set|add)-iam-policy|^gsutil iam' infra/10-bootstrap.sh

echo "scenario: missing etags block policy writes"
reset_policies
echo '{"access":[]}' > "$sandbox/dataset.json"
assert_no_write '^bq .* (update|set-iam-policy) ' scripts/utils/create-dev-dataset.sh dev@example.test analytics_dev
reset_policies
echo '{"bindings":[]}' > "$sandbox/bucket.json"
assert_no_write '^gcloud storage buckets (set|add)-iam-policy|^gsutil iam' infra/10-bootstrap.sh

echo "scenario: successful updates retain etags and existing grants"
reset_policies
run_script infra/10-bootstrap.sh || fail "bootstrap failed"
run_script scripts/utils/create-dev-dataset.sh dev@example.test analytics_dev || fail "developer helper failed"
jq -e '
  .etag == "dataset-etag"
  and any(.access[]; .domain == "example.test")
  and any(.access[]; .userByEmail == "dev@example.test" and .role == "WRITER")
  and any(.access[]; .userByEmail == "dbt-ci@fixture-project.iam.gserviceaccount.com" and .role == "READER")
  and any(.access[]; .userByEmail == "dbt-prod@fixture-project.iam.gserviceaccount.com" and .role == "READER")
' "$sandbox/dataset.json" >/dev/null
jq -e '
  .etag == "bucket-etag" and .version == 3
  and any(.bindings[]; .condition.title == "existing" and .members == ["group:ops@example.test"])
  and any(.bindings[]; .condition == null and any(.members[]; startswith("serviceAccount:dbt-prod@")))
' "$sandbox/bucket.json" >/dev/null

echo "scenario: bootstrap and CI preserve complete authorized ACL entries"
reset_policies
ci_email=dbt-ci@fixture-project.iam.gserviceaccount.com
prod_email=dbt-prod@fixture-project.iam.gserviceaccount.com
cat > "$sandbox/original-acl.json" <<'JSON'
{"etag":"dataset-etag","access":[
  {"view":{"projectId":"fixture-project","datasetId":"sharing","tableId":"view_one"}},
  {"view":{"projectId":"fixture-project","datasetId":"sharing","tableId":"view_two"}},
  {"role":"READER","domain":"one.example.test"},
  {"role":"READER","domain":"two.example.test"},
  {"routine":{"projectId":"fixture-project","datasetId":"sharing","routineId":"routine_one"}},
  {"dataset":{"dataset":{"projectId":"fixture-project","datasetId":"sharing"},"targetTypes":["VIEWS"]}},
  {"role":"OWNER","specialGroup":"projectOwners"},
  {"role":"WRITER","specialGroup":"projectWriters"},
  {"role":"WRITER","userByEmail":"dbt-ci@fixture-project.iam.gserviceaccount.com"}
]}
JSON
cp "$sandbox/original-acl.json" "$sandbox/dataset.json"
echo 'PROD_HARDEN_ACL=true' >> "$sandbox/infra/.env"
run_script infra/10-bootstrap.sh || fail "bootstrap ACL hardening failed"
jq -e --slurpfile before "$sandbox/original-acl.json" --arg ci "$ci_email" --arg prod "$prod_email" '
  .access == (
    $before[0].access | map(select(.role != "WRITER"))
    + [{role:"READER", userByEmail:$ci}, {role:"WRITER", userByEmail:$prod}]
  )
' "$sandbox/dataset.json" >/dev/null || fail "bootstrap changed ACL records outside its writer and reader grants"

cp "$sandbox/original-acl.json" "$sandbox/dataset.json"
env -i PATH="$sandbox/bin" FIXTURE="$sandbox" DBT_GCP_PROJECT_CI=fixture-project DBT_BQ_LOCATION=US \
  DBT_BQ_DATASET=ci_pr_fixture CI_SA_EMAIL="$ci_email" \
  bash "$sandbox/scripts/create_bq_dataset.sh" > "$sandbox/output" 2>&1 || fail "CI ACL hardening failed"
jq -e --slurpfile before "$sandbox/original-acl.json" '
  .access == ($before[0].access | map(select(.specialGroup != "projectWriters")))
' "$sandbox/dataset.json" >/dev/null || fail "CI changed ACL records outside the projectWriters grant"
echo "policy update tests passed"
