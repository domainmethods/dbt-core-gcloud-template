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
#
# $2 (optional) selects a variant:
#   base  (default) - as described above
#   moved           - fct_example lives in a different schema, i.e. the PR has
#                     relocated it relative to prod. Only `schema` changes so the
#                     table_name-keyed bq stub still answers for it.
write_manifest() {
  local path=$1 variant=${2:-base}
  cat > "$path" <<'JSON'
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
  if [[ "$variant" == "moved" ]]; then
    jq '.nodes["model.tpl.fct_example"].schema = "analytics_legacy"' \
      "$path" > "$path.tmp" && mv "$path.tmp" "$path"
  fi
}

# Builds an isolated sandbox and sets SANDBOX and BQ_CALL_LOG.
# $1 selects stub behaviour, consumed by the bq stub via STUB_MODE.
# $2 (optional) selects what prod_state/manifest.json contains:
#   same  (default) - identical to the PR manifest, so nothing has moved
#   moved           - prod has fct_example in a different schema
#   none            - no prod manifest at all, so movement is unknowable
make_sandbox() {
  local mode=$1 prod_manifest=${2:-same}
  SANDBOX=$(mktemp -d)
  STUB_MODE=$mode
  BQ_CALL_LOG="$SANDBOX/bq_calls.log"
  DBT_CALL_LOG="$SANDBOX/dbt_calls.log"
  mkdir -p "$SANDBOX/stubs" "$SANDBOX/target" "$SANDBOX/prod_state" "$SANDBOX/out"
  : > "$BQ_CALL_LOG"
  : > "$DBT_CALL_LOG"

  write_manifest "$SANDBOX/target/manifest.json"
  case "$prod_manifest" in
    same)  write_manifest "$SANDBOX/prod_state/manifest.json" ;;
    moved) write_manifest "$SANDBOX/prod_state/manifest.json" moved ;;
    none)  rmdir "$SANDBOX/prod_state" ;;
    *)     echo "unknown prod_manifest mode: $prod_manifest" >&2; exit 1 ;;
  esac

  printf 'fct_example\nstg_example\n' > "$SANDBOX/models.txt"

  cat > "$SANDBOX/stubs/dbt" <<'STUB'
#!/usr/bin/env bash
# Only `dbt ls` is exercised; every other subcommand is a no-op success.
# The model list lives in models.txt in the sandbox (which is the cwd of the
# script under test) so a test can extend it without rewriting this stub.
# Every invocation is logged verbatim so tests can assert on the exact
# selection args (e.g. --select fct_example+ vs state:modified+).
echo "dbt $*" >> "$DBT_CALL_LOG"
if [[ "${1:-}" == "ls" ]]; then
  cat models.txt
fi
exit 0
STUB

  cat > "$SANDBOX/stubs/bq" <<'STUB'
#!/usr/bin/env bash
# Stub BigQuery CLI. Records every invocation, then answers based on the
# shape of the SQL and on STUB_MODE.
#
# The script queries WHOLE DATASETS, not single tables, so every fixture below
# is a dataset-wide result carrying table_name. Narrowing to one table is the
# script's job; answering per table here would hide a filtering bug.
args="$*"
echo "$args" >> "$BQ_CALL_LOG"

DEV_COLS='[{"table_name":"fct_example","column_name":"id","ordinal_position":1,"data_type":"INT64","is_nullable":"YES"},{"table_name":"fct_example","column_name":"amount","ordinal_position":2,"data_type":"NUMERIC","is_nullable":"YES"},{"table_name":"stg_example","column_name":"id","ordinal_position":1,"data_type":"INT64","is_nullable":"YES"},{"table_name":"stg_example","column_name":"amount","ordinal_position":2,"data_type":"NUMERIC","is_nullable":"YES"}]'
PROD_COLS='[{"table_name":"fct_example","column_name":"id","ordinal_position":1,"data_type":"INT64","is_nullable":"YES"}]'

