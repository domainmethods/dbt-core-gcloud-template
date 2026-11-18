#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
PUBLIC_OVERRIDE="${PUBLIC-}"
source ./.env

DOCS_BUCKET="${DBT_DOCS_BUCKET:?Set DBT_DOCS_BUCKET in infra/.env}"
ARTIFACTS_BUCKET="${DBT_ARTIFACTS_BUCKET:-${DOCS_BUCKET}}"
PUBLIC="${PUBLIC_OVERRIDE:-${PUBLIC:-false}}"

if [[ "$PUBLIC" != true && "$PUBLIC" != false ]]; then
  echo "[error] PUBLIC must be true or false." >&2
  exit 1
fi

if [[ "$PUBLIC" == true && "$DOCS_BUCKET" == "$ARTIFACTS_BUCKET" ]]; then
  echo "[error] Public access requires a docs-only bucket. Set DBT_DOCS_BUCKET and DBT_ARTIFACTS_BUCKET to different buckets in infra/.env." >&2
  exit 1
fi

echo "Configuring website settings on gs://${DOCS_BUCKET} (index.html)"
if ! gcloud storage buckets update "gs://${DOCS_BUCKET}" \
  --web-main-page-suffix=index.html \
  --project "${PROJECT_ID}"; then
  echo "[error] Failed to configure website settings on gs://${DOCS_BUCKET}" >&2
  echo "        Ensure you have storage.buckets.update permission on this bucket." >&2
  exit 1
fi

if [[ "${PUBLIC}" == "true" ]]; then
  echo "Granting public read (roles/storage.objectViewer) to allUsers"
  gcloud storage buckets add-iam-policy-binding "gs://${DOCS_BUCKET}" \
    --member=allUsers \
    --role=roles/storage.objectViewer \
    --condition=None --project "${PROJECT_ID}" --quiet
  echo "Public URL: https://storage.googleapis.com/${DOCS_BUCKET}/index.html"
else
  get_bucket_policy() {
    gcloud storage buckets get-iam-policy "gs://${DOCS_BUCKET}" --project "${PROJECT_ID}" --format=json
  }

  policy=$(get_bucket_policy)
  managed_grant=$(jq -er 'any(.bindings[]?;
    .role == "roles/storage.objectViewer" and .condition == null and any(.members[]?; . == "allUsers")
  ) | tostring' <<< "$policy")
  if [[ "$managed_grant" == true ]]; then
    gcloud storage buckets remove-iam-policy-binding "gs://${DOCS_BUCKET}" \
      --member=allUsers --role=roles/storage.objectViewer --condition=None \
      --project "${PROJECT_ID}" --quiet
    policy=$(get_bucket_policy)
  fi

  public_grants=$(jq -er 'any(.bindings[]?.members[]?;
    . == "allUsers" or . == "allAuthenticatedUsers"
  ) | tostring' <<< "$policy")
  if [[ "$public_grants" == true ]]; then
    echo "[error] Public grants remain in bucket IAM on gs://${DOCS_BUCKET}. Review them before relying on private access." >&2
    exit 1
  fi
  echo "Bucket IAM has no public grants on gs://${DOCS_BUCKET}."
fi

echo "Done."
