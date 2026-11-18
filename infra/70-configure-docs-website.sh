#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

DOCS_BUCKET="${DBT_DOCS_BUCKET:?Set DBT_DOCS_BUCKET in infra/.env}"
PUBLIC=${PUBLIC:-false}

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
  if gcloud storage buckets add-iam-policy-binding "gs://${DOCS_BUCKET}" \
    --member=allUsers \
    --role=roles/storage.objectViewer \
    --condition=None \
    --project "${PROJECT_ID}" --quiet; then
    echo
    echo "Public URL: https://storage.googleapis.com/${DOCS_BUCKET}/index.html"
  else
    echo "[warn] Failed to grant public read access to gs://${DOCS_BUCKET}" >&2
    echo "       The bucket website is configured but remains private." >&2
    echo "       You can manually grant public access via:" >&2
    echo "       gcloud storage buckets add-iam-policy-binding gs://${DOCS_BUCKET} --member=allUsers --role=roles/storage.objectViewer --condition=None --project ${PROJECT_ID}" >&2
  fi
else
  echo "Bucket remains private. To access docs, either:"
  echo " - Open index.html via Cloud Console (Storage > Buckets > ${DOCS_BUCKET} > index.html)"
  echo " - Or serve privately via Cloud Run/Load Balancer (recommended for internal access)."
fi

echo "Done."