# col_diff mode: a deliberate, non-trivial difference on fct_example.
#   added   -> created_at (dev only)
#   removed -> legacy_flag (prod only)
#   changed -> amount (NUMERIC in prod, STRING in dev)
# stg_example keeps its two plain dev columns and has no prod counterpart.
DIFF_DEV_COLS='[{"table_name":"fct_example","column_name":"id","ordinal_position":1,"data_type":"INT64","is_nullable":"YES"},{"table_name":"fct_example","column_name":"amount","ordinal_position":2,"data_type":"STRING","is_nullable":"YES"},{"table_name":"fct_example","column_name":"created_at","ordinal_position":3,"data_type":"TIMESTAMP","is_nullable":"YES"},{"table_name":"stg_example","column_name":"id","ordinal_position":1,"data_type":"INT64","is_nullable":"YES"},{"table_name":"stg_example","column_name":"amount","ordinal_position":2,"data_type":"NUMERIC","is_nullable":"YES"}]'
DIFF_PROD_COLS='[{"table_name":"fct_example","column_name":"id","ordinal_position":1,"data_type":"INT64","is_nullable":"YES"},{"table_name":"fct_example","column_name":"amount","ordinal_position":2,"data_type":"NUMERIC","is_nullable":"YES"},{"table_name":"fct_example","column_name":"legacy_flag","ordinal_position":3,"data_type":"BOOL","is_nullable":"YES"}]'

# per_model_cols mode: two models in the SAME dataset with disjoint extra
# columns. Each must see only its own. Returning the whole dataset's columns —
# the obvious batching bug — shows up immediately as the other model's column.
PM_DEV_COLS='[{"table_name":"fct_example","column_name":"id","ordinal_position":1,"data_type":"INT64","is_nullable":"YES"},{"table_name":"fct_example","column_name":"fct_only_col","ordinal_position":2,"data_type":"INT64","is_nullable":"YES"},{"table_name":"stg_example","column_name":"id","ordinal_position":1,"data_type":"INT64","is_nullable":"YES"},{"table_name":"stg_example","column_name":"stg_only_col","ordinal_position":2,"data_type":"STRING","is_nullable":"YES"}]'
PM_PROD_COLS='[{"table_name":"fct_example","column_name":"id","ordinal_position":1,"data_type":"INT64","is_nullable":"YES"},{"table_name":"stg_example","column_name":"id","ordinal_position":1,"data_type":"INT64","is_nullable":"YES"}]'

BOTH_TABLES='[{"table_name":"fct_example","table_type":"BASE TABLE"},{"table_name":"stg_example","table_type":"BASE TABLE"}]'

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
      case "$STUB_MODE" in
        col_diff)       echo "$DIFF_DEV_COLS" ;;
        per_model_cols) echo "$PM_DEV_COLS" ;;
        *)              echo "$DEV_COLS" ;;
      esac
    else
      case "$STUB_MODE" in
        col_diff)       echo "$DIFF_PROD_COLS" ;;
        per_model_cols) echo "$PM_PROD_COLS" ;;
        *)              echo "$PROD_COLS" ;;
      esac
    fi ;;

  *INFORMATION_SCHEMA.TABLES*)
    # One dataset-wide listing now serves BOTH the batched table-type lookup and
    # the orphan report: they are byte-identical queries and deliberately share
    # a cache entry, so there is nothing left to dispatch between.
    if [[ "$STUB_MODE" == "prod_type_denied" ]] && ! is_dev; then
      # COLUMNS succeeds, TABLES is denied: without classification this used to
      # surface as NEW_MODEL ("nothing to compare") instead of a failure.
      echo 'BigQuery error in query operation: Access Denied: Dataset prodproj:analytics' >&2
      exit 1
    elif is_dev; then
      echo "$BOTH_TABLES"
    else
      case "$STUB_MODE" in
        denied)         echo 'BigQuery error: Access Denied' >&2; exit 1 ;;
        has_orphan)     echo '[{"table_name":"legacy_junk","table_type":"BASE TABLE"}]' ;;
        banner_tables)  echo 'Welcome to BigQuery! Update available.' ;;
        per_model_cols) echo "$BOTH_TABLES" ;;
        *)              echo '[{"table_name":"fct_example","table_type":"BASE TABLE"}]' ;;
      esac
    fi ;;

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
    DBT_CALL_LOG="$DBT_CALL_LOG" \
    HAS_MODEL_CHANGES="${HAS_MODEL_CHANGES:-true}" \
    DIFF_SELECT="${DIFF_SELECT:-}" \
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
  assert_not_contains "$(cat "$BQ_CALL_LOG")" "pkg_schema" \
    "the package node is not queried"
  local rows; rows=$(grep -c '^| [a-z]' "$SANDBOX/out/schema-summary.md")
  assert_eq 2 "$rows" "still one summary row per selected model"
  cleanup
}

