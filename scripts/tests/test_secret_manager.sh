#!/usr/bin/env bash
# Tests for scripts/prod_secrets.sh (PROD_SECRETS parsing) and
# infra/12-secret-manager.sh (create secrets, grant the prod SA access) (#32).
# Dependency-free: bash, coreutils, jq. Stubs gcloud on PATH. No `set -e`.
#
# Usage: bash scripts/tests/test_secret_manager.sh
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "    ok   - $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "    FAIL - $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
assert_contains() { [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 (missing '$2')"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] && pass "$3" || fail "$3 (unexpected '$2')"; }
assert_eq() { [[ "$1" == "$2" ]] && pass "$3" || fail "$3 (got '$1', want '$2')"; }

echo "scenario 1: prod_secrets_flag adds :latest and keeps pinned versions"
# shellcheck source=../prod_secrets.sh
source "$REPO_ROOT/scripts/prod_secrets.sh"
assert_eq "$(prod_secrets_flag 'API_KEY=api-key,DB_PASS=db-pass:3')" "API_KEY=api-key:latest,DB_PASS=db-pass:3" "flag value"
assert_eq "$(prod_secrets_flag ' API_KEY = api-key , ')" "API_KEY=api-key:latest" "spaces and a trailing comma are tolerated"
assert_eq "$(prod_secret_names 'API_KEY=api-key,DB_PASS=db-pass:3' | tr '\n' ' ')" "api-key db-pass " "secret names, versions stripped"
for bad in 'API_KEY' 'api_key=x' 'API_KEY=bad/name' 'API_KEY=x:v2' 'A=x,A=y'; do
  out=$(prod_secrets_flag "$bad" 2>&1); rc=$?
  assert_eq "$rc" "2" "rejects '$bad'"
done
assert_contains "$(prod_secrets_flag 'API_KEY' 2>&1)" "ENV_VAR=secret-name" "error shows the expected format"

# Sandbox: $SANDBOX/infra/{12-secret-manager.sh,.env}, $SANDBOX/scripts/prod_secrets.sh,
# a gcloud stub on PATH. State the stub reads:
#   secrets/<name>          exists → secret exists; holds its IAM policy JSON
#   versions/<name>         exists → secret has an enabled version
make_sandbox() {
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/bin" "$SANDBOX/infra" "$SANDBOX/scripts" "$SANDBOX/secrets" "$SANDBOX/versions"
  cp "$REPO_ROOT/infra/12-secret-manager.sh" "$SANDBOX/infra/"
  cp "$REPO_ROOT/scripts/prod_secrets.sh" "$SANDBOX/scripts/"
  printf 'PROJECT_ID=test-proj\nPROD_SA_ID=dbt-prod\n' > "$SANDBOX/infra/.env"
  : > "$SANDBOX/calls.log"
  cat > "$SANDBOX/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "gcloud $*" >> "$STUB_DIR/calls.log"
case "$1 $2" in
  "services enable") exit 0 ;;
  "secrets describe") [[ -f "$STUB_DIR/secrets/$3" ]] && exit 0; exit 1 ;;
  "secrets create") echo '{}' > "$STUB_DIR/secrets/$3"; exit 0 ;;
  "secrets get-iam-policy") cat "$STUB_DIR/secrets/$3"; exit 0 ;;
  "secrets add-iam-policy-binding") exit 0 ;;
  "secrets versions") [[ "${STUB_VERSIONS_FAIL:-0}" == 1 ]] && { echo "PERMISSION_DENIED: secretmanager.versions.list" >&2; exit 1; }
    [[ "$3" == list && -f "$STUB_DIR/versions/$4" ]] && echo "projects/test-proj/secrets/$4/versions/1"; exit 0 ;;
esac
echo "unexpected gcloud call: $*" >&2; exit 3
STUB
  chmod +x "$SANDBOX/bin/gcloud"
}

run_case() {  # $1 = PROD_SECRETS value, $2 = extra env; sets RUN_OUT, RUN_RC, CALLS
  RUN_OUT=$(env -i PATH="$SANDBOX/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" STUB_DIR="$SANDBOX" \
    PROD_SECRETS="$1" ${2:-} bash "$SANDBOX/infra/12-secret-manager.sh" 2>&1)
  RUN_RC=$?
  CALLS=$(cat "$SANDBOX/calls.log")
}

SA_MEMBER="serviceAccount:dbt-prod@test-proj.iam.gserviceaccount.com"

echo "scenario 2: empty PROD_SECRETS does nothing"
make_sandbox; run_case ''
assert_eq "$RUN_RC" "0" "exits 0"
assert_eq "$CALLS" "" "no gcloud calls"

