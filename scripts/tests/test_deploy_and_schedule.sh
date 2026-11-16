#!/usr/bin/env bash
# Tests for infra/30-deploy-cloud-run-job.sh and infra/80-deploy-docs-viewer.sh
# (Cloud Build fallback when the Docker daemon isn't running, #28) and
# infra/40-schedule-prod-job.sh (SCHED_CRON, #64).
# Dependency-free: bash, coreutils, jq. Stubs gcloud and docker on PATH. No `set -e`.
#
# Usage: bash scripts/tests/test_deploy_and_schedule.sh
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "    ok   - $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "    FAIL - $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
assert_contains() { [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 (missing '$2')"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] && pass "$3" || fail "$3 (unexpected '$2')"; }
assert_eq() { [[ "$1" == "$2" ]] && pass "$3" || fail "$3 (got '$1', want '$2')"; }

# Sandbox: $SANDBOX/{infra/<script>,infra/.env,docs-viewer/,bin/gcloud,bin/docker?}.
# gcloud logs every call and succeeds; image tags never exist (forces a build) and
# IAM policies are empty. docker logs its calls; `docker info` fails when
# STUB_DAEMON_DOWN=1, as it does with the CLI installed and the daemon stopped.
make_sandbox() {  # $1 = script name, $2 = "with-docker" or "no-docker"
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/bin" "$SANDBOX/infra" "$SANDBOX/docs-viewer" "$SANDBOX/scripts"
  cp "$REPO_ROOT/infra/$1" "$SANDBOX/infra/"
  cp "$REPO_ROOT/scripts/"*.sh "$SANDBOX/scripts/" 2>/dev/null || true
  cat > "$SANDBOX/infra/.env" <<'ENV'
PROJECT_ID=test-proj
REGION=us-central1
AR_REPO=dbt
IMAGE_NAME=dbt
IMAGE_TAG=v1
PROD_SA_ID=dbt-prod
PROD_DATASET=analytics
BQ_LOCATION=US
SCHEDULER_SA_ID=dbt-scheduler
DBT_DOCS_BUCKET=docs-bucket
DOCS_VIEWER_SERVICE=dbt-docs
DOCS_VIEWER_SA_ID=dbt-docs-viewer
ENV
  : > "$SANDBOX/calls.log"
  cat > "$SANDBOX/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "gcloud $*" >> "$STUB_DIR/calls.log"
case "$*" in
  "artifacts docker tags list"*) exit 0 ;;
  *"get-iam-policy"*) echo '{}'; exit 0 ;;
  "scheduler jobs describe"*) exit 1 ;;
  "run services describe"*) echo "https://dbt-docs.example"; exit 0 ;;
esac
exit 0
STUB
  if [[ "$2" == "with-docker" ]]; then
    cat > "$SANDBOX/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_DIR/calls.log"
[[ "$1" == info && "${STUB_DAEMON_DOWN:-0}" == "1" ]] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
exit 0
STUB
  fi
  chmod +x "$SANDBOX"/bin/*
  # PATH is only $SANDBOX/bin: a host docker, gcloud or gh in /usr/bin would mask
  # the stubs (and make "no docker binary" find one), so link just the tools the
  # scripts use.
  local tool path
  for tool in $HOST_TOOLS; do
    path=$(command -v "$tool" 2>/dev/null) || continue
    ln -s "$path" "$SANDBOX/bin/$tool"
  done
}
HOST_TOOLS="bash env cat dirname basename mktemp rm mkdir cp mv ls jq grep sed awk tr cut head tail sort uniq wc date sleep"

run_script() {  # $1 = script name, $2 = extra env; sets RUN_OUT, RUN_RC, CALLS
  RUN_OUT=$(env -i PATH="$SANDBOX/bin" STUB_DIR="$SANDBOX" \
    HOME="$SANDBOX" $2 bash "$SANDBOX/infra/$1" 2>&1)
  RUN_RC=$?
  CALLS=$(cat "$SANDBOX/calls.log")
}

for script in 30-deploy-cloud-run-job.sh 80-deploy-docs-viewer.sh; do
  echo "scenario: $script, docker daemon running → docker build (#28)"
  make_sandbox "$script" with-docker; run_script "$script" ''
  assert_eq "$RUN_RC" "0" "exits 0"
  assert_contains "$CALLS" "docker build" "builds with docker"
  assert_not_contains "$CALLS" "builds submit" "no Cloud Build"

  echo "scenario: $script, docker installed but daemon down → Cloud Build (#28)"
  make_sandbox "$script" with-docker; run_script "$script" 'STUB_DAEMON_DOWN=1'
  assert_eq "$RUN_RC" "0" "exits 0"
  assert_not_contains "$CALLS" "docker build" "skips docker build"
  assert_contains "$CALLS" "builds submit" "builds with Cloud Build"
  assert_contains "$RUN_OUT" "daemon" "says the daemon isn't running"

  echo "scenario: $script, no docker binary → Cloud Build"
  make_sandbox "$script" no-docker; run_script "$script" ''
  assert_eq "$RUN_RC" "0" "exits 0"
  assert_contains "$CALLS" "builds submit" "builds with Cloud Build"
done

echo "scenario: 80-deploy-docs-viewer.sh Cloud Build targets the viewer app (#28)"
make_sandbox 80-deploy-docs-viewer.sh no-docker; run_script 80-deploy-docs-viewer.sh ''
assert_contains "$(grep 'builds submit' <<<"$CALLS")" "--tag us-central1-docker.pkg.dev/test-proj/dbt/dbt-docs:v1" "tags the viewer image"
assert_contains "$(grep 'builds submit' <<<"$CALLS")" "./docs-viewer" "builds the viewer directory"

echo "scenario: 40-schedule-prod-job.sh uses the 06:00 UTC default (#64)"
make_sandbox 40-schedule-prod-job.sh no-docker; run_script 40-schedule-prod-job.sh ''
assert_eq "$RUN_RC" "0" "exits 0"
assert_contains "$(grep 'scheduler jobs create' <<<"$CALLS")" "--schedule=0 6 * * *" "default cron"

echo "scenario: 40-schedule-prod-job.sh reads SCHED_CRON (#64)"
make_sandbox 40-schedule-prod-job.sh no-docker
echo 'SCHED_CRON="0 9 * * *"' >> "$SANDBOX/infra/.env"
run_script 40-schedule-prod-job.sh ''
assert_contains "$(grep 'scheduler jobs create' <<<"$CALLS")" "--schedule=0 9 * * *" "custom cron from .env"
assert_contains "$RUN_OUT" "0 9 * * *" "says which schedule it set"

echo "scenario: release.yml schedules with SCHED_CRON, not a hard-coded cron (#64)"
rel=$(cat "$REPO_ROOT/.github/workflows/release.yml")
assert_not_contains "$rel" '--schedule "0 6 * * *"' "no hard-coded cron in release.yml"
assert_contains "$rel" 'secrets.SCHED_CRON' "release.yml reads SCHED_CRON"

echo "scenario: sandbox PATH hides host docker/gcloud/gh"
make_sandbox 30-deploy-cloud-run-job.sh no-docker
leak=$(env -i PATH="$SANDBOX/bin" bash -c 'command -v docker; command -v gh' 2>/dev/null)
assert_eq "$leak" "" "no docker or gh resolvable in the sandbox"

echo "results: passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
