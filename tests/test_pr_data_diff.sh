#!/usr/bin/env bash
# Tests for scripts/pr_data_diff.sh model-selection logic.
# Dependency-free: bash 4+, coreutils. Stubs dbt/gsutil on PATH. No `set -e`.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO_ROOT/scripts/pr_data_diff.sh"
PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "    ok   - $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "    FAIL - $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
assert_contains() { [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 (missing '$2')"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] && pass "$3" || fail "$3 (unexpected '$2')"; }

make_sandbox() {
  SANDBOX=$(mktemp -d); DBT_CALL_LOG="$SANDBOX/dbt_calls.log"; mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/dbt" <<'STUB'
#!/usr/bin/env bash
echo "dbt $*" >> "$DBT_CALL_LOG"
case "$1" in
  ls) printf '%s\n' model_a model_b ;;
  run-operation) echo "SUMMARY|table=model_a|dev=1|prod=1|dev_not_in_prod=0|prod_not_in_dev=0" ;;
  *) : ;;
esac
STUB
  chmod +x "$SANDBOX/bin/dbt"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/bin/gsutil"; chmod +x "$SANDBOX/bin/gsutil"
  export DBT_CALL_LOG
}

run_case() {  # $1 = extra env assignments; sets RUN_OUT and DBT_CALL_LOG
  make_sandbox
  [[ "${WITH_MANIFEST:-0}" == "1" ]] && { mkdir -p "$SANDBOX/prod_state"; echo '{}' > "$SANDBOX/prod_state/manifest.json"; }
  RUN_OUT=$(cd "$SANDBOX" && env -i PATH="$SANDBOX/bin:/usr/bin:/bin" \
    DBT_CALL_LOG="$DBT_CALL_LOG" ARTIFACT_DIR="$SANDBOX/diff_reports" \
    DBT_GCP_PROJECT_CI=ciproj DBT_BQ_DATASET=ci_ds DBT_GCP_PROJECT_PROD=prodproj \
    $1 bash "$SCRIPT" 2>&1)
}

echo "scenario 1: docs-only (HAS_MODEL_CHANGES=false) diffs nothing, no dbt ls"
run_case 'HAS_MODEL_CHANGES=false'
assert_contains "$RUN_OUT" "No models to diff" "exits early with no models"
assert_not_contains "$(cat "$DBT_CALL_LOG")" "ls" "never calls dbt ls"

echo "scenario 2: DIFF_SELECT is used verbatim, not state:modified+"
run_case 'HAS_MODEL_CHANGES=true DIFF_SELECT=fct_example+'
assert_contains "$(cat "$DBT_CALL_LOG")" "ls --select fct_example+" "selects via DIFF_SELECT"
assert_not_contains "$(cat "$DBT_CALL_LOG")" "state:modified+" "does not use state fallback"

echo "scenario 3: no DIFF_SELECT, manifest present → state:modified+"
WITH_MANIFEST=1 run_case 'HAS_MODEL_CHANGES=true'
assert_contains "$(cat "$DBT_CALL_LOG")" "state:modified+" "uses state comparison when scope absent"

echo "results: passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
