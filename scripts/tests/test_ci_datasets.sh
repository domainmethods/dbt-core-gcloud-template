#!/usr/bin/env bash
# Exercises provisioning and both cleanup paths with a local recording bq stub.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
cd "$sandbox"
mkdir bin datasets target
export PATH="$sandbox/bin:$PATH" BQ_TEST_DIR="$sandbox"

cat > bin/bq <<'PYTHON'
#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
root = Path(os.environ["BQ_TEST_DIR"])
with (root / "calls.log").open("a") as log:
    print(" ".join(args), file=log)

command = next(arg for arg in args if not arg.startswith("--"))
datasets = root / "datasets"
if command == "ls":
    # Return lookalikes even when the caller requests a label filter.
    print(json.dumps([json.loads(path.read_text()) for path in sorted(datasets.glob("*.json"))]))
    sys.exit(0)

project = next((arg.split("=", 1)[1] for arg in args if arg.startswith("--project_id=")), "ciproj")
dataset = args[-1].split(":")[-1]
path = datasets / f"{dataset}.json"
if command == "mk":
    if path.exists():
        sys.exit(1)
    labels = dict(arg.removeprefix("--label=").split(":", 1) for arg in args if arg.startswith("--label="))
    location = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--location="))
    path.write_text(json.dumps({
        "datasetReference": {"projectId": project, "datasetId": dataset},
        "labels": labels, "location": location, "creationTime": "1",
        "access": [{"specialGroup": "projectWriters", "role": "WRITER"}],
    }))
elif command == "show":
    print(path.read_text())
elif command == "update":
    details = json.loads(path.read_text())
    details.update(json.loads(Path(args[args.index("--source") + 1]).read_text()))
    path.write_text(json.dumps(details))
elif command == "rm":
    path.unlink()
else:
    sys.exit(f"Unexpected bq command: {args}")
PYTHON
chmod +x bin/bq

export GITHUB_ACTIONS=true GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$sandbox/event.json"
export GITHUB_REPOSITORY_ID=1098 GITHUB_RUN_ID=481516 GITHUB_RUN_ATTEMPT=2
export DBT_TARGET=ci DBT_GCP_PROJECT_CI=ciproj DBT_BQ_LOCATION=EU DBT_BQ_DATASET=ci_pr_17_481516_2
export CI_SA_EMAIL=ci@example.test MAKE_DATASET_READONLY=true
export MAX_AGE_HOURS=24 DATASET_PREFIX=ci_pr_ DRY_RUN=false
printf '{"number":17}\n' > "$GITHUB_EVENT_PATH"
base=$DBT_BQ_DATASET
finance="${base}_finance"
audit="${base}_dbt_test__audit"
lookalike="${base}_finance_backup"
other_run="${base}0"
fresh="ci_pr_18_481517_1"

fail() { echo "FAIL: $*" >&2; exit 1; }
seed_dataset() {
  jq -n --arg dataset "$1" --arg repo "${2:-}" --arg run "${3:-}" --arg created "${4:-1}" '
    {
      datasetReference: {projectId: "ciproj", datasetId: $dataset},
      labels: (if $repo == "" then {} else {dbt_ci_repository: $repo, dbt_ci_run: $run} end),
      location: "EU",
      creationTime: $created
    }' > "datasets/$1.json"
}
assert_deletes() {
  local expected actual
  expected=$(printf '%s\n' "$@" | sort)
  actual=$(sed -n 's/^.*rm -r -f -d ciproj://p' calls.log | sort)
  [[ "$actual" == "$expected" ]] || fail "expected delete calls for [$expected], got [$actual]"
}

echo "scenario: per-run cleanup refuses a developer dataset or the wrong run attempt"
seed_dataset analytics_alice
: > calls.log
if GITHUB_ACTIONS=false DBT_TARGET=dev DBT_BQ_DATASET=analytics_alice \
    bash "$REPO_ROOT/scripts/drop_bq_dataset.sh"; then
  fail "developer dataset was accepted"
fi
if DBT_BQ_DATASET="$other_run" bash "$REPO_ROOT/scripts/drop_bq_dataset.sh"; then
  fail "another run attempt was accepted"
fi
[[ ! -s calls.log ]] || fail "invalid run identity reached bq"

echo "scenario: creation labels the base and custom schemas before dbt can use them"
cat > target/manifest.json <<JSON
{"nodes": {
  "model.example.finance": {"database":"ciproj","schema":"$finance","resource_type":"model","config":{"materialized":"table"}},
  "seed.example.accounts": {"database":"ciproj","schema":"$finance","resource_type":"seed"},
  "test.example.check": {"database":"ciproj","schema":"$audit","resource_type":"test","config":{"store_failures":true}},
  "model.example.ephemeral": {"database":"ciproj","schema":"${base}_ephemeral","resource_type":"model","config":{"materialized":"ephemeral"}},
  "model.example.external": {"database":"other","schema":"${base}_external","resource_type":"model"},
  "model.example.unrelated": {"database":"ciproj","schema":"analytics","resource_type":"model"}
}}
JSON
bash "$REPO_ROOT/scripts/create_bq_dataset.sh"
for dataset in "$base" "$finance" "$audit"; do
  jq -e --arg base "$base" '
    .labels == {dbt_ci_repository: "1098", dbt_ci_run: $base}
    and .location == "EU"
    and .access == [{"userByEmail":"ci@example.test","role":"WRITER"}]
  ' "datasets/$dataset.json" >/dev/null || fail "incorrect ownership, location or ACL for $dataset"
done
[[ $(sed -n '/ mk -d /p' calls.log | wc -l) -eq 3 ]] || fail "unexpected dataset creation"

echo "scenario: immediate cleanup drops owned schemas and leaves lookalikes"
seed_dataset "$lookalike"
seed_dataset "${base}_foreign" 555 "$base"
seed_dataset "${other_run}_finance" 1098 "$other_run"
: > calls.log
bash "$REPO_ROOT/scripts/drop_bq_dataset.sh"
assert_deletes "$base" "$finance" "$audit"

echo "scenario: the sweep deletes old owned datasets and leaves fresh or unrelated datasets"
seed_dataset "$base" 1098 "$base"
seed_dataset "$finance" 1098 "$base"
seed_dataset "$fresh" 1098 "$fresh" "$(date +%s)000"
: > calls.log
output=$(DRY_RUN=true bash "$REPO_ROOT/scripts/cleanup_ci_datasets.sh")
[[ "$output" == *"would delete: $finance"* ]] || fail "dry run did not report the old custom schema"
assert_deletes
bash "$REPO_ROOT/scripts/cleanup_ci_datasets.sh"
assert_deletes "$base" "$finance" "${other_run}_finance"

echo "scenario: creation refuses an existing unowned manifest schema"
seed_dataset "$finance"
if bash "$REPO_ROOT/scripts/create_bq_dataset.sh"; then
  fail "dataset collision accepted"
fi
jq -e '.labels == {}' "datasets/$finance.json" >/dev/null || fail "existing dataset was relabeled"

echo "CI dataset tests passed"
