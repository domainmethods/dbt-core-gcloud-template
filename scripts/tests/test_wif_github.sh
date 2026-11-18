#!/usr/bin/env bash
# Tests the generated federation configuration and migration with stubbed CLIs.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir "$SANDBOX/bin"
cp "$REPO_ROOT/infra/20-wif-github.sh" "$SANDBOX/"
for tool in bash cat cp dirname jq mktemp rm; do
  ln -s "$(command -v "$tool")" "$SANDBOX/bin/$tool"
done
cat > "$SANDBOX/.env" <<'ENV'
PROJECT_ID=fixture-project
PROJECT_NUMBER=123
GITHUB_REPO=example/dbt
CI_SA_ID=dbt-ci
PROD_SA_ID=dbt-prod
ENV

cat > "$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'api repos/example/dbt') echo '{"id":741,"full_name":"example/dbt"}' ;;
  'api repos/example/dbt/environments/production')
    case "${STUB_ENVIRONMENT:-custom}" in
      unprotected) echo '{"deployment_branch_policy":null}' ;;
      protected) echo '{"deployment_branch_policy":{"protected_branches":true}}' ;;
      custom) echo '{"deployment_branch_policy":{"custom_branch_policies":true}}' ;;
    esac ;;
  'api repos/example/dbt/branches/main --jq .protected') echo "${STUB_MAIN_PROTECTED:-false}" ;;
  *'environments/production/deployment-branch-policies'*) printf 'branch\tmain\n' ;;
  *) echo "Unexpected GitHub command: $*" >&2; exit 1 ;;
esac
STUB
cat > "$SANDBOX/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> gcloud.log
pool=projects/123/locations/global/workloadIdentityPools/github-pool
case "$1 $2 $3" in
  'projects describe fixture-project') echo "${STUB_PROJECT_NUMBER:-123}" ;;
  'iam workload-identity-pools describe')
    [[ "${STUB_NEW_POOL:-}" != true ]] || exit 1
    echo '{"state":"ACTIVE"}' ;;
  'iam workload-identity-pools create') ;;
  'iam workload-identity-pools providers')
    case "$4" in
      list)
        if [[ "${STUB_EXTRA_PROVIDER:-}" == true ]]; then
          echo '[{"name":"other-provider"}]'
        else
          printf '[{"name":"%s/providers/github-provider","state":"ACTIVE","oidc":{"issuerUri":"https://token.actions.githubusercontent.com"}}]\n' "$pool"
        fi ;;
      create-oidc|update-oidc) ;;
      *) echo "Unexpected provider command: $*" >&2; exit 1 ;;
    esac ;;
  'iam service-accounts get-iam-policy') cat "${4%%@*}.json" ;;
  'iam service-accounts add-iam-policy-binding')
    [[ "$4" == 'dbt-ci@fixture-project.iam.gserviceaccount.com' ]]
    printf '{"etag":"ci-etag","bindings":[{"role":"roles/iam.workloadIdentityUser","members":["principalSet://iam.googleapis.com/%s/attribute.repository/example/dbt"]}]}\n' "$pool" > dbt-ci.json ;;
  'iam service-accounts set-iam-policy')
    [[ "$4" == 'dbt-prod@fixture-project.iam.gserviceaccount.com' ]]
    jq -e '.etag == "prod-etag"' "$5" > /dev/null
    cp "$5" dbt-prod.json ;;
  *) echo "Unexpected cloud command: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$SANDBOX"/bin/{gh,gcloud}

run_script() {
  : > "$SANDBOX/gcloud.log"
  env -i PATH="$SANDBOX/bin" "$@" bash "$SANDBOX/20-wif-github.sh"
}