scenario_11() {
  echo "  scenario 11: movement UNCHANGED (Defect F regression guard)"
  # PR and prod manifests agree on database/schema/alias, so nothing has moved.
  # This scenario fails if movement reverts to comparing the physical CI dataset
  # against prod: those differ by construction and every row comes out MOVED.
  make_sandbox ok_no_orphans same
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0"

  local line row detail
  line=$(summary_line_for fct_example)
  row=$(table_row_for fct_example)
  detail=$(cat "$SANDBOX/out/fct_example.txt")

  assert_contains "$line" "|moved=UNCHANGED|" \
    "identical manifest locations are UNCHANGED, not MOVED"
  assert_not_contains "$line" "|moved=MOVED|" \
    "the ephemeral CI dataset is never mistaken for a move"
  assert_contains "$row" "| UNCHANGED |" "markdown Moved cell reads UNCHANGED"
  assert_not_contains "$row" "→" "no movement arrow is rendered when nothing moved"
  assert_not_contains "$row" "ci_pr_1" "the CI dataset never appears in the Moved cell"
  assert_contains "$detail" "Movement: UNCHANGED" "detail report states UNCHANGED"

  # Both models sit in the same place in both manifests.
  assert_contains "$(summary_line_for stg_example)" "|moved=UNCHANGED|" \
    "a NEW_MODEL relation with an unmoved manifest node is still UNCHANGED"

  # The physical query targets stay visible for debugging, explicitly labelled.
  assert_contains "$detail" "Physical relations queried:" \
    "physical query targets are labelled as such"
  assert_contains "$detail" "Dev:  ciproj.ci_pr_1.fct_example" \
    "physical dev target is still the CI dataset"
  cleanup
}

scenario_12() {
  echo "  scenario 12: movement MOVED (logical FQNs, not the CI dataset)"
  # Prod has fct_example in schema `analytics_legacy`; the PR moved it to
  # `analytics`.
  make_sandbox ok_no_orphans moved
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0"

  local line row detail
  line=$(summary_line_for fct_example)
  row=$(table_row_for fct_example)
  detail=$(cat "$SANDBOX/out/fct_example.txt")

  assert_contains "$line" "|moved=MOVED|" "a changed manifest schema is MOVED"
  assert_contains "$row" "prodproj.analytics_legacy.fct_example → prodproj.analytics.fct_example" \
    "the arrow shows prod logical → PR logical"
  assert_not_contains "$row" "ci_pr_1" "the arrow never shows the CI dataset"
  assert_contains "$detail" "Movement: prodproj.analytics_legacy.fct_example -> prodproj.analytics.fct_example" \
    "detail report shows the logical move"

  # The unmoved model in the same run is unaffected.
  assert_contains "$(summary_line_for stg_example)" "|moved=UNCHANGED|" \
    "an unmoved model in the same run stays UNCHANGED"
  cleanup
}

scenario_13() {
  echo "  scenario 13: movement UNKNOWN when there is no prod manifest"
  # Without prod_state/manifest.json the prod FQN is synthesised from the PR's
  # own identifier. Comparing against it would report a confident UNCHANGED that
  # was never checked, so movement must be UNKNOWN.
  make_sandbox ok_no_orphans none
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0 with no prod manifest"
  assert_contains "$RUN_STDOUT" "movement=UNKNOWN" "announces that movement is unknowable"

  local line row
  line=$(summary_line_for fct_example)
  row=$(table_row_for fct_example)
  assert_contains "$line" "|moved=UNKNOWN|" "a synthesised prod FQN yields UNKNOWN"
  assert_not_contains "$line" "|moved=UNCHANGED|" \
    "a synthesised prod FQN is never reported as UNCHANGED"
  assert_not_contains "$line" "|moved=MOVED|" \
    "a synthesised prod FQN is never reported as MOVED"
  assert_contains "$row" "| UNKNOWN |" "markdown Moved cell reads UNKNOWN"
  assert_contains "$(cat "$SANDBOX/out/fct_example.txt")" "<not in prod manifest>" \
    "detail report says the prod manifest node was not found"
  cleanup
}

