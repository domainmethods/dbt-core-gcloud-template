#!/usr/bin/env bash
# Static checks on .github/workflows/ci.yml, since this repo's Actions can't be run
# locally: docs-only PRs must not touch BigQuery (#29), and yamllint runs as its own
# fast job that gates the BigQuery build (#33).
# Needs python3 with PyYAML (installed with yamllint). No `set -e`.
#
# Usage: bash scripts/tests/test_ci_workflow.sh
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "    ok   - $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "    FAIL - $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
assert_contains() { [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 (missing '$2')"; }
assert_eq() { [[ "$1" == "$2" ]] && pass "$3" || fail "$3 (got '$1', want '$2')"; }

# wf <python expression over `w`, the parsed workflow> -> printed result
wf() {
  python3 -c 'import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
print(eval(sys.argv[2]))' "$REPO_ROOT/.github/workflows/ci.yml" "$1"
}
step_if() {  # $1 = bigquery-ci step name -> its `if:` ("" if none or missing)
  wf "next((s.get('if', '') for s in w['jobs']['bigquery-ci']['steps'] if s.get('name') == '$1'), 'MISSING')"
}

echo "scenario 1: docs-only PRs skip every BigQuery step (#29)"
for step in "Create ephemeral dataset" "Generate docs (optional preview)" \
            "Generate schema diffs for changed models" "Cleanup dataset"; do
  assert_contains "$(step_if "$step")" "env.HAS_MODEL_CHANGES != 'false'" "'$step' gated on HAS_MODEL_CHANGES"
done
assert_contains "$(step_if "Cleanup dataset")" "always()" "cleanup still runs after a failed build"
assert_contains "$(wf "next(s['run'] for s in w['jobs']['bigquery-ci']['steps'] if s.get('name') == 'Create ephemeral dataset')")" \
  "dbt parse --target ci"$'\n'"bash scripts/create_bq_dataset.sh" "dataset provisioning uses the freshly parsed CI manifest"

echo "scenario 2: yamllint is its own job and gates bigquery-ci (#33)"
assert_eq "$(wf "'yamllint' in w['jobs']")" "True" "yamllint job exists"
assert_eq "$(wf "sorted(w['jobs']['bigquery-ci']['needs'])")" "['lint', 'yamllint']" "bigquery-ci needs lint and yamllint"
assert_contains "$(wf "' '.join(s.get('run', '') for s in w['jobs']['yamllint']['steps'])")" "yamllint ." "lints the whole repo"
assert_eq "$(wf "any('dbt' in s.get('run', '') for s in w['jobs']['yamllint']['steps'])")" "False" "no dbt install in the yamllint job"
assert_eq "$(wf "any('yamllint' in s.get('run', '') for s in w['jobs']['lint']['steps'])")" "False" "lint job does not run yamllint twice"

echo "scenario 3: the warehouse job uses the configured BigQuery location (#97)"
assert_eq "$(wf "w['jobs']['bigquery-ci'].get('env', {}).get('DBT_BQ_LOCATION')")" \
  "\${{ secrets.BQ_LOCATION || 'US' }}" "warehouse job resolves BQ_LOCATION with a US default"
assert_eq "$(wf "next(s for s in w['jobs']['lint']['steps'] if s.get('run') == 'bash scripts/lint_ci_sql.sh')['env']['DBT_BQ_LOCATION']")" "US" \
  "SQLFluff still uses the offline US lint profile"
profile_location=$(python3 -c 'import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))["dbt_gcloud"]["outputs"]["ci"]["location"])' "$REPO_ROOT/profiles/profiles.yml")
assert_eq "$profile_location" "{{ env_var('DBT_BQ_LOCATION', 'US') }}" "CI profile reads the warehouse job environment"

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
printf '%s\n' '#!/usr/bin/env bash' 'echo "$*" >> "$BQ_CALL_LOG"' > "$sandbox/bq"
chmod +x "$sandbox/bq"
mkdir "$sandbox/target"
printf '{"nodes":{}}\n' > "$sandbox/target/manifest.json"
printf '{"number":97}\n' > "$sandbox/event.json"
if (cd "$sandbox" && PATH="$sandbox:$PATH" BQ_CALL_LOG="$sandbox/bq.log" \
    GITHUB_ACTIONS=true GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$sandbox/event.json" \
    GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 GITHUB_REPOSITORY_ID=999 DBT_TARGET=ci \
    DBT_GCP_PROJECT_CI=ciproj DBT_BQ_DATASET=ci_pr_97_123_1 DBT_BQ_LOCATION=EU MAKE_DATASET_READONLY=false \
    bash "$REPO_ROOT/scripts/create_bq_dataset.sh" >/dev/null); then
  assert_contains "$(cat "$sandbox/bq.log")" "--location=EU mk -d" "bq creates the CI dataset in EU"
else
  fail "the CI dataset creation script exited unsuccessfully"
fi

echo "results: passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
