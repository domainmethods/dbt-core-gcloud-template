#!/usr/bin/env bash
set -euo pipefail

job="${1:?Cloud Run job required}"
project="${2:?Cloud Run project required}"
region="${3:?Cloud Run region required}"
member="serviceAccount:${4:?Scheduler service account email required}"
location=(--project "$project" --region "$region")

read_invoker_binding() {
  gcloud run jobs get-iam-policy "$job" "${location[@]}" --format=json |
    jq -r --arg member "$member" '
      any(.bindings[]?; .role == "roles/run.invoker" and .condition == null and any(.members[]?; . == $member))
    '
}

invoker=$(read_invoker_binding)
if [[ "$invoker" != true ]]; then
  gcloud run jobs add-iam-policy-binding "$job" "${location[@]}" \
    --member "$member" --role roles/run.invoker --quiet >/dev/null
  invoker=$(read_invoker_binding)
  if [[ "$invoker" != true ]]; then
    echo "[error] Could not verify roles/run.invoker on $job for $member." >&2
    exit 1
  fi
fi
