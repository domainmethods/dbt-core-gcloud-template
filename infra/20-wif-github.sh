#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

POOL_ID="${POOL_ID:-github-pool}"
PROVIDER_ID="${PROVIDER_ID:-github-provider}"
ISSUER_URI="https://token.actions.githubusercontent.com"

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
require_env PROJECT_ID PROJECT_NUMBER GITHUB_REPO CI_SA_ID PROD_SA_ID

die() { echo "[error] $*" >&2; exit 1; }
[[ "$CI_SA_ID" != "$PROD_SA_ID" ]] || die "CI and production must use different service accounts."
[[ "$GITHUB_REPO" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || die "Set GITHUB_REPO to owner/repo."

repo=$(gh api "repos/${GITHUB_REPO}")
[[ "$(jq -er '.full_name' <<< "$repo")" == "$GITHUB_REPO" ]] || die "Use the canonical name for GITHUB_REPO."
repo_id=$(jq -er '.id | tostring | select(test("^[1-9][0-9]*$"))' <<< "$repo")

environment_path="repos/${GITHUB_REPO}/environments/production"
environment=$(gh api "$environment_path") || die "Configure the GitHub production environment before enabling federation."
if jq -e '.deployment_branch_policy.protected_branches == true' <<< "$environment" >/dev/null; then
  main_protected=$(gh api "repos/${GITHUB_REPO}/branches/main" --jq '.protected')
  [[ "$main_protected" == true ]] || die "The production environment requires main to be a protected branch."
elif jq -e '.deployment_branch_policy.custom_branch_policies == true' <<< "$environment" >/dev/null; then
  branches=$(gh api --paginate "$environment_path/deployment-branch-policies" --jq '.branch_policies[] | [.type,.name] | @tsv')
  [[ "$branches" == $'branch\tmain' ]] || die "The production environment must allow only the main branch in its custom policy."
else
  die "The production environment needs deployment branch protection."
fi

project_number=$(gcloud projects describe "$PROJECT_ID" --project "$PROJECT_ID" --format='value(projectNumber)')
[[ "$project_number" =~ ^[1-9][0-9]*$ && "$project_number" == "$PROJECT_NUMBER" ]] || die "PROJECT_NUMBER does not match PROJECT_ID."

WIF_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}"
PROVIDER_RESOURCE="${WIF_RESOURCE}/providers/${PROVIDER_ID}"
CI_SA_EMAIL="${CI_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
PROD_SA_EMAIL="${PROD_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
repo_member="principalSet://iam.googleapis.com/${WIF_RESOURCE}/attribute.repository/${GITHUB_REPO}"
release_member="principalSet://iam.googleapis.com/${WIF_RESOURCE}/attribute.production_release/${repo_id}"

ci_policy=$(gcloud iam service-accounts get-iam-policy "$CI_SA_EMAIL" --project "$PROJECT_ID" --format=json)
ci_bound=$(jq -er --arg member "$repo_member" 'any(.bindings[]?;
  .role == "roles/iam.workloadIdentityUser" and .condition == null and any(.members[]?; . == $member)
) | tostring' <<< "$ci_policy")
prod_policy=$(gcloud iam service-accounts get-iam-policy "$PROD_SA_EMAIL" --project "$PROJECT_ID" --format=json | jq -ce '
  if (.etag | type == "string" and length > 0) then . else error("Production IAM policy needs an etag") end
')
prod_next=$(jq -c --arg legacy "$repo_member" --arg release "$release_member" '
  def wif: .role == "roles/iam.workloadIdentityUser";
  .bindings |= ((. // []) | map(if wif then .members -= [$legacy] else . end))
  | if any(.bindings[]; wif and .condition == null) then
      (.bindings[] | select(wif and .condition == null) | .members) |=
        (if index($release) == null then . + [$release] else . end)
    else .bindings += [{"role":"roles/iam.workloadIdentityUser","members":[$release]}] end
  | .bindings |= map(select(.members != []))
' <<< "$prod_policy")

echo "== Ensure Workload Identity Pool =="
provider_count=0
if pool=$(gcloud iam workload-identity-pools describe "$POOL_ID" --location=global --project "$PROJECT_ID" --format=json 2>/dev/null); then
  jq -e '.state == "ACTIVE" and .disabled != true' <<< "$pool" >/dev/null || die "The GitHub WIF pool must be active."
  providers=$(gcloud iam workload-identity-pools providers list \
    --workload-identity-pool="$POOL_ID" --location=global --project "$PROJECT_ID" --format=json)
  # IAM principal sets span the pool, so only the template's GitHub provider may map its attributes.
  jq -e --arg name "$PROVIDER_RESOURCE" --arg issuer "$ISSUER_URI" '
    type == "array" and all(.[]; .name == $name and .oidc.issuerUri == $issuer and .state == "ACTIVE" and .disabled != true)
  ' <<< "$providers" >/dev/null || die "The GitHub WIF pool has an unexpected provider or the GitHub provider is disabled."
  provider_count=$(jq -r 'length' <<< "$providers")
else
  gcloud iam workload-identity-pools create "$POOL_ID" \
    --project "$PROJECT_ID" --location=global --display-name="GitHub Actions pool"
fi

echo "== Ensure OIDC provider for GitHub with release scoping =="
repo_claims="assertion.repository=='${GITHUB_REPO}' && assertion.repository_id=='${repo_id}'"
release_claims="${repo_claims} && assertion.ref=='refs/heads/main' && assertion.workflow_ref=='${GITHUB_REPO}/.github/workflows/release.yml@refs/heads/main' && assertion.event_name=='push' && has(assertion.environment) && assertion.environment=='production'"
mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.aud=assertion.aud,attribute.repository=assertion.repository,attribute.repository_id=assertion.repository_id,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref,attribute.workflow_ref=assertion.workflow_ref"
provider_flags=(
  --project "$PROJECT_ID" --location=global --workload-identity-pool="$POOL_ID"
  --attribute-condition="$repo_claims"
  --attribute-mapping="${mapping},attribute.production_release=(${release_claims}) ? assertion.repository_id : 'none'"
)
if [[ "$provider_count" == 0 ]]; then
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" "${provider_flags[@]}" \
    --display-name="GitHub OIDC provider" --issuer-uri="$ISSUER_URI"
else
  gcloud iam workload-identity-pools providers update-oidc "$PROVIDER_ID" "${provider_flags[@]}" >/dev/null
fi

if [[ "$ci_bound" == false ]]; then
  gcloud iam service-accounts add-iam-policy-binding "$CI_SA_EMAIL" \
    --project "$PROJECT_ID" --role=roles/iam.workloadIdentityUser --member="$repo_member" --condition=None
fi
if [[ "$prod_policy" != "$prod_next" ]]; then
  policy_file=$(mktemp)
  trap 'rm -f "$policy_file"' EXIT
  printf '%s\n' "$prod_next" > "$policy_file"
  # Replace the old production member in one write, using the etag to preserve concurrent edits.
  gcloud iam service-accounts set-iam-policy "$PROD_SA_EMAIL" "$policy_file" --project "$PROJECT_ID" >/dev/null
fi

echo "== Output values for GitHub workflows =="
echo "workload_identity_provider=${PROVIDER_RESOURCE}"
echo "service_account=${CI_SA_EMAIL}"

echo "WIF configured."
