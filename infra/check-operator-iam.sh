#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID in infra/.env}"
PROJECT_NUMBER="${PROJECT_NUMBER:?Set PROJECT_NUMBER in infra/.env}"
REGION="${REGION:?Set REGION in infra/.env}"

# Hybrid operator IAM check (roles + permission probes)
VERBOSE=0
VERY_VERBOSE=0

usage() {
  echo "Usage: $0 [--verbose] [--very-verbose]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --effective|--bindings|--force-effective)
      echo "[INFO] Deprecated flag '$1' — hybrid mode is default" >&2 ;;
    --verbose)
      VERBOSE=1 ;;
    --very-verbose)
      VERY_VERBOSE=1; VERBOSE=1 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage; exit 2 ;;
  esac
  shift
done

account=$(gcloud auth list --format='value(account)' --filter='status:ACTIVE')
if [[ -z "$account" ]]; then
  echo "No active gcloud account. Run: gcloud auth login" >&2
  exit 2
fi
if [[ "$account" == *"gserviceaccount.com"* ]]; then
  MEMBER="serviceAccount:${account}"
else
  MEMBER="user:${account}"
fi

dbg() { if [[ "$VERBOSE" -eq 1 ]]; then echo "[DBG] $*" >&2; fi; }
vdbg() { if [[ "$VERY_VERBOSE" -eq 1 ]]; then echo "[DBG] $*" >&2; fi; }

ACTIVE_CORE_PROJECT=$(gcloud config get-value core/project 2>/dev/null || true)
if [[ "$VERBOSE" -eq 1 ]]; then
  if [[ -n "$ACTIVE_CORE_PROJECT" && "$ACTIVE_CORE_PROJECT" != "$PROJECT_ID" ]]; then
    echo "[INFO] gcloud core/project is '${ACTIVE_CORE_PROJECT}'; using '${PROJECT_ID}' for Troubleshooter and API checks."
  fi
fi

echo "Checking operator IAM (hybrid) for ${MEMBER} on project ${PROJECT_ID}"

missing=()
unknown=()
OWNER_DIRECT=0
missing_label="Missing capabilities:"

# Detect direct Owner binding once up front
TMP_FAST_POLICY="$(mktemp)"
if gcloud projects get-iam-policy "$PROJECT_ID" --format=json >"$TMP_FAST_POLICY" 2>/dev/null; then
  if jq -e --arg m "$MEMBER" '.bindings[]? | select(.role=="roles/owner") | .members[]? | select(.==$m)' "$TMP_FAST_POLICY" >/dev/null; then
    OWNER_DIRECT=1
  fi
fi

rm -f "$TMP_FAST_POLICY"

PT_ENABLED=0
enabled_via_list=$(gcloud services list --enabled --project "$PROJECT_ID" \
  --filter="config.name=policytroubleshooter.googleapis.com" \
  --format='value(config.name)' 2>/dev/null || true)
if [[ "$enabled_via_list" != "policytroubleshooter.googleapis.com" ]]; then
  echo "[INFO] Policy Troubleshooter API not enabled; hybrid checks will rely on role bindings." >&2
else
  PT_ENABLED=1
