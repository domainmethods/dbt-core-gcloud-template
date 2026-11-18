#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
source ./.env

BUCKET="${DBT_ARTIFACTS_BUCKET:-${DBT_DOCS_BUCKET:-}}"
if [[ -z "$BUCKET" ]]; then
  echo "Set DBT_ARTIFACTS_BUCKET or DBT_DOCS_BUCKET in infra/.env" >&2
  exit 1
fi

metadata=$(gcloud storage buckets describe "gs://${BUCKET}" --raw --format=json --project "$PROJECT_ID")
metageneration=$(jq -er --arg bucket "$BUCKET" '
  select(.name == $bucket) | .metageneration | tostring | select(test("^[1-9][0-9]*$"))
' <<< "$metadata") || { echo "[error] Could not verify metadata for gs://${BUCKET}." >&2; exit 1; }

current_rules=$(jq -ce '.lifecycle.rule // [] | arrays' <<< "$metadata")
updated_rules=$(jq -c '
  {"action":{"type":"Delete"},"condition":{"age":30}} as $legacy
  | ($legacy | .condition.matchesPrefix = ["ci/"]) as $ci
  | map(select(. != $legacy))
  | if index($ci) == null then . + [$ci] else . end
' <<< "$current_rules")
if [[ "$updated_rules" == "$current_rules" ]]; then
  echo "CI artifact expiration is already configured on gs://${BUCKET}."
  exit 0
fi

echo "Applying 30-day expiration for ci/ objects on gs://${BUCKET}"
# The Storage API precondition prevents overwriting an edit made after the read.
token=$(gcloud auth print-access-token --project "$PROJECT_ID")
printf 'Authorization: Bearer %s\n' "$token" | curl --disable --fail --silent --show-error \
  --request PATCH --header @- --header 'Content-Type: application/json' \
  --data-binary "{\"lifecycle\":{\"rule\":${updated_rules}}}" --output /dev/null \
  "https://storage.googleapis.com/storage/v1/b/${BUCKET}?ifMetagenerationMatch=${metageneration}"
echo "Done."
