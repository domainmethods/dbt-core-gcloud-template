#!/usr/bin/env bash
set -euo pipefail

# Create the Secret Manager secrets named in PROD_SECRETS and let the prod service
# account read each one (#32). Values are never passed here: add them yourself, so
# they stay out of .env and shell history. release.yml and 30-deploy-cloud-run-job.sh
# mount them into the job with --set-secrets.

cd "$(dirname "$0")"
source ./.env
source ../scripts/prod_secrets.sh

info(){ echo "[info] $*"; }
warn(){ echo "[warn] $*"; }

PROD_SECRETS=${PROD_SECRETS:-}
if [[ -z "$PROD_SECRETS" ]]; then
  info "PROD_SECRETS is empty; no secrets to set up."
  exit 0
fi

# Validate every entry before changing anything.
NAMES=$(prod_secret_names "$PROD_SECRETS") || exit 2

PROJECT_ID=${PROJECT_ID:?}
PROD_SA_ID=${PROD_SA_ID:?}
PROD_SA_MEMBER="serviceAccount:${PROD_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

info "Ensuring API enabled: secretmanager.googleapis.com"
gcloud services enable secretmanager.googleapis.com --project "$PROJECT_ID" >/dev/null

while IFS= read -r name; do
  if gcloud secrets describe "$name" --project "$PROJECT_ID" >/dev/null 2>&1; then
    info "Secret exists: $name"
  else
    info "Creating secret: $name"
    gcloud secrets create "$name" --replication-policy=automatic --project "$PROJECT_ID" >/dev/null
  fi

  # Granted per secret, not project-wide, so the job reads only what it mounts.
  if gcloud secrets get-iam-policy "$name" --format=json --project "$PROJECT_ID" \
      | jq -e --arg m "$PROD_SA_MEMBER" '.bindings[]? | select(.role=="roles/secretmanager.secretAccessor") | .members[]? | select(.==$m)' >/dev/null 2>&1; then
    info "Prod SA already reads: $name"
  else
    info "Granting roles/secretmanager.secretAccessor on $name to ${PROD_SA_MEMBER}"
    gcloud secrets add-iam-policy-binding "$name" --member="$PROD_SA_MEMBER" \
      --role=roles/secretmanager.secretAccessor --project "$PROJECT_ID" >/dev/null
  fi

  if [[ -z "$(gcloud secrets versions list "$name" --filter="state=ENABLED" --limit=1 --format="value(name)" --project "$PROJECT_ID")" ]]; then
    warn "Secret $name has no value yet. The job will fail to start until it has one:"
    warn "  printf '%s' \"\$VALUE\" | gcloud secrets versions add $name --data-file=- --project $PROJECT_ID"
  fi
done <<<"$NAMES"

info "Secrets ready. Mounted at the next release or 30-deploy-cloud-run-job.sh run."
