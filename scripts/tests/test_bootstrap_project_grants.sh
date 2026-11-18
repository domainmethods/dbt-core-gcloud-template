#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox"/{infra,scripts,bin}
cp "$repo/infra/10-bootstrap.sh" "$sandbox/infra/"
cp -R "$repo/scripts/lib" "$sandbox/scripts/"

cat > "$sandbox/infra/.env" <<'ENV'
PROJECT_ID=fixture-project
PROJECT_NUMBER=123456
REGION=us-central1
BQ_LOCATION=US
AR_REPO=dbt
PROD_DATASET=analytics
DBT_DOCS_BUCKET=fixture-docs
CI_SA_ID=dbt-ci
PROD_SA_ID=dbt-prod
SCHEDULER_SA_ID=dbt-scheduler
MANAGE_DATASET_IAM=false
OPERATOR_EMAIL=operator@example.test
OPERATOR_GRANT_ACTAS=false
DEV_GROUP_EMAIL=developers@example.test
EXTRA_PROJECT_ROLES=roles/dataform.codeCreator
ENV
echo 'developer@example.test,analytics_developer' > "$sandbox/infra/devs.txt"

cat > "$sandbox/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "gcloud $*" >> "$FIXTURE/calls"
case "$*" in
  'projects add-iam-policy-binding '*) printf '%s %s %s\n' "${5#--role=}" "${4#--member=}" "$3" >> "$FIXTURE/grants" ;;
  'resource-manager org-policies describe '*) echo '{"booleanPolicy":{}}' ;;
  'projects describe '*) echo 987654 ;;
  'storage buckets describe '*) echo '{"uniform_bucket_level_access":true}' ;;
  'storage buckets get-iam-policy '*) cat "$FIXTURE/bucket.json" ;;
  'storage buckets set-iam-policy '*) cp "$5" "$FIXTURE/bucket.json" ;;
  *'get-iam-policy'*) echo '{"bindings":[]}' ;;
esac
STUB
cat > "$sandbox/bin/bq" <<'STUB'
#!/usr/bin/env bash
echo "bq $*" >> "$FIXTURE/calls"
STUB
chmod +x "$sandbox"/bin/*
for tool in bash awk cat cp diff dirname jq mktemp rm; do
  ln -s "$(command -v "$tool")" "$sandbox/bin/$tool"
done

run_bootstrap() {
  : > "$sandbox/calls"
  : > "$sandbox/grants"
  echo '{"etag":"fixture-etag","version":3,"bindings":[]}' > "$sandbox/bucket.json"
  env -i PATH="$sandbox/bin" FIXTURE="$sandbox" "$@" \
    bash "$sandbox/infra/10-bootstrap.sh" > "$sandbox/output" 2>&1 || {
    cat "$sandbox/output" >&2
    exit 1
  }
}

# Members granted a role; with GRANT_PROJECT set, only grants made in that project.
assert_grants() {
  local role="$1" actual expected=
  shift
  actual=$(awk -v role="$role" -v project="${GRANT_PROJECT:-}" \
    '$1 == role && (project == "" || $3 == project) {print $2}' "$sandbox/grants" | sort -u)
  if (( $# )); then expected=$(printf '%s\n' "$@" | sort -u); fi
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL %s\nExpected:\n%s\nRecorded:\n%s\n' "$role" "$expected" "$actual" >&2
    exit 1
  fi
}

ci=serviceAccount:dbt-ci@fixture-project.iam.gserviceaccount.com
prod=serviceAccount:dbt-prod@fixture-project.iam.gserviceaccount.com
operator=user:operator@example.test
group=group:developers@example.test
developer=user:developer@example.test

echo "scenario: default project grants"
run_bootstrap
for role in user jobUser readSessionUser dataViewer; do
  assert_grants "roles/bigquery.$role" "$ci" "$prod" "$operator" "$group" "$developer"
done
assert_grants roles/artifactregistry.writer "$prod"
assert_grants roles/bigquery.dataEditor
assert_grants roles/dataform.codeCreator
assert_grants roles/aiplatform.notebookRuntimeUser
assert_grants roles/aiplatform.colabEnterpriseUser
if grep -Eq 'services enable (notebooks|dataform)\.googleapis\.com' "$sandbox/calls"; then
  echo "FAIL optional APIs enabled by default" >&2
  exit 1
fi

echo "scenario: editor and extra roles opt in for dbt service accounts"
run_bootstrap PROD_READ_ONLY=false ENABLE_EXTRA_PROJECT_ROLES=true
assert_grants roles/artifactregistry.writer "$prod"
assert_grants roles/bigquery.dataEditor "$ci" "$prod"
assert_grants roles/dataform.codeCreator "$ci" "$prod"
echo "scenario: single-project installs grant everything in PROJECT_ID"
run_bootstrap PROD_READ_ONLY=false ENABLE_EXTRA_PROJECT_ROLES=true
if awk '$3 != "fixture-project"' "$sandbox/grants" | grep -q .; then
  echo "FAIL grant outside PROJECT_ID in a single-project install" >&2
  exit 1
fi

echo "scenario: split-project grants put the prod runner's roles in PROD_PROJECT_ID (#107)"
run_bootstrap PROD_PROJECT_ID=prod-project PROD_READ_ONLY=false ENABLE_EXTRA_PROJECT_ROLES=true
GRANT_PROJECT=prod-project
for role in user jobUser readSessionUser dataViewer dataEditor; do
  assert_grants "roles/bigquery.$role" "$prod"
done
assert_grants roles/dataform.codeCreator "$prod"
assert_grants roles/artifactregistry.writer "$prod"
GRANT_PROJECT=fixture-project
for role in user jobUser readSessionUser dataViewer; do
  assert_grants "roles/bigquery.$role" "$ci" "$operator" "$group" "$developer"
done
assert_grants roles/bigquery.dataEditor "$ci"
assert_grants roles/dataform.codeCreator "$ci"
unset GRANT_PROJECT
echo "bootstrap project grant tests passed"
