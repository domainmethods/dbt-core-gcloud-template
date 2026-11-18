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
  cp -R "$REPO_ROOT/scripts/lib" "$SANDBOX/scripts/"
  cat > "$SANDBOX/infra/.env" <<'ENV'
PROJECT_ID=test-proj
PROJECT_NUMBER=111111111111
REGION=us-central1
AR_REPO=dbt
IMAGE_NAME=dbt
IMAGE_TAG=v1
PROD_SA_ID=dbt-prod
CI_SA_ID=dbt-ci
PROD_DATASET=analytics
BQ_LOCATION=US
SCHEDULER_SA_ID=dbt-scheduler
DBT_DOCS_BUCKET=docs-bucket
DOCS_VIEWER_SERVICE=dbt-docs
DOCS_VIEWER_SA_ID=dbt-docs-viewer
GITHUB_REPO=owner/repo
ENV
  : > "$SANDBOX/calls.log"
  cat > "$SANDBOX/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "gcloud $*" >> "$STUB_DIR/calls.log"
case "$*" in
  "resource-manager org-policies describe "*) echo "{\"booleanPolicy\":{\"enforced\":${STUB_ORG_POLICY:-false}}}" ;;
  "projects describe prod-proj "*) echo '222222222222' ;;
  "artifacts repositories describe"*) [[ "${STUB_CREATE_RESOURCES:-0}" != 1 ]] || exit 1 ;;
  "iam service-accounts describe"*) [[ "${STUB_CREATE_RESOURCES:-0}" != 1 ]] || exit 1 ;;
  "storage buckets describe"*) echo '{"uniform_bucket_level_access":true}' ;;
  "storage buckets get-iam-policy"*)
    if [[ -f "$STUB_DIR/bucket.json" ]]; then cat "$STUB_DIR/bucket.json"; else
      echo '{"etag":"bucket-etag","bindings":[{"role":"roles/storage.objectAdmin","members":["serviceAccount:dbt-ci@test-proj.iam.gserviceaccount.com"]}]}'
    fi
    ;;
  "storage buckets set-iam-policy"*) cp "$5" "$STUB_DIR/bucket.json" ;;
  "artifacts docker tags list"*) exit 0 ;;
  "builds submit"*) echo "staging: $PWD source=${@: -1} ignore=${CLOUDSDK_GCLOUDIGNORE_ENABLED:-unset}" >> "$STUB_DIR/calls.log" ;;
  *"get-iam-policy"*) echo '{}'; exit 0 ;;
  "scheduler jobs describe"*) exit 1 ;;
  "run services describe"*) echo "https://dbt-docs.example"; exit 0 ;;
esac
exit 0
STUB
  cat > "$SANDBOX/bin/bq" <<'STUB'
#!/usr/bin/env bash
echo "bq $*" >> "$STUB_DIR/calls.log"
case " $* " in
  *" show --format=none "*) exit 1 ;;
  *" get-iam-policy "*) echo '{"bindings":[]}' ;;
  *" show --format=prettyjson "*) echo '{"etag":"acl-etag","access":[{"role":"WRITER","specialGroup":"projectWriters"}]}' ;;
esac
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
HOST_TOOLS="bash env cat dirname basename mktemp rm mkdir cp mv ls jq grep sed awk tr cut head tail sort uniq wc date sleep diff"

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
  assert_not_contains "$RUN_OUT" "docker not found;" "doesn't claim docker is missing"

  echo "scenario: $script, no docker binary → Cloud Build"
  make_sandbox "$script" no-docker; run_script "$script" 'CLOUDSDK_GCLOUDIGNORE_ENABLED=false'
  assert_eq "$RUN_RC" "0" "exits 0"
  assert_contains "$CALLS" "builds submit" "builds with Cloud Build"
  assert_contains "$RUN_OUT" "docker not found" "says docker is missing"
  context=.
  if [[ "$script" == 80-deploy-docs-viewer.sh ]]; then context=./docs-viewer; fi
  assert_contains "$CALLS" "staging: $SANDBOX source=$context ignore=true" "stages the expected context with ignore rules enabled"
done

echo "scenario: 80-deploy-docs-viewer.sh Cloud Build targets the viewer app (#28)"
make_sandbox 80-deploy-docs-viewer.sh no-docker; run_script 80-deploy-docs-viewer.sh ''
assert_contains "$(grep 'builds submit' <<<"$CALLS")" "--tag us-central1-docker.pkg.dev/test-proj/dbt/dbt-docs:v1" "tags the viewer image"
assert_contains "$(grep 'builds submit' <<<"$CALLS")" "./docs-viewer" "builds the viewer directory"

