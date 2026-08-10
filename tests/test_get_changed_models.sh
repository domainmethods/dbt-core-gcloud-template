#!/usr/bin/env bash
# Tests for scripts/get_changed_models.sh change detection + DIFF_SELECT derivation.
#
# Dependency-free: requires bash 4+, git, coreutils. No bats, no pip packages.
# Builds a throwaway git repo per scenario so `git diff --name-only "$BASE_REF...HEAD"`
# is exercised for real, deterministically, without any network.
#
# Usage: bash tests/test_get_changed_models.sh
#
# Note: `set -e` is deliberately NOT used. The harness inspects the script's
# stdout and the $GITHUB_ENV it writes; aborting on a non-zero exit would defeat
# the purpose.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO_ROOT/scripts/get_changed_models.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "    ok   - $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "    FAIL - $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

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

# Creates a throwaway git repo with a single base commit and sets:
#   REPO  - the repo directory (also the cwd used to run the script)
#   BASE  - the base commit SHA the diff is taken against
make_repo() {
  REPO=$(mktemp -d)
  git -C "$REPO" init -q
  git -C "$REPO" config user.email "ci@example.com"
  git -C "$REPO" config user.name "CI Test"
  git -C "$REPO" config commit.gpgsign false
  mkdir -p "$REPO/models"
  echo "# base" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit -q -m "base"
  BASE=$(git -C "$REPO" rev-parse HEAD)
}

# Writes each given path (creating parent dirs) with throwaway content and
# commits the lot as one change on top of the base commit.
commit_files() {
  local f
  for f in "$@"; do
    mkdir -p "$REPO/$(dirname "$f")"
    echo "-- changed" > "$REPO/$f"
    git -C "$REPO" add "$f"
  done
  git -C "$REPO" commit -q -m "change"
}

# Runs the real script inside $REPO with BASE_REF=$1, capturing:
#   RUN_OUT - stdout+stderr (the human-facing log, incl. the KEY=VALUE echoes)
#   RUN_ENV - the contents the script wrote to $GITHUB_ENV (exact values)
run_script() {
  local base_ref=$1 genv="$REPO/github_env.txt"
  : > "$genv"
  RUN_OUT=$(cd "$REPO" && BASE_REF="$base_ref" GITHUB_ENV="$genv" bash "$SCRIPT" 2>&1)
  RUN_ENV=$(cat "$genv")
}

cleanup() { [[ -n "${REPO:-}" && -d "$REPO" ]] && rm -rf "$REPO"; }

scenario_1() {
  echo "  scenario 1: no changed files -> HAS_MODEL_CHANGES=false, DIFF_SELECT empty"
  make_repo
  # HEAD == BASE, so the diff is empty.
  run_script "$BASE"
  assert_contains "$RUN_OUT" "HAS_MODEL_CHANGES=false" "no changes reports HAS_MODEL_CHANGES=false"
  # Exact emptiness is only unambiguous in the env file (stdout uses a <none> display fallback).
  assert_contains "$RUN_ENV" "DIFF_SELECT=" "DIFF_SELECT key is exported"
  assert_not_contains "$RUN_ENV" "DIFF_SELECT=." "DIFF_SELECT is empty (no value after '=')"
  assert_not_contains "$RUN_ENV" "+" "no selector tokens are emitted for a no-change diff"
  cleanup
}

scenario_2() {
  echo "  scenario 2: one changed .sql model -> DIFF_SELECT=<name>+"
  make_repo
  commit_files "models/staging/stg_foo.sql"
  run_script "$BASE"
  assert_contains "$RUN_OUT" "HAS_MODEL_CHANGES=true" "a model change reports HAS_MODEL_CHANGES=true"
  assert_contains "$RUN_OUT" "DIFF_SELECT=stg_foo+" "stdout advertises the single selector"
  assert_contains "$RUN_ENV" "DIFF_SELECT=stg_foo+" "env exports exactly one 'name+' token"
  cleanup
}

scenario_3() {
  echo "  scenario 3: multiple changed .sql models -> space-separated 'a+ b+'"
  make_repo
  # git diff --name-only sorts by path: marts/ precedes staging/, so the order
  # is deterministic: fct_b then stg_a.
  commit_files "models/marts/fct_b.sql" "models/staging/stg_a.sql"
  run_script "$BASE"
  assert_contains "$RUN_ENV" "DIFF_SELECT=fct_b+ stg_a+" "both models become space-separated 'name+' tokens"
  cleanup
}

scenario_4() {
  echo "  scenario 4: non-model dbt changes -> HAS_MODEL_CHANGES=true, DIFF_SELECT empty"
  # A macro change is dbt-relevant (build must run) but yields no model name,
  # so DIFF_SELECT stays empty and the state:modified+ fallback governs.
  make_repo
  commit_files "macros/my_macro.sql"
  run_script "$BASE"
  assert_contains "$RUN_OUT" "HAS_MODEL_CHANGES=true" "a macro change still flags model changes"
  assert_not_contains "$RUN_ENV" "DIFF_SELECT=." "a macro-only change exports an empty DIFF_SELECT"
  assert_not_contains "$RUN_ENV" "+" "a macro-only change emits no selector tokens"
  cleanup

  # dbt_project.yml is the same class of change.
  make_repo
  commit_files "dbt_project.yml"
  run_script "$BASE"
  assert_contains "$RUN_OUT" "HAS_MODEL_CHANGES=true" "a dbt_project.yml change flags model changes"
  assert_not_contains "$RUN_ENV" "DIFF_SELECT=." "a dbt_project.yml-only change exports an empty DIFF_SELECT"
  cleanup
}

echo "test_get_changed_models.sh"
scenario_1
scenario_2
scenario_3
scenario_4

echo ""
echo "passed: $PASS_COUNT  failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