fi

  # Hybrid checks
  command -v jq >/dev/null || { echo "jq not found"; exit 2; }

  # Full resource names used by Policy Troubleshooter. These must match the
  # service's resource type that the permission is evaluated against.
  # We'll compute multiple variants for some services and try them in order.
  CRM_PROJECT_REF_NUM="//cloudresourcemanager.googleapis.com/projects/${PROJECT_NUMBER}"
  CRM_PROJECT_REF_ID="//cloudresourcemanager.googleapis.com/projects/${PROJECT_ID}"
  # Artifact Registry: location-scoped resource.
  AR_LOC_REF_ID="//artifactregistry.googleapis.com/projects/${PROJECT_ID}/locations/${REGION}"
  # Cloud Run: location-scoped resource.
  RUN_LOC_REF_ID="//run.googleapis.com/projects/${PROJECT_ID}/locations/${REGION}"
  # Cloud Scheduler: location-scoped resource.
  SCHED_LOC_REF_ID="//cloudscheduler.googleapis.com/projects/${PROJECT_ID}/locations/${REGION}"
  # Workload Identity Pools: global location in IAM.
  IAM_LOC_REF_ID="//iam.googleapis.com/projects/${PROJECT_ID}/locations/global"
  # (BigQuery create, Storage bucket create, SA create all evaluated at CRM project)

  PROJ_POLICY_TMP="$(mktemp)"
  gcloud projects get-iam-policy "$PROJECT_ID" --format=json >"$PROJ_POLICY_TMP"
  checks=(
    "roles/iam.serviceAccountIamAdmin|iam.serviceAccounts.setIamPolicy|Manage service account IAM|"
    "roles/iam.serviceAccountUser|iam.serviceAccounts.actAs|Use service accounts|"
    "roles/serviceusage.serviceUsageAdmin|serviceusage.services.enable|Enable/disable APIs|${CRM_PROJECT_REF_ID},${CRM_PROJECT_REF_NUM}"
    "roles/iam.serviceAccountAdmin|iam.serviceAccounts.create|Create service accounts|${CRM_PROJECT_REF_ID},${CRM_PROJECT_REF_NUM}"
    "roles/iam.workloadIdentityPoolAdmin|iam.workloadIdentityPools.create|Create WIF pools|${IAM_LOC_REF_ID},${CRM_PROJECT_REF_ID},${CRM_PROJECT_REF_NUM}"
    "roles/artifactregistry.admin|artifactregistry.repositories.create|Create Artifact Registry repos|${AR_LOC_REF_ID}"
    "roles/storage.admin|storage.buckets.create|Create GCS buckets|${CRM_PROJECT_REF_ID},${CRM_PROJECT_REF_NUM}"
    "roles/bigquery.admin|bigquery.datasets.create|Create BigQuery datasets|${CRM_PROJECT_REF_ID},${CRM_PROJECT_REF_NUM}"
    "roles/run.admin|run.jobs.create|Create Cloud Run Jobs|${RUN_LOC_REF_ID}"
    "roles/cloudscheduler.admin|cloudscheduler.jobs.create|Create Cloud Scheduler jobs|${SCHED_LOC_REF_ID}"
    "roles/secretmanager.admin|secretmanager.secrets.create|Create Secret Manager secrets (12-secret-manager.sh)|${CRM_PROJECT_REF_ID},${CRM_PROJECT_REF_NUM}"
  )

  LAST_TROUBLESHOOT_JSON=""
  LAST_TROUBLESHOOT_PRINCIPAL=""
  # (resource_type_for/resource_service_for not needed in simplified probe)

  troubleshoot_once() {
    local principal_email="$1" perm="$2" resource="$3"
    local access json rc
    LAST_TROUBLESHOOT_PRINCIPAL="$principal_email"
    vdbg "troubleshoot perm=${perm} resource=${resource} principal-email=${principal_email}"
    json=$(gcloud policy-troubleshoot iam "$resource" \
      --principal-email="$principal_email" \
      --permission="$perm" \
      --project="$PROJECT_ID" \
      --format=json 2>/dev/null)
    rc=$?
    if [[ $rc -ne 0 ]]; then
      vdbg "troubleshoot command failed (rc=$rc)"
      json=""
      access="UNKNOWN"
    else
      access=$(printf '%s' "$json" | jq -r '.access? // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
      [[ -z "$access" ]] && access="UNKNOWN"
    fi
    LAST_TROUBLESHOOT_JSON="$json"
    vdbg "access=${access}"
    LAST_ACCESS_RESULT="$access"
  }

  normalize_access () {
    case "$1" in
      ACCESS_STATE_GRANTED) echo GRANTED ;;
      ACCESS_STATE_NOT_GRANTED) echo NOT_GRANTED ;;
      UNKNOWN_INFO_DENIED) echo UNKNOWN ;;
      ACCESS_STATE_UNKNOWN|UNKNOWN|"") echo UNKNOWN ;;
      *) echo "$1" ;;
    esac
  }

  has_permission() {
    local perm="$1" resource="$2"
    local email="$MEMBER"
    if [[ "$email" == user:* ]]; then email=${email#user:}; fi
    troubleshoot_once "$email" "$perm" "$resource"
    LAST_ACCESS_RESULT=$(normalize_access "$LAST_ACCESS_RESULT")
  }

  total_checks=${#checks[@]}
  ok_count=0
  missing_count=0
  unknown_count=0
  idx=0
  set +e
  for def in "${checks[@]}"; do
    ((++idx))
    IFS='|' read -r need_role perm label variants <<<"$def"
    dbg "(${idx}/${total_checks}) ${label} [${need_role}]"
    IFS=',' read -r -a resources <<<"$variants"
    access="UNKNOWN"
    # Owner fast-path per check
    if (( OWNER_DIRECT == 1 )); then
      printf "[OK] %s (%s) [owner]\n" "$perm" "$label"
      ((ok_count++))
      dbg "Pausing briefly to respect API quota..."; sleep 1
      continue
    fi
    # Direct role binding check
    if jq -e --arg r "$need_role" --arg m "$MEMBER" '.bindings[]? | select(.role==$r) | .members[]? | select(.==$m)' "$PROJ_POLICY_TMP" >/dev/null; then
      printf "[OK] %s (%s) [role]\n" "$perm" "$label"
      ((ok_count++))
      dbg "Pausing briefly to respect API quota..."; sleep 1
      continue
    fi
    # Role-only capability: if no resource variants defined, mark missing when role absent
    if [[ -z "$variants" ]]; then
      printf "[MISSING] %s (%s) [role-required]\n" "$perm" "$label"
      missing+=("perm:$perm")
      ((missing_count++))
      dbg "Pausing briefly to respect API quota..."; sleep 1
      continue
    fi
    # Permission probe via Troubleshooter (if enabled)
    if (( PT_ENABLED == 1 )); then
      for resource in "${resources[@]}"; do
        [[ -z "$resource" ]] && continue
        vdbg "Trying resource variant: ${resource}"
        has_permission "$perm" "$resource"
        access="$LAST_ACCESS_RESULT"
        vdbg "Result: ${access} (principal=${LAST_TROUBLESHOOT_PRINCIPAL})"
        if [[ "$access" == "GRANTED" || "$access" == "NOT_GRANTED" ]]; then
          dbg "Selected resource variant: ${resource} -> ${access}"
          break
        fi
      done
    else
      access="UNKNOWN"
    fi
    if [[ "$access" == "GRANTED" ]]; then
      printf "[OK] %s (%s)\n" "$perm" "$label"
      ((ok_count++))
    elif [[ "$access" == "UNKNOWN" ]]; then
      if (( OWNER_DIRECT == 1 )); then
        dbg "Resolving UNKNOWN via Owner for ${perm}"
        printf "[OK] %s (%s) [owner]\n" "$perm" "$label"
        ((ok_count++))
      else
        if (( PT_ENABLED == 1 )); then
          printf "[WARN] Troubleshooter returned UNKNOWN for %s (%s) — may indicate resource mismatch or cross-project constraints\n" "$perm" "$label"
        else
          printf "[WARN] Unknown for %s (%s) — Policy Troubleshooter API may be disabled\n" "$perm" "$label"
        fi
        unknown+=("perm:$perm")
        ((unknown_count++))
      fi
    else
      printf "[MISSING] %s (%s)\n" "$perm" "$label"
      missing+=("perm:$perm")
      ((missing_count++))
    fi
    # Small delay to avoid hitting Troubleshooter per-minute quotas when many variants are tried
    dbg "Pausing briefly to respect API quota..."; sleep 1
  done
  set -e

  # Optional: check ability to act as SAs, if they already exist
  sa_missing=()
  if [[ -n "${PROD_SA_ID:-}" ]]; then
    PROD_SA_EMAIL="${PROD_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
    if gcloud iam service-accounts describe "$PROD_SA_EMAIL" --project "$PROJECT_ID" >/dev/null 2>&1; then
      SA_REF="//iam.googleapis.com/projects/${PROJECT_NUMBER}/serviceAccounts/${PROD_SA_EMAIL}"
      dbg "Checking SA permissions on ${SA_REF} (prod)"
      # Can the operator act as this SA (deploy Run Job with --service-account)?
      has_permission iam.serviceAccounts.actAs "$SA_REF"; access="$LAST_ACCESS_RESULT"
      dbg "iam.serviceAccounts.actAs -> ${access}"
      if [[ "$access" == "GRANTED" ]]; then
        printf "[OK] iam.serviceAccounts.actAs on %s\n" "$PROD_SA_EMAIL"
      else
        printf "[INFO] You may need roles/iam.serviceAccountUser on %s (or project-level equivalent)\n" "$PROD_SA_EMAIL"
        sa_missing+=("roles/iam.serviceAccountUser@$PROD_SA_EMAIL")
      fi
      # Can the operator set IAM on this SA (needed for WIF bindings, etc.)?
      has_permission iam.serviceAccounts.setIamPolicy "$SA_REF"; access="$LAST_ACCESS_RESULT"
      dbg "iam.serviceAccounts.setIamPolicy -> ${access}"
      if [[ "$access" == "GRANTED" ]]; then
        printf "[OK] iam.serviceAccounts.setIamPolicy on %s\n" "$PROD_SA_EMAIL"
      else
        printf "[INFO] Consider roles/iam.serviceAccountIamAdmin to manage IAM on %s\n" "$PROD_SA_EMAIL"
        sa_missing+=("roles/iam.serviceAccountIamAdmin@$PROD_SA_EMAIL")
      fi
    else
      printf "[INFO] Skipping actAs check; service account not found: %s\n" "$PROD_SA_EMAIL"
    fi
  fi

  if [[ -n "${SCHEDULER_SA_ID:-}" ]]; then
    SCHED_SA_EMAIL="${SCHEDULER_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
    if gcloud iam service-accounts describe "$SCHED_SA_EMAIL" --project "$PROJECT_ID" >/dev/null 2>&1; then
      SA_REF="//iam.googleapis.com/projects/${PROJECT_NUMBER}/serviceAccounts/${SCHED_SA_EMAIL}"
      dbg "Checking SA permissions on ${SA_REF} (scheduler)"
      has_permission iam.serviceAccounts.actAs "$SA_REF"; access="$LAST_ACCESS_RESULT"
      dbg "iam.serviceAccounts.actAs -> ${access}"
      if [[ "$access" == "GRANTED" ]]; then
        printf "[OK] iam.serviceAccounts.actAs on %s\n" "$SCHED_SA_EMAIL"
      else
        printf "[INFO] You may need roles/iam.serviceAccountUser on %s (only if impersonating it)\n" "$SCHED_SA_EMAIL"
        sa_missing+=("roles/iam.serviceAccountUser@$SCHED_SA_EMAIL")
      fi
      has_permission iam.serviceAccounts.setIamPolicy "$SA_REF"; access="$LAST_ACCESS_RESULT"
      dbg "iam.serviceAccounts.setIamPolicy -> ${access}"
      if [[ "$access" == "GRANTED" ]]; then
        printf "[OK] iam.serviceAccounts.setIamPolicy on %s\n" "$SCHED_SA_EMAIL"
      else
        printf "[INFO] Consider roles/iam.serviceAccountIamAdmin to manage IAM on %s\n" "$SCHED_SA_EMAIL"
        sa_missing+=("roles/iam.serviceAccountIamAdmin@$SCHED_SA_EMAIL")
      fi
    else
      printf "[INFO] Skipping actAs check; service account not found: %s\n" "$SCHED_SA_EMAIL"
    fi
  fi

echo
if (( ${#missing[@]} )); then
  echo "${missing_label}" >&2
  printf ' - %s\n' "${missing[@]}" >&2
fi
if [[ "$VERBOSE" -eq 1 ]]; then
  echo "[DBG] Summary: OK=${ok_count} MISSING=${missing_count} UNKNOWN=${unknown_count}"
fi
if (( ${#sa_missing[@]} )); then
  echo "Service account bindings to consider:" >&2
  printf ' - %s\n' "${sa_missing[@]}" >&2
fi

if (( ${#missing[@]} )); then
  exit 1
else
  echo "Operator IAM looks good."
fi