echo "scenario: Cloud Build uses staging exclusions for a root viewer context (#115)"
: > "$SANDBOX/calls.log"
run_script 80-deploy-docs-viewer.sh 'CLOUDSDK_GCLOUDIGNORE_ENABLED=false DOCS_VIEWER_DIR=.'
assert_contains "$CALLS" "staging: $SANDBOX source=. ignore=true" "viewer override stages the root with ignore rules enabled"

check_upload_list() (
  local source="$1" stage uploads
  stage=$(mktemp -d)
  trap 'rm -rf "$stage"' EXIT
  mkdir -p "$stage/source"/{infra,secrets,nested,.direnv}
  cp "$REPO_ROOT/$source/.gcloudignore" "$stage/source/" || exit 1
  if [[ "$source" == . ]]; then
    cp "$REPO_ROOT/.gitignore" "$stage/source/"
  fi
  cd "$stage/source" || exit 1
  touch Dockerfile ordinary.json .env .envrc .direnv/placeholder infra/notes.txt \
    keyfile.json nested/keyfile.json secrets/placeholder.json
  if command -v gcloud >/dev/null; then
    # This SDK command only enumerates files locally. Give it an empty config.
    uploads=$(env -i PATH="$PATH" HOME="$stage" CLOUDSDK_CONFIG="$stage/sdk" \
      CLOUDSDK_GCLOUDIGNORE_ENABLED=true CLOUDSDK_CORE_DISABLE_USAGE_REPORTING=true \
      gcloud meta list-files-for-upload) || exit 1
  else
    # Check the explicit patterns with Git's ignore syntax when gcloud is absent.
    git init -q || exit 1
    uploads=$(git ls-files --others --exclude-from=.gcloudignore) || exit 1
  fi
  test "$(sort <<<"$uploads")" = $'Dockerfile\nordinary.json'
)
for source in . docs-viewer; do
  if check_upload_list "$source"; then
    pass "$source upload list contains only build files"
  else
    fail "$source upload list should contain only build files"
  fi
done

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
assert_contains "$rel" 'SCHED_CRON: ${{ secrets.SCHED_CRON }}' "passes SCHED_CRON via env:"
assert_not_contains "$rel" '"${{ secrets.SCHED_CRON }}"' "doesn't inline the secret into the script"

echo "scenario: bootstrap uses the production and identity project owners (#107)"
make_sandbox 10-bootstrap.sh no-docker
cat >> "$SANDBOX/infra/.env" <<'ENV'
PROD_PROJECT_ID=prod-proj
INT_DATASET=integration
ENV
run_script 10-bootstrap.sh STUB_CREATE_RESOURCES=1
assert_eq "$RUN_RC" "0" "bootstrap exits 0"
for api in run cloudscheduler artifactregistry bigquery bigquerystorage; do
  assert_contains "$CALLS" "services enable $api.googleapis.com --project prod-proj" "$api enabled in prod"
done
assert_contains "$CALLS" "services enable sts.googleapis.com --project test-proj" "WIF API stays in identity project"
assert_contains "$(grep 'artifacts repositories create' <<< "$CALLS")" "--project prod-proj" "registry created in prod"
assert_contains "$(grep 'service-accounts create dbt-prod ' <<< "$CALLS")" "--project test-proj" "prod runtime SA stays in identity project"
assert_contains "$(grep 'service-accounts create dbt-scheduler ' <<< "$CALLS")" "--project prod-proj" "Scheduler OAuth SA belongs to prod"
assert_contains "$(grep 'mk -d' <<< "$CALLS")" "prod-proj:analytics" "prod dataset created in prod"
assert_contains "$(grep 'mk -d' <<< "$CALLS")" "test-proj:integration" "integration dataset stays in identity project"
assert_contains "$CALLS" "show --format=prettyjson --dataset_view=ACL prod-proj:analytics" "reads the prod dataset ACL in prod"
assert_contains "$(grep -- '--update_mode=UPDATE_ACL' <<< "$CALLS")" "prod-proj:analytics" "prod dataset ACL updates target prod"
assert_contains "$CALLS" "show --format=prettyjson --dataset_view=ACL test-proj:integration" "integration dataset ACL stays in identity project"
assert_not_contains "$CALLS" "test-proj:analytics" "never touches a prod dataset in the identity project"
assert_contains "$RUN_OUT" "Verified CI read/list and ci/ write bindings" "artifact bucket checks still pass"
assert_contains "$CALLS" "projects add-iam-policy-binding prod-proj --member=serviceAccount:dbt-prod@test-proj.iam.gserviceaccount.com --role=roles/bigquery.jobUser" "runtime can create jobs in the prod warehouse"
assert_contains "$CALLS" "projects add-iam-policy-binding prod-proj --member=serviceAccount:dbt-prod@test-proj.iam.gserviceaccount.com --role=roles/run.developer" "release can deploy in prod"
assert_contains "$CALLS" "projects add-iam-policy-binding prod-proj --member=serviceAccount:dbt-prod@test-proj.iam.gserviceaccount.com --role=roles/cloudscheduler.admin" "release can schedule in prod"
assert_contains "$CALLS" "projects add-iam-policy-binding prod-proj --member=serviceAccount:dbt-prod@test-proj.iam.gserviceaccount.com --role=roles/artifactregistry.writer" "release can push images in prod"
assert_contains "$CALLS" "beta services identity create --service=run.googleapis.com --project prod-proj" "creates the prod Cloud Run agent before using it"
assert_contains "$CALLS" "dbt-prod@test-proj.iam.gserviceaccount.com --project test-proj --member serviceAccount:service-222222222222@serverless-robot-prod.iam.gserviceaccount.com --role roles/iam.serviceAccountTokenCreator" "prod Cloud Run agent can use the identity-project runtime SA"
assert_contains "$CALLS" "dbt-scheduler@prod-proj.iam.gserviceaccount.com --project prod-proj --member serviceAccount:service-222222222222@gcp-sa-cloudscheduler.iam.gserviceaccount.com --role roles/iam.serviceAccountTokenCreator" "prod Scheduler agent can mint the token"

