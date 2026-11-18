#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
# DOCS_PUBLIC is the one-off shell override. PUBLIC comes only from infra/.env:
# setup-env.sh exports it, so a value already in the shell may be stale.
DOCS_PUBLIC_OVERRIDE="${DOCS_PUBLIC-}"
unset PUBLIC
source ./.env

DOCS_BUCKET="${DBT_DOCS_BUCKET:?Set DBT_DOCS_BUCKET in infra/.env}"
ARTIFACTS_BUCKET="${DBT_ARTIFACTS_BUCKET:-${DOCS_BUCKET}}"
PUBLIC="${DOCS_PUBLIC_OVERRIDE:-${PUBLIC:-false}}"

if [[ "$PUBLIC" != true && "$PUBLIC" != false ]]; then
  echo "[error] DOCS_PUBLIC / PUBLIC must be true or false." >&2
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
  echo "        Ensure you have storage.buckets.update permission on this bucket" >&2
  echo "        (and storage.buckets.getIamPolicy/setIamPolicy for the IAM changes below)." >&2
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
    if ! gcloud storage buckets get-iam-policy "gs://${DOCS_BUCKET}" --project "${PROJECT_ID}" --format=json; then
      echo "[error] Failed to read bucket IAM policy on gs://${DOCS_BUCKET} (needs storage.buckets.getIamPolicy)." >&2
      return 1
    fi
  }

  policy=$(get_bucket_policy)
  # -e fails on unparsable input, but it also fails when the result is false;
  # tostring turns false into the string "false" so only a bad policy aborts.
  managed_grant=$(jq -er 'any(.bindings[]?;
    .role == "roles/storage.objectViewer" and .condition == null and any(.members[]?; . == "allUsers")
  ) | tostring' <<< "$policy")
  if [[ "$managed_grant" == true ]]; then
    if ! gcloud storage buckets remove-iam-policy-binding "gs://${DOCS_BUCKET}" \
      --member=allUsers --role=roles/storage.objectViewer --condition=None \
      --project "${PROJECT_ID}" --quiet; then
      echo "[error] Failed to remove the allUsers reader grant on gs://${DOCS_BUCKET} (needs storage.buckets.setIamPolicy)." >&2
      exit 1
    fi
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
