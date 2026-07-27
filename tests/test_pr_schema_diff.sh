#!/usr/bin/env bash
# Tests for scripts/pr_schema_diff.sh
#
# Dependency-free: requires bash 4+, jq, coreutils. No bats, no pip packages.
# Runs the real script against stubbed `bq` and `dbt` binaries on PATH.
#
# Usage: bash tests/test_pr_schema_diff.sh
#
# Note: `set -e` is deliberately NOT used. The harness inspects non-zero exit
# codes from the script under test; aborting on them would defeat the purpose.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO_ROOT/scripts/pr_schema_diff.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "    ok   - $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "    FAIL - $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

assert_eq() {
  local expected=$1 actual=$2 msg=$3
  if [[ "$expected" == "$actual" ]]; then
    pass "$msg"
  else
    fail "$msg (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local haystack=$1 needle=$2 msg=$3
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$msg"
  else
    fail "$msg (expected to find '$needle')"
  fi
}

assert_not_contains() {
  local haystack=$1 needle=$2 msg=$3
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$msg"
  else
    fail "$msg (did not expect to find '$needle')"
  fi
}

# Fixture manifest: two models in prod dataset `analytics`.
#   fct_example - exists in prod
#   stg_example - has no prod counterpart, so exercises NEW_MODEL
write_manifest() {
  cat > "$1" <<'JSON'
{
  "nodes": {
    "model.tpl.fct_example": {
      "resource_type": "model", "name": "fct_example", "alias": "fct_example",
      "database": "prodproj", "schema": "analytics",
      "unique_id": "model.tpl.fct_example"
    },
    "model.tpl.stg_example": {
      "resource_type": "model", "name": "stg_example", "alias": "stg_example",
      "database": "prodproj", "schema": "analytics",
      "unique_id": "model.tpl.stg_example"
    }
  },
  "sources": {}
}
JSON
}

# Builds an isolated sandbox and sets SANDBOX and BQ_CALL_LOG.
# $1 selects stub behaviour, consumed by the bq stub via STUB_MODE.
make_sandbox() {
  local mode=$1
  SANDBOX=$(mktemp -d)
  STUB_MODE=$mode
  BQ_CALL_LOG="$SANDBOX/bq_calls.log"
  mkdir -p "$SANDBOX/stubs" "$SANDBOX/target" "$SANDBOX/prod_state" "$SANDBOX/out"
  : > "$BQ_CALL_LOG"

  write_manifest "$SANDBOX/target/manifest.json"
  write_manifest "$SANDBOX/prod_state/manifest.json"

  cat > "$SANDBOX/stubs/dbt" <<'STUB'
#!/usr/bin/env bash
# Only `dbt ls` is exercised; every other subcommand is a no-op success.
if [[ "${1:-}" == "ls" ]]; then
  printf 'fct_example\nstg_example\n'
fi
exit 0
STUB

  cat > "$SANDBOX/stubs/bq" <<'STUB'
#!/usr/bin/env bash
# Stub BigQuery CLI. Records every invocation, then answers based on the
# shape of the SQL and on STUB_MODE.
args="$*"
echo "$args" >> "$BQ_CALL_LOG"

DEV_COLS='[{"column_name":"id","ordinal_position":1,"data_type":"INT64","is_nullable":"YES"},{"column_name":"amount","ordinal_position":2,"data_type":"NUMERIC","is_nullable":"YES"}]'
PROD_COLS='[{"column_name":"id","ordinal_position":1,"data_type":"INT64","is_nullable":"YES"}]'

case "$args" in
  *TABLE_OPTIONS*)
    echo '[]' ;;

  *INFORMATION_SCHEMA.COLUMNS*)
    if [[ "$STUB_MODE" == "banner_introspect" ]]; then
      echo 'Welcome to BigQuery! Update available.'
    elif [[ "$args" == *ci_pr_1* ]]; then
      echo "$DEV_COLS"
    elif [[ "$args" == *"table_name = 'fct_example'"* ]]; then
      echo "$PROD_COLS"
    else
      echo '[]'
    fi ;;

  *"INFORMATION_SCHEMA.TABLES WHERE"*)
    if [[ "$args" == *ci_pr_1* ]]; then
      echo '[{"table_type":"BASE TABLE"}]'
    elif [[ "$args" == *"table_name = 'fct_example'"* ]]; then
      echo '[{"table_type":"BASE TABLE"}]'
    else
      echo '[]'
    fi ;;

  *INFORMATION_SCHEMA.TABLES*)
    # Dataset-wide table listing, used only by the orphan block.
    case "$STUB_MODE" in
      denied)        echo 'BigQuery error: Access Denied' >&2; exit 1 ;;
      has_orphan)    echo '[{"table_name":"legacy_junk","table_type":"BASE TABLE"}]' ;;
      banner_tables) echo 'Welcome to BigQuery! Update available.' ;;
      *)             echo '[{"table_name":"fct_example","table_type":"BASE TABLE"}]' ;;
    esac ;;

  *)
    echo '[]' ;;
esac
exit 0
STUB

  chmod +x "$SANDBOX/stubs/bq" "$SANDBOX/stubs/dbt"
}

# Runs the script under test inside the sandbox. Returns its exit code and
# sets RUN_STDOUT / RUN_STDERR. stdin is closed to mimic GitHub Actions.
run_diff() {
  local rc
  RUN_STDOUT=$(
    cd "$SANDBOX" || exit 99
    PATH="$SANDBOX/stubs:$PATH" \
    STUB_MODE="$STUB_MODE" \
    BQ_CALL_LOG="$BQ_CALL_LOG" \
    DBT_GCP_PROJECT_CI=ciproj \
    DBT_BQ_DATASET=ci_pr_1 \
    DBT_GCP_PROJECT_PROD=prodproj \
    DBT_BQ_DATASET_PROD=analytics \
    ARTIFACT_DIR="$SANDBOX/out" \
      bash "$SCRIPT" 2>"$SANDBOX/stderr.txt" </dev/null
  )
  rc=$?
  RUN_STDERR=$(cat "$SANDBOX/stderr.txt")
  return $rc
}

cleanup() { [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"; }

scenario_1() {
  echo "  scenario 1: zero orphans (every prod table covered by the manifest)"
  make_sandbox ok_no_orphans
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0 when no orphans are found"
  assert_contains "$(cat "$SANDBOX/out/orphans.md")" "Found 0 orphan(s)." "reports zero orphans"
  cleanup
}

scenario_2() {
  echo "  scenario 2: prod dataset unreadable"
  make_sandbox denied
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0 when the prod dataset cannot be listed"
  assert_contains "$(cat "$SANDBOX/out/orphans.md")" "Could not list tables" \
    "keeps the unreadable-dataset diagnostic in orphans.md"
  cleanup
}

scenario_3() {
  echo "  scenario 3: an orphan is present"
  make_sandbox has_orphan
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0 when an orphan is found"
  local report; report=$(cat "$SANDBOX/out/orphans.md")
  assert_contains "$report" "Found 1 orphan(s)." "counts the orphan"
  assert_contains "$report" "prodproj.analytics.legacy_junk" "names the orphan"
  cleanup
}

scenario_4() {
  echo "  scenario 4: bq returns a non-JSON banner for the table listing"
  make_sandbox banner_tables
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0 when the table listing is unparseable"
  cleanup
}

echo "test_pr_schema_diff.sh"
scenario_1
scenario_2
scenario_3
scenario_4

echo ""
echo "passed: $PASS_COUNT  failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
