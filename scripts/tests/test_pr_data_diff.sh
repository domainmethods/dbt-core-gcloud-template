#!/usr/bin/env bash
# Tests for scripts/pr_data_diff.sh model-selection logic.
# Dependency-free: bash 4+, coreutils. Stubs dbt/gsutil on PATH. No `set -e`.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/pr_data_diff.sh"
PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "    ok   - $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "    FAIL - $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
assert_contains() { [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 (missing '$2')"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] && pass "$3" || fail "$3 (unexpected '$2')"; }

# "$BASH", not `bash`: the script needs bash 4+ (mapfile), and with this PATH a Mac
# would pick /bin/bash 3.2, so no model would ever reach the diff loop.
make_sandbox() {
  SANDBOX=$(mktemp -d); DBT_CALL_LOG="$SANDBOX/dbt_calls.log"; mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/dbt" <<'STUB'
#!/usr/bin/env bash
echo "dbt $*" >> "$DBT_CALL_LOG"
case "$1" in
  ls) printf '%s\n' "${STUB_LS:-model_a,model_b}" | tr , '\n' ;;  # STUB_LS: comma-separated names
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
  [[ "${WITH_MANIFEST:-0}" == "1" ]] && { mkdir -p "$SANDBOX/prod_state"; echo "${MANIFEST_JSON:-{\}}" > "$SANDBOX/prod_state/manifest.json"; }
  RUN_OUT=$(cd "$SANDBOX" && env -i PATH="$SANDBOX/bin:/usr/bin:/bin" \
    DBT_CALL_LOG="$DBT_CALL_LOG" ARTIFACT_DIR="$SANDBOX/diff_reports" \
    DBT_GCP_PROJECT_CI=ciproj DBT_BQ_DATASET=ci_ds DBT_GCP_PROJECT_PROD=prodproj \
    $1 "$BASH" "$SCRIPT" 2>&1)
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

echo "scenario 4: manifest lookup fails (auth error) → exits non-zero, no dbt ls (#74)"
make_sandbox
printf '#!/usr/bin/env bash\necho "AccessDeniedException: 403" >&2\nexit 1\n' > "$SANDBOX/bin/gsutil"
RUN_OUT=$(cd "$SANDBOX" && env -i PATH="$SANDBOX/bin:/usr/bin:/bin" \
  DBT_CALL_LOG="$DBT_CALL_LOG" ARTIFACT_DIR="$SANDBOX/diff_reports" \
  DBT_GCP_PROJECT_CI=ciproj DBT_BQ_DATASET=ci_ds DBT_ARTIFACTS_BUCKET=fake-bucket \
  PROD_MANIFEST_RETRY_DELAY=0 HAS_MODEL_CHANGES=true "$BASH" "$SCRIPT" 2>&1); RC=$?
[[ $RC -ne 0 ]] && pass "exits non-zero on lookup error" || fail "exits non-zero on lookup error (exit $RC)"
assert_not_contains "$(cat "$DBT_CALL_LOG" 2>/dev/null)" "ls" "never selects models after a lookup error"

echo "scenario 5: lookup script exits with an unexpected code (127) → exits non-zero, no dbt ls (#74)"
make_sandbox
mkdir -p "$SANDBOX/scripts"
cp "$SCRIPT" "$SANDBOX/scripts/pr_data_diff.sh"
printf '#!/usr/bin/env bash\nexit 127\n' > "$SANDBOX/scripts/lookup_prod_manifest.sh"
RUN_OUT=$(cd "$SANDBOX" && env -i PATH="$SANDBOX/bin:/usr/bin:/bin" \
  DBT_CALL_LOG="$DBT_CALL_LOG" ARTIFACT_DIR="$SANDBOX/diff_reports" \
  DBT_GCP_PROJECT_CI=ciproj DBT_BQ_DATASET=ci_ds DBT_ARTIFACTS_BUCKET=fake-bucket \
  HAS_MODEL_CHANGES=true "$BASH" "$SANDBOX/scripts/pr_data_diff.sh" 2>&1); RC=$?
[[ $RC -ne 0 ]] && pass "exits non-zero on unexpected lookup exit code" || fail "exits non-zero on unexpected lookup exit code (exit $RC)"
assert_not_contains "$(cat "$DBT_CALL_LOG" 2>/dev/null)" "ls" "never selects models after an unexpected lookup exit code"
# model_a is deployed; model_b is not, though a leftover prod table may share its name.
PROD_MANIFEST='{"nodes": {"model.proj.model_a": {"name": "model_a", "resource_type": "model"}, "test.proj.model_b_check": {"name": "model_b", "resource_type": "test"}}}'
diff_call() { grep "run-operation dev_prod_diff_for_model" "$DBT_CALL_LOG" | grep "model_name: '$1'"; }

echo "scenario 6: a model missing from the prod manifest is diffed as new (#12)"
WITH_MANIFEST=1 MANIFEST_JSON="$PROD_MANIFEST" run_case 'HAS_MODEL_CHANGES=true DIFF_SELECT=model_a+'
assert_contains "$(diff_call model_b)" "new_model: true" "model_b (not in manifest) is passed as new"
assert_not_contains "$(diff_call model_a)" "new_model: true" "model_a (in manifest) is compared as usual"
assert_contains "$RUN_OUT" "model_b is not in the prod manifest" "says why model_b is treated as new"

echo "scenario 7: an unreadable prod manifest falls back to the table check (#12)"
WITH_MANIFEST=1 MANIFEST_JSON='not json' run_case 'HAS_MODEL_CHANGES=true DIFF_SELECT=model_a+'
assert_not_contains "$(cat "$DBT_CALL_LOG")" "new_model: true" "no model forced new"
assert_contains "$RUN_OUT" "Could not read model names" "warns that the manifest was unreadable"

echo "scenario 8: no prod manifest keeps the table check (#12)"
run_case 'HAS_MODEL_CHANGES=true'
assert_not_contains "$(cat "$DBT_CALL_LOG")" "new_model: true" "no model forced new"

# dbt ls --output name prints a versioned model's search_name ("<name>.v<version>"),
# so the manifest side must be built the same way or every versioned model is "new".
VERSIONED_MANIFEST='{"nodes": {"model.proj.dim_v": {"name": "dim_v", "resource_type": "model", "version": 2}, "model.proj.model_a": {"name": "model_a", "resource_type": "model", "version": null}}}'

echo "scenario 9: a deployed versioned model is compared as usual, an undeployed version is new"
WITH_MANIFEST=1 MANIFEST_JSON="$VERSIONED_MANIFEST" run_case 'HAS_MODEL_CHANGES=true DIFF_SELECT=dim_v+ STUB_LS=dim_v.v2,dim_v.v3,model_a'
assert_not_contains "$(diff_call dim_v.v2)" "new_model: true" "dim_v.v2 (in manifest) is compared as usual"
assert_contains "$(diff_call dim_v.v3)" "new_model: true" "dim_v.v3 (not in manifest) is passed as new"
assert_not_contains "$(diff_call model_a)" "new_model: true" "unversioned model_a (in manifest) is compared as usual"

echo "results: passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
