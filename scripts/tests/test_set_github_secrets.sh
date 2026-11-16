#!/usr/bin/env bash
# Tests for infra/25-set-github-secrets.sh: an optional value emptied in .env
# deletes its GitHub secret instead of leaving a stale one for release.yml.
# Dependency-free: bash, coreutils. Stubs gh on PATH. No `set -e`.
#
# Usage: bash scripts/tests/test_set_github_secrets.sh
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "    ok   - $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "    FAIL - $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
assert_contains() { [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 (missing '$2')"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] && pass "$3" || fail "$3 (unexpected '$2')"; }
assert_eq() { [[ "$1" == "$2" ]] && pass "$3" || fail "$3 (got '$1', want '$2')"; }

HOST_TOOLS="bash env cat dirname mktemp rm grep sed tr"

# Sandbox: $SANDBOX/{infra/25-set-github-secrets.sh,infra/.env,bin/gh}. gh logs
# every call; `gh secret delete` answers per STUB_GH_DELETE: ok (default),
# 404 (secret not set) or 500 (any other failure).
make_sandbox() {  # $1 = extra .env lines
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/bin" "$SANDBOX/infra"
  cp "$REPO_ROOT/infra/25-set-github-secrets.sh" "$SANDBOX/infra/"
  cat > "$SANDBOX/infra/.env" <<ENV
GITHUB_REPO=owner/repo
PROJECT_ID=test-proj
PROJECT_NUMBER=123
CI_SA_ID=dbt-ci
PROD_SA_ID=dbt-prod
SCHEDULER_SA_ID=dbt-scheduler
DBT_DOCS_BUCKET=docs-bucket
REGION=us-central1
AR_REPO=dbt
IMAGE_NAME=dbt
PROD_DATASET=analytics
BQ_LOCATION=US
$1
ENV
  : > "$SANDBOX/calls.log"
  cat > "$SANDBOX/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB_DIR/calls.log"
if [[ "$1 $2" == "secret delete" ]]; then
  case "${STUB_GH_DELETE:-ok}" in
    404) echo "failed to delete secret $3: HTTP 404: Not Found (https://api.github.com/repos/owner/repo/actions/secrets/$3)" >&2; exit 1 ;;
    500) echo "failed to delete secret $3: HTTP 500: Server Error" >&2; exit 1 ;;
  esac
fi
exit 0
STUB
  chmod +x "$SANDBOX/bin/gh"
  local tool path
  for tool in $HOST_TOOLS; do
    path=$(command -v "$tool" 2>/dev/null) || continue
    ln -s "$path" "$SANDBOX/bin/$tool"
  done
}

run_script() {  # $1 = extra env; sets RUN_OUT, RUN_RC, CALLS
  RUN_OUT=$(env -i PATH="$SANDBOX/bin" STUB_DIR="$SANDBOX" HOME="$SANDBOX" $1 \
    bash "$SANDBOX/infra/25-set-github-secrets.sh" 2>&1)
  RUN_RC=$?
  CALLS=$(cat "$SANDBOX/calls.log")
}

# Optional values: empty in .env means "use the default", so the secret must go.
OPTIONAL_KEYS="SCHED_CRON"

for key in $OPTIONAL_KEYS; do
  echo "scenario: $key set → secret set"
  make_sandbox "$key=x"; run_script ''
  assert_eq "$RUN_RC" "0" "exits 0"
  assert_contains "$CALLS" "gh secret set $key -R owner/repo --body x" "sets $key"

  echo "scenario: $key emptied, GitHub secret exists → deleted"
  make_sandbox "$key="; run_script ''
  assert_eq "$RUN_RC" "0" "exits 0"
  assert_contains "$CALLS" "gh secret delete $key -R owner/repo" "deletes $key"
  assert_not_contains "$CALLS" "gh secret set $key " "doesn't set $key"
  assert_contains "$RUN_OUT" "Deleted secret $key" "says it deleted $key"

  echo "scenario: $key empty, no GitHub secret → tolerated"
  make_sandbox ""; run_script 'STUB_GH_DELETE=404'
  assert_eq "$RUN_RC" "0" "exits 0"
  assert_contains "$RUN_OUT" "$key not set" "says there was nothing to delete"

  echo "scenario: $key empty, delete fails for another reason → error"
  make_sandbox ""; run_script 'STUB_GH_DELETE=500'
  assert_eq "$RUN_RC" "1" "exits 1"
  assert_contains "$RUN_OUT" "HTTP 500" "shows gh's error"
done

echo "scenario: an empty required value is skipped, never deleted"
make_sandbox "DBT_DOCS_BUCKET=" ; run_script ''
assert_eq "$RUN_RC" "0" "exits 0"
assert_not_contains "$CALLS" "gh secret delete DBT_DOCS_BUCKET" "keeps DBT_DOCS_BUCKET"
assert_contains "$RUN_OUT" "Skipping DBT_DOCS_BUCKET (empty)" "says it skipped it"

echo "results: passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
