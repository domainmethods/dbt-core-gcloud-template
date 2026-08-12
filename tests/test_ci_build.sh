#!/usr/bin/env bash
# Tests for scripts/ci_build.sh — verifies models are built with
# --exclude-resource-type test so a red data test can no longer suppress
# the diff-gate steps that follow, and that CI_SELECT/CI_DEFER are exported
# for the downstream (non-blocking) `dbt test` step to consume.
#
# Dependency-free: requires bash 4+, coreutils. Stubs `dbt`/`gsutil` on PATH.
# `set -e` is deliberately NOT used so assertions can accumulate.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO_ROOT/scripts/ci_build.sh"
PASS_COUNT=0; FAIL_COUNT=0
pass(){ echo "    ok   - $1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail(){ echo "    FAIL - $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
assert_contains(){ [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 (missing '$2')"; }
assert_not_contains(){ [[ "$1" != *"$2"* ]] && pass "$3" || fail "$3 (unexpectedly contains '$2')"; }

SANDBOX=$(mktemp -d); mkdir -p "$SANDBOX/bin"
printf '#!/usr/bin/env bash\necho "dbt $*" >> "$DBT_CALL_LOG"\n' > "$SANDBOX/bin/dbt"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gsutil"   # no manifest → full build
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

echo "scenario: no manifest (HAS_STATE false) → full build, no defer"
: > "$DBT_CALL_LOG"
GITHUB_ENV_FILE6="$SANDBOX/github_env_6"; : > "$GITHUB_ENV_FILE6"
( cd "$SANDBOX" && env -i PATH="$SANDBOX/bin:/usr/bin:/bin" DBT_CALL_LOG="$DBT_CALL_LOG" \
    GITHUB_ENV="$GITHUB_ENV_FILE6" DBT_ARTIFACTS_BUCKET="fake-bucket" \
    HAS_MODEL_CHANGES=true BUILD_SELECT="fct_a+" bash "$SCRIPT" >/dev/null 2>&1 )
assert_contains "$(cat "$DBT_CALL_LOG")" "build --target ci --exclude-resource-type test" "full build when no manifest"
assert_not_contains "$(cat "$DBT_CALL_LOG")" "--defer" "no defer when no manifest"

echo "results: passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
