#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

require_env(){
  local v
  for v in "$@"; do
    if [[ -z "${!v:-}" ]] ; then
      echo "Missing env: $v"
      exit 1
    fi
  done
  return 0
}
require_env PROJECT_ID REGION AR_REPO DBT_DOCS_BUCKET DOCS_VIEWER_SERVICE DOCS_VIEWER_SA_ID

SERVICE="$DOCS_VIEWER_SERVICE"
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE}:${IMAGE_TAG:-latest}"
VIEWER_SA_EMAIL="${DOCS_VIEWER_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Building and pushing image: ${IMAGE_URI}"
cd ..
APP_DIR="${DOCS_VIEWER_DIR:-./docs-viewer}"
if [[ ! -d "$APP_DIR" ]]; then
  echo "Docs viewer app directory not found: $APP_DIR" >&2
  echo "Set DOCS_VIEWER_DIR to the app path, or place the app in ./docs-viewer" >&2
  exit 1
fi
# Cloud Build when docker is missing or its daemon isn't running, as in
# 30-deploy-cloud-run-job.sh (#28).
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  # Ensure Docker is authenticated for Artifact Registry
  gcloud auth configure-docker "${REGION}-docker.pkg.dev" -q >/dev/null 2>&1 || {
    echo "[warn] Could not configure Docker auth for Artifact Registry" >&2
    echo "       You may need to run: gcloud auth configure-docker ${REGION}-docker.pkg.dev" >&2
  }
  if ! docker build -t "$IMAGE_URI" "$APP_DIR"; then
    echo "[error] Docker build failed for docs viewer" >&2
    exit 1
  fi
  if ! docker push "$IMAGE_URI"; then
    echo "[error] Docker push failed for image: ${IMAGE_URI}" >&2
    echo "        Ensure you have artifactregistry.repositories.uploadArtifacts permission" >&2
    exit 1
  fi
else
  echo "docker not found or its daemon isn't running; using Cloud Build"
  gcloud services enable cloudbuild.googleapis.com --project "$PROJECT_ID" >/dev/null
  if ! CLOUDSDK_GCLOUDIGNORE_ENABLED=true gcloud builds submit \
    --region="$REGION" --tag "$IMAGE_URI" --project "$PROJECT_ID" "$APP_DIR"; then
    echo "[error] Cloud Build failed to build and push image: ${IMAGE_URI}" >&2
    echo "        Check build logs: gcloud builds log --region=${REGION} --project=${PROJECT_ID}" >&2
    exit 1
  fi
fi
cd - >/dev/null

echo "Deploying Cloud Run service: ${SERVICE}"
gcloud run deploy "$SERVICE" \
  --image "$IMAGE_URI" \
  --region "$REGION" \
  --no-allow-unauthenticated \
  --service-account "$VIEWER_SA_EMAIL" \
  --set-env-vars "DBT_DOCS_BUCKET=${DBT_DOCS_BUCKET}" \
  --min-instances=0 \
  --max-instances=2 \
  --project "$PROJECT_ID"

URL=$(gcloud run services describe "$SERVICE" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)')
echo "Service URL: $URL"
echo "Grant access with: ./81-grant-docs-viewer-access.sh <principal>   # e.g., group:[email protected]"