echo "scenario: enforced cross-project service account policy blocks bootstrap (#107)"
make_sandbox 10-bootstrap.sh no-docker
echo 'PROD_PROJECT_ID=prod-proj' >> "$SANDBOX/infra/.env"
run_script 10-bootstrap.sh STUB_ORG_POLICY=true
assert_eq "$RUN_RC" "1" "bootstrap exits before provisioning"
assert_contains "$RUN_OUT" "[error] Cross-project Cloud Run requires iam.disableCrossProjectServiceAccountUsage" "fails on the cross-project policy check"
assert_contains "$CALLS" "resource-manager org-policies describe iam.disableCrossProjectServiceAccountUsage --project test-proj" "reads the policy in the identity project"
assert_not_contains "$CALLS" "services enable" "no API mutation with the policy enforced"

echo "scenario: local deploy sends image, build, job and warehouse to prod (#107)"
make_sandbox 30-deploy-cloud-run-job.sh no-docker
echo 'PROD_PROJECT_ID=prod-proj' >> "$SANDBOX/infra/.env"
run_script 30-deploy-cloud-run-job.sh STUB_CREATE_RESOURCES=1
assert_eq "$RUN_RC" "0" "deployment exits 0"
assert_contains "$(grep 'artifacts repositories create' <<< "$CALLS")" "--project prod-proj" "creates registry in prod"
assert_contains "$(grep 'builds submit' <<< "$CALLS")" "--tag us-central1-docker.pkg.dev/prod-proj/dbt/dbt:v1 --project prod-proj" "Cloud Build targets prod image"
job_call=$(grep 'run jobs deploy' <<< "$CALLS")
assert_contains "$job_call" "--project prod-proj" "deploy targets prod project"
assert_contains "$job_call" "--service-account=dbt-prod@test-proj.iam.gserviceaccount.com" "attaches the runtime SA from the identity project"
assert_contains "$job_call" "DBT_GCP_PROJECT_PROD=prod-proj" "sets BigQuery project in runtime"

echo "scenario: local scheduler uses a prod OAuth SA and a prod Run job (#107)"
make_sandbox 40-schedule-prod-job.sh no-docker
echo 'PROD_PROJECT_ID=prod-proj' >> "$SANDBOX/infra/.env"
run_script 40-schedule-prod-job.sh ''
assert_eq "$RUN_RC" "0" "Scheduler setup exits 0"
assert_contains "$(grep 'run jobs add-iam-policy-binding' <<< "$CALLS")" "serviceAccount:dbt-scheduler@prod-proj.iam.gserviceaccount.com" "grants prod Scheduler SA"
sched_call=$(grep 'scheduler jobs create' <<< "$CALLS")
assert_contains "$sched_call" "--project prod-proj" "scheduler targets prod project"
assert_contains "$sched_call" "projects/prod-proj/locations/us-central1/jobs/dbt-prod-run:run" "scheduler invokes prod job"

echo "scenario: sandbox PATH hides host docker/gcloud/gh"
make_sandbox 30-deploy-cloud-run-job.sh no-docker
leak=$(env -i PATH="$SANDBOX/bin" bash -c 'command -v docker; command -v gh' 2>/dev/null)
assert_eq "$leak" "" "no docker or gh resolvable in the sandbox"

echo "results: passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
