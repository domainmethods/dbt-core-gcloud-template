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

echo "results: passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
