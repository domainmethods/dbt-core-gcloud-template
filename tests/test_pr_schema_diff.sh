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

# col_diff mode: a deliberate, non-trivial difference on fct_example.
#   added   -> created_at (dev only)
#   removed -> legacy_flag (prod only)
#   changed -> amount (NUMERIC in prod, STRING in dev)
DIFF_DEV_COLS='[{"column_name":"id","ordinal_position":1,"data_type":"INT64","is_nullable":"YES"},{"column_name":"amount","ordinal_position":2,"data_type":"STRING","is_nullable":"YES"},{"column_name":"created_at","ordinal_position":3,"data_type":"TIMESTAMP","is_nullable":"YES"}]'
DIFF_PROD_COLS='[{"column_name":"id","ordinal_position":1,"data_type":"INT64","is_nullable":"YES"},{"column_name":"amount","ordinal_position":2,"data_type":"NUMERIC","is_nullable":"YES"},{"column_name":"legacy_flag","ordinal_position":3,"data_type":"BOOL","is_nullable":"YES"}]'

is_dev() { [[ "$args" == *ci_pr_1* ]]; }

case "$args" in
  *TABLE_OPTIONS*)
    echo '[]' ;;

  *INFORMATION_SCHEMA.COLUMNS*)
    if [[ "$STUB_MODE" == "banner_introspect" ]]; then
      echo 'Welcome to BigQuery! Update available.'
    elif [[ "$STUB_MODE" == "dev_denied" ]] && is_dev; then
      # Denial printed on stdout with exit 0: exercises the "Access Denied"
      # substring branch of the classifier.
      echo 'BigQuery error in query operation: Access Denied: Dataset ciproj:ci_pr_1'
    elif [[ "$STUB_MODE" == "prod_denied" ]] && ! is_dev; then
      # Denial on stderr with exit 1: exercises the empty-output branch.
      echo 'BigQuery error in query operation: Access Denied: Dataset prodproj:analytics' >&2
      exit 1
    elif is_dev; then
      if [[ "$STUB_MODE" == "col_diff" && "$args" == *"table_name = 'fct_example'"* ]]; then
        echo "$DIFF_DEV_COLS"
      else
        echo "$DEV_COLS"
      fi
    elif [[ "$args" == *"table_name = 'fct_example'"* ]]; then
      if [[ "$STUB_MODE" == "col_diff" ]]; then
        echo "$DIFF_PROD_COLS"
      else
        echo "$PROD_COLS"
      fi
    else
      echo '[]'
    fi ;;

  *"INFORMATION_SCHEMA.TABLES WHERE"*)
    if [[ "$STUB_MODE" == "prod_type_denied" ]] && ! is_dev; then
      # COLUMNS succeeds, TABLES is denied: without classification this used to
      # surface as NEW_MODEL ("nothing to compare") instead of a failure.
      echo 'BigQuery error in query operation: Access Denied: Dataset prodproj:analytics' >&2
      exit 1
    elif is_dev; then
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

scenario_5() {
  echo "  scenario 5: regression guard — models actually resolve (Defect B)"
  make_sandbox ok_no_orphans
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0"

  # Every model returned by `dbt ls` must produce exactly one summary row and
  # zero resolution warnings. Models with no prod counterpart satisfy the row
  # requirement with status NEW_MODEL; the assertion is on row count and
  # warning absence, not on status value.
  assert_not_contains "$RUN_STDOUT" "Could not resolve model" \
    "no model fails to resolve in the PR manifest"

  local summary rows
  summary=$(cat "$SANDBOX/out/schema-summary.md")
  rows=$(grep -c '^| [a-z]' <<< "$summary")
  assert_eq 2 "$rows" "summary table has one row per selected model"
  assert_contains "$summary" "fct_example" "fct_example appears in the summary"
  assert_contains "$summary" "stg_example" "stg_example appears in the summary"
  assert_contains "$summary" "NEW_MODEL" "model with no prod counterpart is NEW_MODEL"
  cleanup
}

scenario_6() {
  echo "  scenario 6: bq returns a non-JSON banner for column introspection"
  make_sandbox banner_introspect
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0 when introspection output is unparseable"

  # The requirement is that unparseable output is never reported as a clean
  # diff. The exact status string is pinned here once observed.
  local summary; summary=$(cat "$SANDBOX/out/schema-summary.md")
  assert_contains "$summary" "NON_JSON" "unparseable introspection is marked NON_JSON"
  cleanup
}

# Returns the SUMMARY| line emitted for one model.
summary_line_for() { grep -m1 "^SUMMARY|model=$1|" "$SANDBOX/out/$1.txt"; }

# Returns the markdown table row for one model.
table_row_for() { grep -m1 "^| $1 " "$SANDBOX/out/schema-summary.md"; }