pool=projects/123/locations/global/workloadIdentityPools/github-pool
old="principalSet://iam.googleapis.com/$pool/attribute.repository/example/dbt"
release="principalSet://iam.googleapis.com/$pool/attribute.production_release/741"
cat > "$SANDBOX/dbt-prod.json" <<JSON
{"etag":"prod-etag","version":3,"bindings":[
  {"role":"roles/iam.workloadIdentityUser","members":["$old","group:operators@example.org"]},
  {"role":"roles/iam.serviceAccountTokenCreator","members":["user:operator@example.org"],
   "condition":{"title":"limited","expression":"request.time < timestamp('2030-01-01T00:00:00Z')"}}
]}
JSON
echo '{"etag":"ci-etag"}' > "$SANDBOX/dbt-ci.json"

run_script
grep -Fq "providers update-oidc github-provider" "$SANDBOX/gcloud.log"
grep -Fq -- "--attribute-condition=assertion.repository=='example/dbt' && assertion.repository_id=='741'" "$SANDBOX/gcloud.log"
grep -Fq "attribute.production_release=(assertion.repository=='example/dbt' && assertion.repository_id=='741' && assertion.ref=='refs/heads/main' && assertion.workflow_ref=='example/dbt/.github/workflows/release.yml@refs/heads/main' && assertion.event_name=='push' && has(assertion.environment) && assertion.environment=='production') ? assertion.repository_id : 'none'" "$SANDBOX/gcloud.log"
grep -Fq "add-iam-policy-binding dbt-ci@fixture-project.iam.gserviceaccount.com" "$SANDBOX/gcloud.log"
jq -e --arg member "$old" '.bindings[0].members == [$member]' "$SANDBOX/dbt-ci.json" > /dev/null
jq -e --arg member "$release" '
  .version == 3 and
  .bindings[0].members == ["group:operators@example.org", $member] and
  .bindings[1].members == ["user:operator@example.org"] and .bindings[1].condition.title == "limited"
' "$SANDBOX/dbt-prod.json" > /dev/null
grep -q 'environment: production' "$REPO_ROOT/.github/workflows/release.yml"

run_script
if grep -Eq 'add-iam-policy-binding|set-iam-policy' "$SANDBOX/gcloud.log"; then
  echo "A second run should leave both IAM policies unchanged" >&2
  exit 1
fi

echo '{"etag":"prod-etag"}' > "$SANDBOX/dbt-prod.json"
run_script STUB_NEW_POOL=true STUB_ENVIRONMENT=protected STUB_MAIN_PROTECTED=true
grep -Fq "providers create-oidc github-provider" "$SANDBOX/gcloud.log"
jq -e --arg member "$release" '.bindings[0].members == [$member]' "$SANDBOX/dbt-prod.json" > /dev/null

assert_preflight_fails() {
  if run_script "$@" > "$SANDBOX/output" 2>&1; then
    echo "Federation setup accepted invalid configuration ($*)" >&2
    exit 1
  fi
  if grep -Eq 'create|update-oidc|add-iam-policy-binding|set-iam-policy' "$SANDBOX/gcloud.log"; then
    echo "Federation setup changed cloud configuration before preflight passed" >&2
    exit 1
  fi
}
assert_preflight_fails STUB_ENVIRONMENT=unprotected
grep -q 'production environment' "$SANDBOX/output"
assert_preflight_fails STUB_ENVIRONMENT=protected
grep -q 'main to be a protected branch' "$SANDBOX/output"
assert_preflight_fails STUB_PROJECT_NUMBER=456
grep -q 'PROJECT_NUMBER' "$SANDBOX/output"
assert_preflight_fails STUB_EXTRA_PROVIDER=true
grep -q 'unexpected provider' "$SANDBOX/output"
echo '{}' > "$SANDBOX/dbt-prod.json"
assert_preflight_fails
grep -q 'Production IAM policy needs an etag' "$SANDBOX/output"
echo PROD_SA_ID=dbt-ci >> "$SANDBOX/.env"
assert_preflight_fails
grep -q 'different service accounts' "$SANDBOX/output"

echo "GitHub federation configuration tests passed."
