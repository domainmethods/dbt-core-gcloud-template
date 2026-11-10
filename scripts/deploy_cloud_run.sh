#!/usr/bin/env bash
set -euo pipefail

# Env vars:
#   JOB           default dbt-prod
#   REGION        default us-central1
#   SCHED         default dbt-prod-schedule
#   SCHED_REGION  default us-central1
#   IMAGE_URI     required
#   PROJECT       required
#   INVOKER_SA    required (Scheduler invoker SA email)

JOB=${JOB:-dbt-prod}
REGION=${REGION:-us-central1}
SCHED=${SCHED:-dbt-prod-schedule}
SCHED_REGION=${SCHED_REGION:-us-central1}
IMAGE_URI=${IMAGE_URI:?required}
PROJECT=${PROJECT:?required}
INVOKER_SA=${INVOKER_SA:?required}

if ! gcloud run jobs describe "$JOB" --region "$REGION" >/dev/null 2>&1; then
  gcloud run jobs create "$JOB" \
    --image "$IMAGE_URI" \
    --set-env-vars=DBT_TARGET=prod,CI=true,DBT_GCP_PROJECT_PROD=$PROJECT,DBT_BQ_DATASET_PROD=analytics,DBT_BQ_LOCATION=US \
    --region "$REGION" --memory=2Gi --cpu=1 --max-retries=0
fi

gcloud run jobs update "$JOB" \
  --image "$IMAGE_URI" \
  --set-env-vars=DBT_TARGET=prod,CI=true,DBT_GCP_PROJECT_PROD=$PROJECT,DBT_BQ_DATASET_PROD=analytics,DBT_BQ_LOCATION=US \
  --region "$REGION"

EXEC_URI="https://run.googleapis.com/v2/projects/${PROJECT}/locations/${REGION}/jobs/${JOB}:run"

if ! gcloud scheduler jobs describe "$SCHED" --location "$SCHED_REGION" >/dev/null 2>&1; then
  gcloud scheduler jobs create http "$SCHED" \
    --location "$SCHED_REGION" \
    --schedule "0 2 * * *" \
    --uri "$EXEC_URI" \
    --http-method POST \
    --oauth-service-account-email "$INVOKER_SA"
else
  gcloud scheduler jobs update http "$SCHED" \
    --location "$SCHED_REGION" \
    --schedule "0 2 * * *" \
    --uri "$EXEC_URI" \
    --http-method POST \
    --oauth-service-account-email "$INVOKER_SA"
fi

echo "Deployed job $JOB and schedule $SCHED"