# Adds $1 extra models, all in the same dev and prod datasets as the fixture
# pair. Used to prove the query count is a function of dataset count, not of
# model count.
add_extra_models() {
  local n=$1 mf i
  for mf in "$SANDBOX/target/manifest.json" "$SANDBOX/prod_state/manifest.json"; do
    [[ -f "$mf" ]] || continue
    for ((i = 1; i <= n; i++)); do
      jq --arg id "model.tpl.extra_$i" --arg nm "extra_$i" \
        '.nodes[$id] = {resource_type: "model", name: $nm, alias: $nm,
                        database: "prodproj", schema: "analytics",
                        unique_id: $id}' "$mf" > "$mf.tmp" && mv "$mf.tmp" "$mf"
    done
  done
  for ((i = 1; i <= n; i++)); do
    echo "extra_$i" >> "$SANDBOX/models.txt"
  done
}

bq_call_count() { grep -c . "$BQ_CALL_LOG"; }

scenario_14() {
  echo "  scenario 14: query volume is per dataset, not per model"
  # Before batching this loop issued six queries per model plus one dataset
  # listing: 13 for this two-model fixture, 241 at the real CI selection size of
  # 40 models, against a step capped at timeout-minutes: 10.
  #
  # Two datasets are touched — the CI dataset and prod — at three queries each.
  # The orphan report's table listing is the same query as the batched one and
  # shares its cache entry, so it adds nothing.
  make_sandbox ok_no_orphans
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0"
  local two_model_calls; two_model_calls=$(bq_call_count)
  assert_eq 6 "$two_model_calls" "two models cost 3 queries per dataset across 2 datasets"
  assert_eq 2 "$(grep -c 'INFORMATION_SCHEMA.TABLES' "$BQ_CALL_LOG")" \
    "the orphan listing reuses the batched TABLES query instead of repeating it"
  cleanup

  # The load-bearing half: the SAME count with six times the models. An
  # implementation that merely lowered the constant would pass an absolute
  # threshold and fail here.
  make_sandbox ok_no_orphans
  add_extra_models 10
  run_diff; rc=$?
  assert_eq 0 "$rc" "exits 0 with twelve models"
  local rows; rows=$(grep -c '^| [a-z]' "$SANDBOX/out/schema-summary.md")
  assert_eq 12 "$rows" "all twelve models are actually processed"
  local twelve_model_calls; twelve_model_calls=$(bq_call_count)
  assert_eq "$two_model_calls" "$twelve_model_calls" \
    "query count does not scale with model count"
  assert_eq 6 "$twelve_model_calls" "twelve models still cost 6 queries"
  cleanup
}

scenario_15() {
  echo "  scenario 15: each model sees only its own columns"
  # Two models in one dataset with disjoint extra columns. The batching bug this
  # guards against is handing every model the whole dataset's columns, or the
  # first table's.
  make_sandbox per_model_cols
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0"

  local fct stg
  fct=$(cat "$SANDBOX/out/fct_example.txt")
  stg=$(cat "$SANDBOX/out/stg_example.txt")

  assert_contains "$fct" "+ fct_only_col" "fct_example reports its own added column"
  assert_not_contains "$fct" "stg_only_col" "fct_example never sees the other table's column"
  assert_contains "$stg" "+ stg_only_col" "stg_example reports its own added column"
  assert_not_contains "$stg" "fct_only_col" "stg_example never sees the other table's column"

  assert_contains "$(summary_line_for fct_example)" "|added=1|removed=0|changed=0|" \
    "fct_example counts only its own column difference"
  assert_contains "$(summary_line_for stg_example)" "|added=1|removed=0|changed=0|" \
    "stg_example counts only its own column difference"
  assert_contains "$(summary_line_for fct_example)" "|status=OK|" \
    "fct_example is a clean comparison, not NEW_MODEL"
  assert_contains "$(summary_line_for stg_example)" "|status=OK|" \
    "stg_example is a clean comparison, not NEW_MODEL"
  cleanup
}

