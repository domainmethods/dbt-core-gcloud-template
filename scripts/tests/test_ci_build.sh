#!/usr/bin/env bash
# Tests for scripts/ci_build.sh — verifies models are built with
# --exclude-resource-type test so a red data test can no longer suppress
# the diff-gate steps that follow, and that CI_SELECT/CI_DEFER are exported
# for the downstream (non-blocking) `dbt test` step to consume.
#
# Dependency-free: requires bash 4+, coreutils. Stubs `dbt`/`gsutil` on PATH.
# `set -e` is deliberately NOT used so assertions can accumulate.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/ci_build.sh"
PASS_COUNT=0; FAIL_COUNT=0
pass(){ echo "    ok   - $1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail(){ echo "    FAIL - $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
assert_contains(){ [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 (missing '$2')"; }
assert_not_contains(){ [[ "$1" != *"$2"* ]] && pass "$3" || fail "$3 (unexpectedly contains '$2')"; }

SANDBOX=$(mktemp -d); mkdir -p "$SANDBOX/bin"
printf '#!/usr/bin/env bash\necho "dbt $*" >> "$DBT_CALL_LOG"\n' > "$SANDBOX/bin/dbt"
printf '#!/usr/bin/env bash\necho "CommandException: One or more URLs matched no objects." >&2\nexit 1\n' > "$SANDBOX/bin/gsutil"   # no manifest → full build
chmod +x "$SANDBOX/bin/dbt" "$SANDBOX/bin/gsutil"
export DBT_CALL_LOG="$SANDBOX/calls.log"

echo "scenario: model changes, no state → build excludes tests"
: > "$DBT_CALL_LOG"
GITHUB_ENV_FILE="$SANDBOX/github_env_1"; : > "$GITHUB_ENV_FILE"
( cd "$SANDBOX" && env -i PATH="$SANDBOX/bin:/usr/bin:/bin" DBT_CALL_LOG="$DBT_CALL_LOG" \
    GITHUB_ENV="$GITHUB_ENV_FILE" \
    HAS_MODEL_CHANGES=true bash "$SCRIPT" >/dev/null 2>&1 )
assert_contains "$(cat "$DBT_CALL_LOG")" "build --target ci --exclude-resource-type test" "build skips tests"
assert_contains "$(cat "$GITHUB_ENV_FILE")" "CI_SELECT=" "CI_SELECT exported to GITHUB_ENV"
assert_contains "$(cat "$GITHUB_ENV_FILE")" "CI_DEFER=" "CI_DEFER exported to GITHUB_ENV"

echo "scenario: model changes, with state → slim build excludes tests and exports select/defer"
: > "$DBT_CALL_LOG"
SANDBOX2=$(mktemp -d); mkdir -p "$SANDBOX2/bin"
printf '#!/usr/bin/env bash\necho "dbt $*" >> "$DBT_CALL_LOG"\ncase "$*" in\n  "ls --select"*) exit 0 ;;\nesac\n' > "$SANDBOX2/bin/dbt"
printf '#!/usr/bin/env bash\ncase "$1" in\n  ls) exit 0 ;;\n  cp) mkdir -p prod_state; echo "{}" > prod_state/manifest.json; exit 0 ;;\nesac\n' > "$SANDBOX2/bin/gsutil"
chmod +x "$SANDBOX2/bin/dbt" "$SANDBOX2/bin/gsutil"
GITHUB_ENV_FILE2="$SANDBOX2/github_env_2"; : > "$GITHUB_ENV_FILE2"
( cd "$SANDBOX2" && env -i PATH="$SANDBOX2/bin:/usr/bin:/bin" DBT_CALL_LOG="$DBT_CALL_LOG" \
    GITHUB_ENV="$GITHUB_ENV_FILE2" DBT_ARTIFACTS_BUCKET="fake-bucket" \
    HAS_MODEL_CHANGES=true bash "$SCRIPT" >/dev/null 2>&1 )
assert_contains "$(cat "$DBT_CALL_LOG")" "build --target ci --select state:modified+ --defer --state prod_state --exclude-resource-type test" "slim build skips tests"
assert_contains "$(cat "$GITHUB_ENV_FILE2")" "CI_SELECT=state:modified+" "CI_SELECT exported for slim build"
assert_contains "$(cat "$GITHUB_ENV_FILE2")" "CI_DEFER=--defer --state prod_state" "CI_DEFER exported for slim build"

echo "scenario: HAS_STATE + no fallback + BUILD_SELECT → git-diff scoped build"
: > "$DBT_CALL_LOG"
SANDBOX3=$(mktemp -d); mkdir -p "$SANDBOX3/bin"
printf '#!/usr/bin/env bash\necho "dbt $*" >> "$DBT_CALL_LOG"\n' > "$SANDBOX3/bin/dbt"
printf '#!/usr/bin/env bash\ncase "$1" in\n  ls) exit 0 ;;\n  cp) mkdir -p prod_state; echo "{}" > prod_state/manifest.json; exit 0 ;;\nesac\n' > "$SANDBOX3/bin/gsutil"
chmod +x "$SANDBOX3/bin/dbt" "$SANDBOX3/bin/gsutil"
GITHUB_ENV_FILE3="$SANDBOX3/github_env_3"; : > "$GITHUB_ENV_FILE3"
( cd "$SANDBOX3" && env -i PATH="$SANDBOX3/bin:/usr/bin:/bin" DBT_CALL_LOG="$DBT_CALL_LOG" \
    GITHUB_ENV="$GITHUB_ENV_FILE3" DBT_ARTIFACTS_BUCKET="fake-bucket" \
    HAS_MODEL_CHANGES=true NEEDS_FALLBACK=false BUILD_SELECT="fct_a+" bash "$SCRIPT" >/dev/null 2>&1 )
assert_contains "$(cat "$DBT_CALL_LOG")" "build --target ci --select fct_a+ --defer --state prod_state --exclude-resource-type test" "git-diff scoped build"
assert_contains "$(cat "$GITHUB_ENV_FILE3")" "CI_SELECT=fct_a+" "CI_SELECT exported for scoped build"
assert_contains "$(cat "$GITHUB_ENV_FILE3")" "CI_DEFER=--defer --state prod_state" "CI_DEFER exported for scoped build"

echo "scenario: HAS_STATE + fallback + BUILD_SELECT → combined select"
: > "$DBT_CALL_LOG"
SANDBOX4=$(mktemp -d); mkdir -p "$SANDBOX4/bin"
printf '#!/usr/bin/env bash\necho "dbt $*" >> "$DBT_CALL_LOG"\n' > "$SANDBOX4/bin/dbt"
printf '#!/usr/bin/env bash\ncase "$1" in\n  ls) exit 0 ;;\n  cp) mkdir -p prod_state; echo "{}" > prod_state/manifest.json; exit 0 ;;\nesac\n' > "$SANDBOX4/bin/gsutil"
chmod +x "$SANDBOX4/bin/dbt" "$SANDBOX4/bin/gsutil"
GITHUB_ENV_FILE4="$SANDBOX4/github_env_4"; : > "$GITHUB_ENV_FILE4"
( cd "$SANDBOX4" && env -i PATH="$SANDBOX4/bin:/usr/bin:/bin" DBT_CALL_LOG="$DBT_CALL_LOG" \
    GITHUB_ENV="$GITHUB_ENV_FILE4" DBT_ARTIFACTS_BUCKET="fake-bucket" \
    HAS_MODEL_CHANGES=true NEEDS_FALLBACK=true BUILD_SELECT="fct_a+" bash "$SCRIPT" >/dev/null 2>&1 )
assert_contains "$(cat "$DBT_CALL_LOG")" "build --target ci --select fct_a+ state:modified+ --defer --state prod_state --exclude-resource-type test" "git-diff + state:modified+ combined select"
assert_contains "$(cat "$GITHUB_ENV_FILE4")" "CI_SELECT=fct_a+ state:modified+" "CI_SELECT exported for combined build"
assert_contains "$(cat "$GITHUB_ENV_FILE4")" "CI_DEFER=--defer --state prod_state" "CI_DEFER exported for combined build"

echo "scenario: HAS_STATE + fallback + no BUILD_SELECT → state:modified+ only"
: > "$DBT_CALL_LOG"
SANDBOX5=$(mktemp -d); mkdir -p "$SANDBOX5/bin"
printf '#!/usr/bin/env bash\necho "dbt $*" >> "$DBT_CALL_LOG"\n' > "$SANDBOX5/bin/dbt"
printf '#!/usr/bin/env bash\ncase "$1" in\n  ls) exit 0 ;;\n  cp) mkdir -p prod_state; echo "{}" > prod_state/manifest.json; exit 0 ;;\nesac\n' > "$SANDBOX5/bin/gsutil"
chmod +x "$SANDBOX5/bin/dbt" "$SANDBOX5/bin/gsutil"
GITHUB_ENV_FILE5="$SANDBOX5/github_env_5"; : > "$GITHUB_ENV_FILE5"
( cd "$SANDBOX5" && env -i PATH="$SANDBOX5/bin:/usr/bin:/bin" DBT_CALL_LOG="$DBT_CALL_LOG" \
    GITHUB_ENV="$GITHUB_ENV_FILE5" DBT_ARTIFACTS_BUCKET="fake-bucket" \
    HAS_MODEL_CHANGES=true NEEDS_FALLBACK=true BUILD_SELECT="" bash "$SCRIPT" >/dev/null 2>&1 )
assert_contains "$(cat "$DBT_CALL_LOG")" "build --target ci --select state:modified+ --defer --state prod_state --exclude-resource-type test" "state:modified+ fallback only"
assert_contains "$(cat "$GITHUB_ENV_FILE5")" "CI_SELECT=state:modified+" "CI_SELECT exported for state:modified+ fallback"
assert_contains "$(cat "$GITHUB_ENV_FILE5")" "CI_DEFER=--defer --state prod_state" "CI_DEFER exported for state:modified+ fallback"

echo "scenario: no manifest (HAS_STATE false) → full build, no defer"
: > "$DBT_CALL_LOG"
GITHUB_ENV_FILE6="$SANDBOX/github_env_6"; : > "$GITHUB_ENV_FILE6"
( cd "$SANDBOX" && env -i PATH="$SANDBOX/bin:/usr/bin:/bin" DBT_CALL_LOG="$DBT_CALL_LOG" \
    GITHUB_ENV="$GITHUB_ENV_FILE6" DBT_ARTIFACTS_BUCKET="fake-bucket" \
    HAS_MODEL_CHANGES=true BUILD_SELECT="fct_a+" bash "$SCRIPT" >/dev/null 2>&1 )
assert_contains "$(cat "$DBT_CALL_LOG")" "build --target ci --exclude-resource-type test" "full build when no manifest"
assert_not_contains "$(cat "$DBT_CALL_LOG")" "--defer" "no defer when no manifest"

echo "scenario: manifest lookup fails (auth error) → job fails, no build (#74)"
: > "$DBT_CALL_LOG"
SANDBOX7=$(mktemp -d); mkdir -p "$SANDBOX7/bin"
printf '#!/usr/bin/env bash\necho "dbt $*" >> "$DBT_CALL_LOG"\n' > "$SANDBOX7/bin/dbt"
printf '#!/usr/bin/env bash\necho "AccessDeniedException: 401 Anonymous caller" >&2\nexit 1\n' > "$SANDBOX7/bin/gsutil"
chmod +x "$SANDBOX7/bin/dbt" "$SANDBOX7/bin/gsutil"
OUT7=$( cd "$SANDBOX7" && env -i PATH="$SANDBOX7/bin:/usr/bin:/bin" DBT_CALL_LOG="$DBT_CALL_LOG" \
    DBT_ARTIFACTS_BUCKET="fake-bucket" PROD_MANIFEST_RETRY_DELAY=0 \
    HAS_MODEL_CHANGES=true bash "$SCRIPT" 2>&1 ); RC7=$?
[[ $RC7 -ne 0 ]] && pass "job fails on lookup error" || fail "job fails on lookup error (exit $RC7)"
assert_contains "$OUT7" "AccessDeniedException" "lookup error is printed"
assert_not_contains "$(cat "$DBT_CALL_LOG")" "build" "no full build on lookup error"

echo "scenario: manifest downloads but is not valid JSON → job fails, no build (#74)"
: > "$DBT_CALL_LOG"
SANDBOX8=$(mktemp -d); mkdir -p "$SANDBOX8/bin"
printf '#!/usr/bin/env bash\necho "dbt $*" >> "$DBT_CALL_LOG"\n' > "$SANDBOX8/bin/dbt"
printf '#!/usr/bin/env bash\ncase "$1" in\n  ls) exit 0 ;;\n  cp) mkdir -p prod_state; echo "{trunc" > prod_state/manifest.json; exit 0 ;;\nesac\n' > "$SANDBOX8/bin/gsutil"
chmod +x "$SANDBOX8/bin/dbt" "$SANDBOX8/bin/gsutil"
( cd "$SANDBOX8" && env -i PATH="$SANDBOX8/bin:/usr/bin:/bin" DBT_CALL_LOG="$DBT_CALL_LOG" \
    DBT_ARTIFACTS_BUCKET="fake-bucket" HAS_MODEL_CHANGES=true bash "$SCRIPT" >/dev/null 2>&1 ); RC8=$?
[[ $RC8 -ne 0 ]] && pass "job fails on corrupt manifest" || fail "job fails on corrupt manifest (exit $RC8)"
assert_not_contains "$(cat "$DBT_CALL_LOG")" "build" "no full build on corrupt manifest"

echo "scenario: docs-only (HAS_MODEL_CHANGES=false) + lookup error → parse only, no lookup"
: > "$DBT_CALL_LOG"
SANDBOX9=$(mktemp -d); mkdir -p "$SANDBOX9/bin"
printf '#!/usr/bin/env bash\necho "dbt $*" >> "$DBT_CALL_LOG"\n' > "$SANDBOX9/bin/dbt"
printf '#!/usr/bin/env bash\necho "gsutil $*" >> "$DBT_CALL_LOG"\necho "AccessDeniedException: 401 Anonymous caller" >&2\nexit 1\n' > "$SANDBOX9/bin/gsutil"
chmod +x "$SANDBOX9/bin/dbt" "$SANDBOX9/bin/gsutil"
( cd "$SANDBOX9" && env -i PATH="$SANDBOX9/bin:/usr/bin:/bin" DBT_CALL_LOG="$DBT_CALL_LOG" \
    DBT_ARTIFACTS_BUCKET="fake-bucket" PROD_MANIFEST_RETRY_DELAY=0 \
    HAS_MODEL_CHANGES=false bash "$SCRIPT" >/dev/null 2>&1 ); RC9=$?
[[ $RC9 -eq 0 ]] && pass "docs-only PR passes despite lookup error" || fail "docs-only PR passes despite lookup error (exit $RC9)"
assert_contains "$(cat "$DBT_CALL_LOG")" "parse --target ci" "docs-only PR runs dbt parse"
assert_not_contains "$(cat "$DBT_CALL_LOG")" "gsutil" "docs-only PR skips the manifest lookup"

echo "scenario: lookup script exits with an unexpected code (127) → job fails, no build (#74)"
: > "$DBT_CALL_LOG"
SANDBOX10=$(mktemp -d); mkdir -p "$SANDBOX10/bin" "$SANDBOX10/scripts"
printf '#!/usr/bin/env bash\necho "dbt $*" >> "$DBT_CALL_LOG"\n' > "$SANDBOX10/bin/dbt"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX10/bin/gsutil"
chmod +x "$SANDBOX10/bin/dbt" "$SANDBOX10/bin/gsutil"
cp "$SCRIPT" "$SANDBOX10/scripts/ci_build.sh"
printf '#!/usr/bin/env bash\nexit 127\n' > "$SANDBOX10/scripts/lookup_prod_manifest.sh"
( cd "$SANDBOX10" && env -i PATH="$SANDBOX10/bin:/usr/bin:/bin" DBT_CALL_LOG="$DBT_CALL_LOG" \
    DBT_ARTIFACTS_BUCKET="fake-bucket" HAS_MODEL_CHANGES=true \
    bash "$SANDBOX10/scripts/ci_build.sh" >/dev/null 2>&1 ); RC10=$?
[[ $RC10 -ne 0 ]] && pass "job fails on unexpected lookup exit code" || fail "job fails on unexpected lookup exit code (exit $RC10)"
assert_not_contains "$(cat "$DBT_CALL_LOG")" "build" "no full build on unexpected lookup exit code"

echo "scenario: FULL_BUILD (dbt/adapter or profile change) with state → full build, no select, no defer"
: > "$DBT_CALL_LOG"
SANDBOX11=$(mktemp -d); mkdir -p "$SANDBOX11/bin"
printf '#!/usr/bin/env bash\necho "dbt $*" >> "$DBT_CALL_LOG"\n' > "$SANDBOX11/bin/dbt"
printf '#!/usr/bin/env bash\ncase "$1" in\n  ls) exit 0 ;;\n  cp) mkdir -p prod_state; echo "{}" > prod_state/manifest.json; exit 0 ;;\nesac\n' > "$SANDBOX11/bin/gsutil"
chmod +x "$SANDBOX11/bin/dbt" "$SANDBOX11/bin/gsutil"
GITHUB_ENV_FILE11="$SANDBOX11/github_env_11"; : > "$GITHUB_ENV_FILE11"
( cd "$SANDBOX11" && env -i PATH="$SANDBOX11/bin:/usr/bin:/bin" DBT_CALL_LOG="$DBT_CALL_LOG" \
    GITHUB_ENV="$GITHUB_ENV_FILE11" DBT_ARTIFACTS_BUCKET="fake-bucket" \
    HAS_MODEL_CHANGES=true FULL_BUILD=true NEEDS_FALLBACK=true BUILD_SELECT="fct_a+" bash "$SCRIPT" >/dev/null 2>&1 ); RC11=$?
[[ $RC11 -eq 0 ]] && pass "full build exits 0" || fail "full build exits 0 (exit $RC11)"
assert_contains "$(cat "$DBT_CALL_LOG")" "build --target ci --exclude-resource-type test" "FULL_BUILD runs an unscoped build"
assert_not_contains "$(cat "$DBT_CALL_LOG")" "--select" "FULL_BUILD build has no --select"
assert_not_contains "$(cat "$DBT_CALL_LOG")" "--defer" "FULL_BUILD build does not defer"
assert_contains "$(cat "$GITHUB_ENV_FILE11")" "CI_SELECT=" "CI_SELECT exported (empty) for full build"
assert_not_contains "$(cat "$GITHUB_ENV_FILE11")" "CI_SELECT=fct" "CI_SELECT is empty for full build"

echo "results: passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