echo "scenario 3: fresh project creates each secret and grants the prod SA on it"
make_sandbox; run_case 'API_KEY=api-key,DB_PASS=db-pass:3'
assert_eq "$RUN_RC" "0" "exits 0"
assert_contains "$CALLS" "services enable secretmanager.googleapis.com" "enables the API"
assert_contains "$CALLS" "secrets create api-key --replication-policy=automatic --project test-proj" "creates api-key"
assert_contains "$CALLS" "secrets create db-pass --replication-policy=automatic --project test-proj" "creates db-pass (version stripped)"
assert_eq "$(grep -c "add-iam-policy-binding .* --member=$SA_MEMBER --role=roles/secretmanager.secretAccessor" <<<"$CALLS")" "2" "grants accessor on each secret"
assert_not_contains "$CALLS" "projects add-iam-policy-binding" "no project-wide grant"
assert_contains "$RUN_OUT" "gcloud secrets versions add api-key --data-file=-" "says how to add a value"
assert_contains "$RUN_OUT" "read -rs VALUE" "reads the value without echo or shell history"
assert_not_contains "$CALLS" "versions add" "never adds a value itself"

echo "scenario 4: re-run with secrets, grants and values in place changes nothing"
make_sandbox
for s in api-key db-pass; do
  printf '{"bindings":[{"role":"roles/secretmanager.secretAccessor","members":["%s"]}]}\n' "$SA_MEMBER" > "$SANDBOX/secrets/$s"
  : > "$SANDBOX/versions/$s"
done
run_case 'API_KEY=api-key,DB_PASS=db-pass:3'
assert_eq "$RUN_RC" "0" "exits 0"
assert_not_contains "$CALLS" "secrets create" "creates none"
assert_not_contains "$CALLS" "add-iam-policy-binding" "grants none"
assert_not_contains "$RUN_OUT" "versions add" "no missing-value warning"

echo "scenario 5: a bad entry stops before any change"
make_sandbox; run_case 'API_KEY=api-key,oops'
assert_eq "$RUN_RC" "2" "exits 2"
assert_eq "$CALLS" "" "no gcloud calls"

echo "scenario 5b: a failing versions list is an error, not \"no value yet\""
make_sandbox; run_case 'API_KEY=api-key' 'STUB_VERSIONS_FAIL=1'
assert_eq "$RUN_RC" "1" "exits 1"
assert_not_contains "$RUN_OUT" "has no value yet" "doesn't claim the secret is empty"
assert_contains "$RUN_OUT" "PERMISSION_DENIED" "shows gcloud's error"

# 30-deploy sandbox: gcloud stub reports the image tag as present, so nothing is
# built; PATH holds only the stub and linked tools, so no host docker or gcloud runs.
make_deploy_sandbox() {  # $1 = PROD_SECRETS value
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/bin" "$SANDBOX/infra" "$SANDBOX/scripts"
  cp "$REPO_ROOT/infra/30-deploy-cloud-run-job.sh" "$SANDBOX/infra/"
  cp "$REPO_ROOT/scripts/prod_secrets.sh" "$SANDBOX/scripts/"
  cat > "$SANDBOX/infra/.env" <<ENV
PROJECT_ID=test-proj
REGION=us-central1
AR_REPO=dbt
IMAGE_NAME=dbt
IMAGE_TAG=v1
PROD_SA_ID=dbt-prod
PROD_DATASET=analytics
BQ_LOCATION=US
PROD_SECRETS=$1
ENV
  : > "$SANDBOX/calls.log"
  cat > "$SANDBOX/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "gcloud $*" >> "$STUB_DIR/calls.log"
case "$*" in "artifacts docker tags list"*) echo v1 ;; esac
exit 0
STUB
  chmod +x "$SANDBOX/bin/gcloud"
  local tool path
  for tool in bash env cat dirname mktemp rm grep sed tr; do
    path=$(command -v "$tool" 2>/dev/null) || continue
    ln -s "$path" "$SANDBOX/bin/$tool"
  done
}
run_deploy() {
  RUN_OUT=$(env -i PATH="$SANDBOX/bin" STUB_DIR="$SANDBOX" HOME="$SANDBOX" \
    bash "$SANDBOX/infra/30-deploy-cloud-run-job.sh" 2>&1)
  RUN_RC=$?
  CALLS=$(cat "$SANDBOX/calls.log")
}

echo "scenario 5c: 30-deploy mounts PROD_SECRETS with --set-secrets"
make_deploy_sandbox 'API_KEY=api-key'; run_deploy
assert_eq "$RUN_RC" "0" "exits 0"
assert_contains "$(grep 'run jobs deploy' <<<"$CALLS")" "--set-secrets=API_KEY=api-key:latest" "passes --set-secrets"

echo "scenario 5d: 30-deploy without PROD_SECRETS passes no --set-secrets"
make_deploy_sandbox ''; run_deploy
assert_eq "$RUN_RC" "0" "exits 0"
assert_contains "$CALLS" "run jobs deploy" "deploys"
assert_not_contains "$CALLS" "--set-secrets" "no --set-secrets"

echo "scenario 6: the script parses under /bin/bash (3.2 on macOS)"
/bin/bash -n "$REPO_ROOT/infra/12-secret-manager.sh" && /bin/bash -n "$REPO_ROOT/scripts/prod_secrets.sh" \
  && pass "bash -n clean" || fail "bash -n failed"

echo "results: passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