scenario_16() {
  echo "  scenario 16: a dataset-wide failure reaches every model in it"
  # The blob is fetched once now, so the failure happens once. Every model in
  # that dataset must still classify exactly as it did when each issued its own
  # query. Filtering a non-JSON blob instead of passing it through verbatim
  # would turn a permissions failure into a clean OK diff on every row.
  make_sandbox prod_denied
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0 when the prod dataset fetch is denied"
  local summary; summary=$(cat "$SANDBOX/out/schema-summary.md")
  assert_contains "$(summary_line_for fct_example)" "|status=AUTH_ERROR|" \
    "first model in the denied dataset is AUTH_ERROR"
  assert_contains "$(summary_line_for stg_example)" "|status=AUTH_ERROR|" \
    "second model in the denied dataset is AUTH_ERROR too, not OK"
  assert_not_contains "$summary" "NEW_MODEL" \
    "no model in a denied dataset is downgraded to NEW_MODEL"
  assert_not_contains "$summary" "| OK |" \
    "no model in a denied dataset is downgraded to OK"
  assert_eq 1 "$(grep -c 'prodproj.analytics..INFORMATION_SCHEMA.COLUMNS' "$BQ_CALL_LOG")" \
    "the denied fetch is cached, not retried once per model"
  cleanup

  # Same requirement for a denial printed on stdout with exit 0, which reaches
  # the classifier as an "Access Denied" substring rather than as emptiness.
  make_sandbox dev_denied
  run_diff; rc=$?
  assert_eq 0 "$rc" "exits 0 when the dev dataset fetch is denied on stdout"
  assert_contains "$(summary_line_for fct_example)" "|status=AUTH_ERROR|" \
    "first model sees the Access Denied string"
  assert_contains "$(summary_line_for stg_example)" "|status=AUTH_ERROR|" \
    "second model sees the Access Denied string too"
  cleanup

  # A non-JSON blob that is NOT a denial pins the passthrough precisely: it can
  # only reach the classifier as NON_JSON if the helper hands it back untouched.
  # jq-filtering it instead yields empty (which classifies AUTH_ERROR) and
  # normalizing it first yields [] (which classifies OK) — both wrong, and both
  # indistinguishable from correct behaviour on a denial alone.
  make_sandbox banner_introspect
  run_diff; rc=$?
  assert_eq 0 "$rc" "exits 0 on a dataset-wide banner"
  assert_contains "$(summary_line_for fct_example)" "|status=NON_JSON|" \
    "first model in the dataset sees the banner verbatim"
  assert_contains "$(summary_line_for stg_example)" "|status=NON_JSON|" \
    "second model in the dataset sees the banner verbatim, not empty and not []"
  cleanup
}

scenario_17() {
  echo "  scenario 17: dev and prod datasets do not share a cache entry"
  # A cache keyed on anything less than (project, dataset) would serve the dev
  # blob for prod, and the diff would silently collapse to zero.
  make_sandbox ok_no_orphans
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0"

  # dev has `amount`, prod does not.
  assert_contains "$(summary_line_for fct_example)" "|added=1|removed=0|changed=0|" \
    "the dev/prod difference survives caching"
  assert_contains "$(cat "$SANDBOX/out/fct_example.txt")" "+ amount" \
    "the column present only in dev is named"
  assert_eq 1 "$(grep -c 'ciproj.ci_pr_1..INFORMATION_SCHEMA.COLUMNS' "$BQ_CALL_LOG")" \
    "the dev dataset is fetched exactly once"
  assert_eq 1 "$(grep -c 'prodproj.analytics..INFORMATION_SCHEMA.COLUMNS' "$BQ_CALL_LOG")" \
    "the prod dataset is fetched exactly once, separately"
  cleanup
}

scenario_18() {
  echo "  scenario 18: docs-only (HAS_MODEL_CHANGES=false) produces no schema diff"
  make_sandbox ok_no_orphans
  HAS_MODEL_CHANGES=false run_diff; local rc=$?
  unset HAS_MODEL_CHANGES
  assert_eq 0 "$rc" "exits 0 on docs-only PRs"
  assert_contains "$RUN_STDOUT" "No models" "schema diff exits early on docs-only"
  assert_not_contains "$(cat "$DBT_CALL_LOG")" "ls" "never calls dbt ls on docs-only PRs"
  assert_eq 0 "$(grep -c . "$BQ_CALL_LOG")" "never calls bq on docs-only PRs"
  cleanup
}

scenario_19() {
  echo "  scenario 19: DIFF_SELECT is honoured over state:modified+"
  make_sandbox ok_no_orphans
  HAS_MODEL_CHANGES=true DIFF_SELECT=fct_example+ run_diff; local rc=$?
  unset HAS_MODEL_CHANGES DIFF_SELECT
  assert_eq 0 "$rc" "exits 0"
  assert_contains "$(cat "$DBT_CALL_LOG")" "ls --select fct_example+" "schema diff uses DIFF_SELECT"
  assert_not_contains "$(cat "$DBT_CALL_LOG")" "state:modified+" "does not fall back to state:modified+ when DIFF_SELECT is set"
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
scenario_11
scenario_12
scenario_13
scenario_14
scenario_15
scenario_16
scenario_17
scenario_18
scenario_19

echo ""
echo "passed: $PASS_COUNT  failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