scenario_7() {
  echo "  scenario 7: the diff actually diffs (Critical: jq -n)"
  make_sandbox col_diff
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0"

  # fct_example: 1 added, 1 removed, 1 type-changed. These are the numbers the
  # whole report exists to produce; without `jq -n` on compute_column_diff they
  # come out blank and every assertion below fails.
  local line row detail
  line=$(summary_line_for fct_example)
  row=$(table_row_for fct_example)
  detail=$(cat "$SANDBOX/out/fct_example.txt")

  assert_contains "$line" "|added=1|removed=1|changed=1|" \
    "SUMMARY line carries the real column counts"
  assert_contains "$row" "| 1 | 1 | 1 |" \
    "markdown table row carries the real column counts"
  assert_contains "$detail" "Columns added (1):" "added header is populated"
  assert_contains "$detail" "+ created_at" "names the added column"
  assert_contains "$detail" "- legacy_flag" "names the removed column"
  assert_contains "$detail" "* amount: dev=(STRING/YES) prod=(NUMERIC/YES)" \
    "names the type-changed column with both types"
  # opt_changes is the last field, so there is no trailing pipe.
  assert_contains "$line" "|opt_changes=0" "meta diff emits an option-change count"

  # NEW_MODEL rows must carry real counts too, not blanks.
  assert_contains "$(summary_line_for stg_example)" "|added=2|removed=0|changed=0|" \
    "NEW_MODEL row reports every dev column as added"
  cleanup
}

scenario_8() {
  echo "  scenario 8: failure rows carry literal 0 counts, never blanks"
  make_sandbox banner_introspect
  run_diff
  assert_contains "$(summary_line_for fct_example)" "|status=NON_JSON|" \
    "banner output is classified NON_JSON"
  assert_contains "$(summary_line_for fct_example)" "|added=0|removed=0|changed=0|" \
    "NON_JSON row carries literal 0 counts"
  cleanup

  make_sandbox prod_denied
  run_diff
  assert_contains "$(summary_line_for fct_example)" "|status=AUTH_ERROR|" \
    "unreadable prod columns are classified AUTH_ERROR"
  assert_contains "$(summary_line_for fct_example)" "|added=0|removed=0|changed=0|" \
    "AUTH_ERROR row carries literal 0 counts"
  cleanup
}

scenario_9() {
  echo "  scenario 9: the ordering invariant holds on every path"
  # Dev-side denial: previously dev_cols normalized to [] and every prod column
  # was reported as removed under a clean OK.
  make_sandbox dev_denied
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0 when the dev side is unreadable"
  local line; line=$(summary_line_for fct_example)
  assert_contains "$line" "|status=AUTH_ERROR|" "a dev-side denial is classified AUTH_ERROR"
  assert_not_contains "$line" "|status=OK|" "a dev-side denial is never reported as OK"
  assert_contains "$line" "|removed=0|" "a dev-side denial does not report phantom removals"
  cleanup

  # Prod TABLES denial while COLUMNS succeeds: previously downgraded to
  # NEW_MODEL, i.e. "brand-new model, nothing to compare".
  make_sandbox prod_type_denied
  run_diff; rc=$?
  assert_eq 0 "$rc" "exits 0 when the prod table-type query is denied"
  local summary; summary=$(cat "$SANDBOX/out/schema-summary.md")
  assert_contains "$(summary_line_for fct_example)" "|status=AUTH_ERROR|" \
    "a denied prod table-type query is classified AUTH_ERROR"
  assert_not_contains "$summary" "NEW_MODEL" \
    "a permissions failure is never downgraded to NEW_MODEL"
  cleanup
}

scenario_10() {
  echo "  scenario 10: a name collision with a package resolves to one node"
  make_sandbox ok_no_orphans
  # Add a same-named model from an installed package, plus the project name.
  local mf
  for mf in "$SANDBOX/target/manifest.json" "$SANDBOX/prod_state/manifest.json"; do
    jq '.metadata = {"project_name": "tpl"}
        | .nodes["model.tpl.fct_example"].package_name = "tpl"
        | .nodes["model.tpl.stg_example"].package_name = "tpl"
        | .nodes["model.some_pkg.fct_example"] = {
            "resource_type": "model", "name": "fct_example",
            "alias": "pkg_fct_example", "database": "pkgproj",
            "schema": "pkg_schema", "package_name": "some_pkg",
            "unique_id": "model.some_pkg.fct_example"
          }' "$mf" > "$mf.tmp" && mv "$mf.tmp" "$mf"
  done
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0 on a colliding model name"
  # The project's own node must win: its alias is fct_example, not the
  # package's pkg_fct_example, and no query may carry a concatenated name.
  assert_contains "$(cat "$SANDBOX/out/fct_example.txt")" "Dev:  ciproj.ci_pr_1.fct_example" \
    "the project's own node wins over the package node"
  assert_not_contains "$(cat "$BQ_CALL_LOG")" "pkg_fct_example" \
    "the package node is not queried"
  local rows; rows=$(grep -c '^| [a-z]' "$SANDBOX/out/schema-summary.md")
  assert_eq 2 "$rows" "still one summary row per selected model"
  cleanup
}

echo "test_pr_schema_diff.sh"
scenario_1
scenario_2
scenario_3
scenario_4
scenario_5
scenario_6
scenario_7
scenario_8
scenario_9
scenario_10

echo ""
echo "passed: $PASS_COUNT  failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
