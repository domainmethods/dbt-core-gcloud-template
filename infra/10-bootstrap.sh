#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env
source ../scripts/lib/bigquery_acl.sh

command -v gcloud >/dev/null || { echo "gcloud not found"; exit 1; }
command -v bq >/dev/null || { echo "bq not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Helpers
info(){ echo "[info] $*"; }
warn(){ echo "[warn] $*"; }
require_env(){
  local v
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then
      echo "Missing env: $v"
      exit 1
    fi
  done
  return 0
}

ensure_api(){
  local api="$1" project="$2"
  info "Ensuring API enabled in $project: $api"
  gcloud services enable "$api" --project "$project" >/dev/null
}
ensure_sa(){
  local id="$1" dn="$2" project="$3"
  local email="${id}@${project}.iam.gserviceaccount.com"
  if gcloud iam service-accounts describe "$email" --project "$project" >/dev/null 2>&1; then
    info "SA exists: $email"
  else
    info "Creating SA: $email"
    gcloud iam service-accounts create "$id" --display-name="$dn" --project "$project"
  fi
}
ensure_sa_binding(){
  local email="$1" role="$2" member="$3" project="$4"
  if gcloud iam service-accounts get-iam-policy "$email" --project "$project" --format=json |
    jq -e --arg r "$role" --arg m "$member" '
      any(.bindings[]?; .role == $r and .condition == null and any(.members[]?; . == $m))
    ' >/dev/null; then
    info "SA IAM binding exists: $email $role -> $member"
  else
    info "Adding SA IAM binding: $email $role -> $member"
    gcloud iam service-accounts add-iam-policy-binding "$email" \
      --project "$project" --member "$member" --role "$role" --condition=None >/dev/null
  fi
}
ensure_ar_repo(){
  local project="$1"
  if gcloud artifacts repositories describe "$AR_REPO" --location "$REGION" --project "$project" >/dev/null 2>&1; then
    info "AR repo exists in $project: $AR_REPO"
  else
    info "Creating AR repo in $project: $AR_REPO"
    gcloud artifacts repositories create "$AR_REPO" \
      --repository-format=docker --location="$REGION" --description="dbt containers" --project "$project"
  fi
}
ensure_bucket(){
  local name="${DBT_DOCS_BUCKET}"
  local uri="gs://${name}"
  # First, try to describe. If it exists and we have access, we're done.
  local err_msg
  if err_msg="$(gcloud storage buckets describe "$uri" --project "$PROJECT_ID" 2>&1 >/dev/null)"; then
    info "Bucket exists: $uri"
    return 0
  fi
  # If describe failed with 403, it's very likely the name is already taken by another project.
  if [[ "$err_msg" == *"HttpError 403"* || "$err_msg" == *"Permission denied"* || "$err_msg" == *"AccessDenied"* || "$err_msg" == *"does not have storage.buckets.get"* ]]; then
    echo "[error] Bucket name '${name}' appears to be in use (403 on describe)." >&2
    echo "        GCS bucket names are global. Please set DBT_DOCS_BUCKET to a unique value" >&2
    echo "        (e.g., '${PROJECT_ID}-dbt-docs' or 'dbt-docs-${PROJECT_ID}') and re-run." >&2
    exit 1
  fi
  # Otherwise, attempt to create and handle a possible 409/name-taken error with a friendly message.
  info "Creating bucket: $uri"
  local create_out rc
  create_out="$(gcloud storage buckets create "$uri" --uniform-bucket-level-access --location="$REGION" --project "$PROJECT_ID" 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]]; then
    if [[ "$create_out" == *"409"* || "$create_out" == *"already exists"* || "$create_out" == *"not available"* || "$create_out" == *"already owns this bucket"* ]]; then
      echo "[error] Bucket name '${name}' is already taken globally." >&2
      echo "        Please choose a unique DBT_DOCS_BUCKET (e.g., '${PROJECT_ID}-dbt-docs')." >&2
    else
      echo "[error] Failed to create bucket ${uri}:" >&2
      echo "        ${create_out}" >&2
    fi
    exit 1
  fi
}

# Ensure a specific bucket by name (same behavior as ensure_bucket, but parameterized)
ensure_bucket_named(){
  local name="$1"
  local uri="gs://${name}"
  local err_msg create_out rc
  if err_msg="$(gcloud storage buckets describe "$uri" --project "$PROJECT_ID" 2>&1 >/dev/null)"; then
    info "Bucket exists: $uri"
    return 0
  fi
  if [[ "$err_msg" == *"HttpError 403"* || "$err_msg" == *"Permission denied"* || "$err_msg" == *"AccessDenied"* || "$err_msg" == *"does not have storage.buckets.get"* ]]; then
    echo "[error] Bucket name '${name}' appears to be in use (403 on describe)." >&2
    echo "        GCS bucket names are global. Please set a unique name and re-run." >&2
    exit 1
  fi
  info "Creating bucket: $uri"
  create_out="$(gcloud storage buckets create "$uri" --uniform-bucket-level-access --location="$REGION" --project "$PROJECT_ID" 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]]; then
    if [[ "$create_out" == *"409"* || "$create_out" == *"already exists"* || "$create_out" == *"not available"* || "$create_out" == *"already owns this bucket"* ]]; then
      echo "[error] Bucket name '${name}' is already taken globally." >&2
      echo "        Please choose a unique name (e.g., '${PROJECT_ID}-dbt-artifacts')." >&2
    else
      echo "[error] Failed to create bucket ${uri}:" >&2
      echo "        ${create_out}" >&2
    fi
    exit 1
  fi
}
ensure_dataset(){
  local ds="$1" desc="$2" project="$3"
  if bq --project_id="$project" --location="$BQ_LOCATION" show --format=none "${project}:${ds}" >/dev/null 2>&1; then
    info "Dataset exists: ${project}:${ds}"
  else
    info "Creating dataset: ${project}:${ds}"
    bq --project_id="$project" --location="$BQ_LOCATION" mk -d --description "$desc" "${project}:${ds}"
  fi
}

ensure_project_binding(){
  local role="$1" member="$2" project="$3"
  if gcloud projects get-iam-policy "$project" --format=json |
    jq -e --arg r "$role" --arg m "$member" '
      any(.bindings[]?; .role == $r and .condition == null and any(.members[]?; . == $m))
    ' >/dev/null; then
    info "Project IAM binding exists in $project: $role -> $member"
  else
    info "Adding project IAM binding in $project: $role -> $member"
    gcloud projects add-iam-policy-binding "$project" --member="$member" --role="$role" --condition=None --quiet >/dev/null
  fi
}

# Harden dataset ACLs so that only the specified writer_email has WRITER; all others get no write.
# Keeps projectOwners and projectReaders; removes projectWriters and any other WRITER entries.
harden_dataset_acl_writer_only() {
  update_dataset_acl "${3}:$1" '
    map(select(.specialGroup != "projectWriters"))
    | map(select(.role != "WRITER" or (.userByEmail == $writer)))
    | {"role":"WRITER","userByEmail": $writer} as $entry
    | if any(.[]; . == $entry) then . else . + [$entry] end
  ' --arg writer "$2"
}

read_bucket_policy() {
  local bucket="$1" policy_file="$2"
  if ! gcloud storage buckets get-iam-policy "gs://${bucket}" --format=json --project "$PROJECT_ID" > "$policy_file" ||
     ! jq -es '
       length == 1 and (.[0] |
         (.etag | type == "string" and length > 0 and . != "*")
         and (.bindings == null or (.bindings | type == "array")))
     ' "$policy_file" >/dev/null; then
    echo "[error] Could not read a versioned IAM policy for gs://${bucket}" >&2
    return 1
  fi
}

write_bucket_policy_if_changed() {
  local bucket="$1" before="$2" after="$3"
  if ! jq -es '.[0] == .[1]' "$before" "$after" >/dev/null; then
    info "Updating bucket IAM: gs://${bucket}"
    gcloud storage buckets set-iam-policy "gs://${bucket}" "$after" --project "$PROJECT_ID" >/dev/null
  fi
}

ensure_bucket_binding () {
  local bucket="$1" role="$2" member="$3" condition="${4:-null}"
  local tmp="${TMP_DIR}/bkt_iam_old.json" tmp2="${TMP_DIR}/bkt_iam_new.json"
  read_bucket_policy "$bucket" "$tmp"
  jq --arg role "$role" --arg member "$member" --argjson condition "$condition" '
    def target: .role == $role and .condition == $condition;
    if any(.bindings[]?; target and (.members | index($member))) then .
    elif any(.bindings[]?; target) then
      .bindings |= map(if target then .members += [$member] else . end)
    else
      .bindings += [{"role": $role, "members": [$member]}]
      | if $condition == null then . else .version = 3 | .bindings[-1].condition = $condition end
    end
  ' "$tmp" > "$tmp2"
  write_bucket_policy_if_changed "$bucket" "$tmp" "$tmp2"
}

remove_legacy_ci_bucket_writer() {
  local bucket="$1" policy="$2" updated="${TMP_DIR}/bkt_iam_migrated.json"
  jq --arg ci "serviceAccount:${CI_SA_EMAIL}" '
    if .bindings == null then . else
      .bindings |= map(
        if .role == "roles/storage.objectAdmin" and .condition == null and (.members | index($ci))
        then .members -= [$ci] | select(.members | length > 0)
        else .
        end
      )
    end
  ' "$policy" > "$updated"
  write_bucket_policy_if_changed "$bucket" "$policy" "$updated"
}

require_env PROJECT_ID PROJECT_NUMBER REGION BQ_LOCATION AR_REPO PROD_DATASET DBT_DOCS_BUCKET CI_SA_ID PROD_SA_ID SCHEDULER_SA_ID

PROD_PROJECT_ID="${PROD_PROJECT_ID:-$PROJECT_ID}"
PROD_PROJECT_NUMBER="$PROJECT_NUMBER"
if [[ "$PROD_PROJECT_ID" != "$PROJECT_ID" ]]; then
  # Cloud Run attaches the prod runtime SA from the identity project.
  if ! gcloud resource-manager org-policies describe iam.disableCrossProjectServiceAccountUsage \
      --project "$PROJECT_ID" --effective --format=json |
    jq -e '.booleanPolicy | type == "object" and ((.enforced // false) == false)' >/dev/null; then
    echo "[error] Cross-project Cloud Run requires iam.disableCrossProjectServiceAccountUsage to be unenforced in $PROJECT_ID." >&2
    echo "        Ask the organization administrator to confirm the effective policy and your read access." >&2
    exit 1
  fi
  PROD_PROJECT_NUMBER=$(gcloud projects describe "$PROD_PROJECT_ID" --project "$PROD_PROJECT_ID" --format='value(projectNumber)')
  if [[ ! "$PROD_PROJECT_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "[error] Could not resolve the project number for $PROD_PROJECT_ID." >&2
    exit 1
  fi
fi

CI_SA_EMAIL="${CI_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
PROD_SA_EMAIL="${PROD_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
SCHED_SA_EMAIL="${SCHEDULER_SA_ID}@${PROD_PROJECT_ID}.iam.gserviceaccount.com"

if [[ "$CI_SA_EMAIL" == "$PROD_SA_EMAIL" ]]; then
  echo "[error] CI_SA_ID and PROD_SA_ID must name different service accounts" >&2
  exit 1
fi

info "Enabling required APIs"
for api in run artifactregistry bigquery iam iamcredentials sts logging monitoring bigquerystorage; do
  ensure_api "$api.googleapis.com" "$PROJECT_ID"
done
if [[ "$PROD_PROJECT_ID" != "$PROJECT_ID" ]]; then
  for api in run artifactregistry bigquery bigquerystorage iam iamcredentials logging; do
    ensure_api "$api.googleapis.com" "$PROD_PROJECT_ID"
  done
fi
ensure_api cloudscheduler.googleapis.com "$PROD_PROJECT_ID"

info "Ensuring service accounts"
ensure_sa "$CI_SA_ID" "dbt CI SA" "$PROJECT_ID"
ensure_sa "$PROD_SA_ID" "dbt Prod SA" "$PROJECT_ID"
ensure_sa "$SCHEDULER_SA_ID" "Scheduler Invoker SA" "$PROD_PROJECT_ID"
if [[ -n "${DOCS_VIEWER_SA_ID:-}" ]]; then
  ensure_sa "$DOCS_VIEWER_SA_ID" "Docs Viewer SA" "$PROJECT_ID"
fi

info "Ensuring Artifact Registry repo"
ensure_ar_repo "$PROD_PROJECT_ID"
if [[ "$PROD_PROJECT_ID" != "$PROJECT_ID" && -n "${DOCS_VIEWER_SA_ID:-}" ]]; then
  ensure_ar_repo "$PROJECT_ID"
fi

info "Ensuring docs bucket"
ensure_bucket

# Determine which bucket CI will actually use for artifacts (explicit override or fallback to docs bucket)
ARTIFACTS_BUCKET_EFFECTIVE="${DBT_ARTIFACTS_BUCKET:-${DBT_DOCS_BUCKET}}"
info "Artifacts bucket (effective): ${ARTIFACTS_BUCKET_EFFECTIVE}"

info "Ensuring BigQuery datasets"
ensure_dataset "$PROD_DATASET" "dbt prod dataset" "$PROD_PROJECT_ID"
if [[ -n "${INT_DATASET:-}" ]]; then
  ensure_dataset "$INT_DATASET" "dbt integration dataset" "$PROJECT_ID"
else
  info "INT_DATASET not set; skipping integration dataset creation"
fi

info "Ensuring project-level IAM"
ensure_project_binding roles/bigquery.jobUser "serviceAccount:${CI_SA_EMAIL}" "$PROJECT_ID"
ensure_project_binding roles/bigquery.jobUser "serviceAccount:${PROD_SA_EMAIL}" "$PROD_PROJECT_ID"
# Allow CI to create datasets for ephemeral PR runs
ensure_project_binding roles/bigquery.user "serviceAccount:${CI_SA_EMAIL}" "$PROJECT_ID"
# The release workflow publishes images with the production service account.
ensure_project_binding roles/artifactregistry.writer "serviceAccount:${PROD_SA_EMAIL}" "$PROD_PROJECT_ID"
ensure_project_binding roles/logging.logWriter "serviceAccount:${PROD_SA_EMAIL}" "$PROD_PROJECT_ID"

# Allow the PROD SA (used by GitHub Actions) to manage Cloud Run Jobs and Cloud Scheduler jobs
ensure_project_binding roles/run.developer "serviceAccount:${PROD_SA_EMAIL}" "$PROD_PROJECT_ID"
# Cloud Scheduler has only admin/viewer predefined roles; admin needed to create/update jobs
ensure_project_binding roles/cloudscheduler.admin "serviceAccount:${PROD_SA_EMAIL}" "$PROD_PROJECT_ID"

# Permit the deployer identity to set the runtime service account when deploying the job
# (required by Cloud Run to use --service-account). Here we allow the PROD SA to act as itself.
ensure_sa_binding "$PROD_SA_EMAIL" roles/iam.serviceAccountUser "serviceAccount:${PROD_SA_EMAIL}" "$PROJECT_ID"
if [[ "$PROD_PROJECT_ID" != "$PROJECT_ID" ]]; then
  gcloud beta services identity create --service=run.googleapis.com --project "$PROD_PROJECT_ID" --quiet >/dev/null
  RUN_AGENT="service-${PROD_PROJECT_NUMBER}@serverless-robot-prod.iam.gserviceaccount.com"
  ensure_project_binding roles/run.serviceAgent "serviceAccount:${RUN_AGENT}" "$PROD_PROJECT_ID"
  ensure_sa_binding "$PROD_SA_EMAIL" roles/iam.serviceAccountTokenCreator "serviceAccount:${RUN_AGENT}" "$PROJECT_ID"
fi

# Optionally allow the human operator to set the runtime service account during deploys
# Determine operator principal from either OPERATOR_EMAIL or active gcloud account
if [[ "${OPERATOR_GRANT_ACTAS:-true}" == "true" ]]; then
  operator_email="${OPERATOR_EMAIL:-}"
  if [[ -z "$operator_email" ]]; then
    operator_email=$(gcloud auth list --format='value(account)' --filter='status:ACTIVE' 2>/dev/null || true)
  fi
  if [[ -n "$operator_email" ]]; then
    if [[ "$operator_email" == *"gserviceaccount.com"* ]]; then
      operator_member="serviceAccount:${operator_email}"
    else
      operator_member="user:${operator_email}"
    fi
    ensure_sa_binding "$PROD_SA_EMAIL" roles/iam.serviceAccountUser "$operator_member" "$PROJECT_ID"
  else
    info "No operator email resolved; skipping operator actAs grant"
  fi
fi

# Allow Cloud Scheduler service agent to mint tokens for the Scheduler SA when invoking the job
SCHED_AGENT="service-${PROD_PROJECT_NUMBER}@gcp-sa-cloudscheduler.iam.gserviceaccount.com"
ensure_sa_binding "$SCHED_SA_EMAIL" roles/iam.serviceAccountTokenCreator "serviceAccount:${SCHED_AGENT}" "$PROD_PROJECT_ID"

# Allow the deployer (PROD SA) to configure Scheduler with --oauth-service-account-email
# This requires iam.serviceAccounts.actAs on the Scheduler SA
ensure_sa_binding "$SCHED_SA_EMAIL" roles/iam.serviceAccountUser "serviceAccount:${PROD_SA_EMAIL}" "$PROD_PROJECT_ID"

# Optional: grant BigQuery Job User to a developer Google Group for per-dev work
if [[ -n "${DEV_GROUP_EMAIL:-}" ]]; then
  info "Ensuring project-level IAM for dev group: roles/bigquery.jobUser -> group:${DEV_GROUP_EMAIL}"
  ensure_project_binding roles/bigquery.jobUser "group:${DEV_GROUP_EMAIL}" "$PROJECT_ID"
fi

# Additional project-level roles for dbt users (service accounts, devs, operator)
add_project_binding_soft(){
  local role="$1" member="$2" project="${3:-$PROJECT_ID}" out
  # Use if/then to prevent set -e from aborting on non-zero
  if out=$(gcloud projects add-iam-policy-binding "$project" --member="$member" --role="$role" --condition=None --quiet 2>&1); then
    info "Ensured $role -> $member"
  else
    warn "Could not add $role to $member (project $project)"
    if [[ "${DEBUG:-0}" == "1" ]]; then
      echo "[debug] gcloud error: ${out}" >&2
    fi
  fi
}

# Common BigQuery project roles for dbt runs
DBT_USER_ROLES=(
  roles/bigquery.user
  roles/bigquery.readSessionUser
  roles/bigquery.jobUser
  roles/bigquery.dataViewer
)

# CI runs in PROJECT_ID; the prod runner's BigQuery jobs and data live in PROD_PROJECT_ID,
# so every project role below goes to the project where that identity does its work.
info "Ensuring project-level roles for dbt service accounts"
for role in "${DBT_USER_ROLES[@]}"; do
  add_project_binding_soft "$role" "serviceAccount:${CI_SA_EMAIL}"
  add_project_binding_soft "$role" "serviceAccount:${PROD_SA_EMAIL}" "$PROD_PROJECT_ID"
done

if [[ "${PROD_READ_ONLY:-true}" == "false" ]]; then
  add_project_binding_soft roles/bigquery.dataEditor "serviceAccount:${CI_SA_EMAIL}"
  add_project_binding_soft roles/bigquery.dataEditor "serviceAccount:${PROD_SA_EMAIL}" "$PROD_PROJECT_ID"
fi

if [[ "${ENABLE_EXTRA_PROJECT_ROLES:-false}" == "true" && -n "${EXTRA_PROJECT_ROLES:-}" ]]; then
  read -r -a extra_roles <<< "$EXTRA_PROJECT_ROLES"
  for role in "${extra_roles[@]}"; do
    add_project_binding_soft "$role" "serviceAccount:${CI_SA_EMAIL}"
    add_project_binding_soft "$role" "serviceAccount:${PROD_SA_EMAIL}" "$PROD_PROJECT_ID"
  done
fi

# Operator (human) principal
operator_email_resolved="${OPERATOR_EMAIL:-}"
if [[ -z "$operator_email_resolved" ]]; then
  operator_email_resolved=$(gcloud auth list --format='value(account)' --filter='status:ACTIVE' 2>/dev/null || true)
fi
if [[ -n "$operator_email_resolved" ]]; then
  if [[ "$operator_email_resolved" == *"gserviceaccount.com"* ]]; then
    operator_member="serviceAccount:${operator_email_resolved}"
  else
    operator_member="user:${operator_email_resolved}"
  fi
  info "Ensuring project-level roles for operator: ${operator_member}"
  for role in "${DBT_USER_ROLES[@]}"; do
    add_project_binding_soft "$role" "$operator_member"
  done
else
  info "No operator principal resolved; skipping operator project role grants (set OPERATOR_EMAIL to force)"
fi

# Devs: group and/or per-email from devs.txt
if [[ -n "${DEV_GROUP_EMAIL:-}" ]]; then
  info "Ensuring project-level roles for dev group: group:${DEV_GROUP_EMAIL}"
  for role in "${DBT_USER_ROLES[@]}"; do
    add_project_binding_soft "$role" "group:${DEV_GROUP_EMAIL}"
  done
else
  info "No DEV_GROUP_EMAIL set; skipping dev-group project role grants"
fi

DEVS_FILE="./devs.txt"
if [[ -f "$DEVS_FILE" ]]; then
  info "Ensuring project-level roles for devs listed in ${DEVS_FILE}"
  while IFS= read -r line; do
    line_trimmed="${line%%#*}"
    line_trimmed="${line_trimmed%%*$'\r'}"
    line_trimmed="$(echo "$line_trimmed" | awk '{$1=$1;print}')"
    [[ -z "$line_trimmed" ]] && continue
    email="${line_trimmed%%,*}"
    [[ -z "$email" ]] && continue
    member="user:${email}"
    for role in "${DBT_USER_ROLES[@]}"; do
      add_project_binding_soft "$role" "$member"
    done
  done < "$DEVS_FILE"
else
  info "No devs.txt found; skipping per-dev project role grants"
fi

info "Ensuring dataset-level IAM"
if [[ "${MANAGE_DATASET_IAM:-true}" == "true" ]]; then
if [[ -n "${INT_DATASET:-}" ]]; then
  # CI should be able to write; others query-only
  add_dataset_acl_entry "${PROJECT_ID}:${INT_DATASET}" READER "${CI_SA_EMAIL}"
  if [[ "${INT_HARDEN_ACL:-true}" == "true" ]]; then
    harden_dataset_acl_writer_only "$INT_DATASET" "$CI_SA_EMAIL" "$PROJECT_ID"
  else
    info "INT_HARDEN_ACL=false; skipping ACL harden on ${INT_DATASET}"
  fi
else
  info "INT_DATASET not set; skipping integration dataset IAM"
fi
add_dataset_acl_entry "${PROD_PROJECT_ID}:${PROD_DATASET}" READER "${CI_SA_EMAIL}"
if [[ "${PROD_HARDEN_ACL:-true}" == "true" ]]; then
  harden_dataset_acl_writer_only "$PROD_DATASET" "$PROD_SA_EMAIL" "$PROD_PROJECT_ID"
else
  info "PROD_HARDEN_ACL=false; skipping ACL harden on ${PROD_DATASET}"
fi
  info "Dataset IAM step finished"
else
  info "MANAGE_DATASET_IAM=false; skipping dataset IAM bindings"
fi

if [[ "${ARTIFACTS_BUCKET_EFFECTIVE}" != "${DBT_DOCS_BUCKET}" ]]; then
  info "Ensuring artifacts bucket exists (${ARTIFACTS_BUCKET_EFFECTIVE})"
  ensure_bucket_named "${ARTIFACTS_BUCKET_EFFECTIVE}"
fi

if ! gcloud storage buckets describe "gs://${ARTIFACTS_BUCKET_EFFECTIVE}" --project "$PROJECT_ID" --format=json |
     jq -e '.uniform_bucket_level_access == true' >/dev/null; then
  echo "[error] Could not confirm uniform bucket-level access on gs://${ARTIFACTS_BUCKET_EFFECTIVE}." >&2
  echo "        IAM Conditions require it. Review existing object ACLs before enabling it and rerunning bootstrap." >&2
  exit 1
fi

ensure_bucket_binding "$DBT_DOCS_BUCKET" roles/storage.objectAdmin "serviceAccount:${PROD_SA_EMAIL}"
if [[ "$ARTIFACTS_BUCKET_EFFECTIVE" != "$DBT_DOCS_BUCKET" ]]; then
  ensure_bucket_binding "$ARTIFACTS_BUCKET_EFFECTIVE" roles/storage.objectAdmin "serviceAccount:${PROD_SA_EMAIL}"
fi

# Object listing is a bucket operation. The writer condition applies to objects only.
ci_object_prefix="projects/_/buckets/${ARTIFACTS_BUCKET_EFFECTIVE}/objects/ci/"
ci_artifact_condition=$(jq -nc \
  --arg expression "resource.type == 'storage.googleapis.com/Object' && resource.name.startsWith('$ci_object_prefix')" \
  '{title:"dbt-ci-artifacts", expression:$expression}')
ensure_bucket_binding "$ARTIFACTS_BUCKET_EFFECTIVE" roles/storage.objectViewer "serviceAccount:${CI_SA_EMAIL}"
ensure_bucket_binding "$ARTIFACTS_BUCKET_EFFECTIVE" roles/storage.objectUser "serviceAccount:${CI_SA_EMAIL}" "$ci_artifact_condition"

ci_policy="${TMP_DIR}/ci_bucket_policy.json"
read_bucket_policy "$ARTIFACTS_BUCKET_EFFECTIVE" "$ci_policy"
if ! jq -e --arg ci "serviceAccount:${CI_SA_EMAIL}" --argjson scope "$ci_artifact_condition" '
  def granted($role; $condition):
    any(.bindings[]?; .role == $role and .condition == $condition and (.members | index($ci)));
  granted("roles/storage.objectViewer"; null) and granted("roles/storage.objectUser"; $scope)
' "$ci_policy" >/dev/null; then
  echo "[error] CI read/list and ci/ write bindings could not be verified on gs://${ARTIFACTS_BUCKET_EFFECTIVE}." >&2
  exit 1
fi
info "Verified CI read/list and ci/ write bindings on gs://${ARTIFACTS_BUCKET_EFFECTIVE}"

remove_legacy_ci_bucket_writer "$ARTIFACTS_BUCKET_EFFECTIVE" "$ci_policy"
if [[ "$ARTIFACTS_BUCKET_EFFECTIVE" != "$DBT_DOCS_BUCKET" ]]; then
  read_bucket_policy "$DBT_DOCS_BUCKET" "$ci_policy"
  remove_legacy_ci_bucket_writer "$DBT_DOCS_BUCKET" "$ci_policy"
fi

# Allow docs viewer SA to read docs (if defined)
if [[ -n "${DOCS_VIEWER_SA_ID:-}" ]]; then
  viewer_email="${DOCS_VIEWER_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
  ensure_bucket_binding "${DBT_DOCS_BUCKET}" "roles/storage.objectViewer" "serviceAccount:${viewer_email}"
fi

info "Bootstrap complete."
