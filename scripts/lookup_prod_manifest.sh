#!/usr/bin/env bash
# Usage: lookup_prod_manifest.sh gs://bucket/prod/manifest.json
# Exit 0 = found, 2 = missing, 1 = lookup failed (after one retry).
# Only "missing" justifies a full build without --defer (first deploy). An auth,
# permission or network error used to read as "missing" too, so CI stayed green
# while it silently built the whole project (#74).
set -uo pipefail

url="$1"
delay="${PROD_MANIFEST_RETRY_DELAY:-5}"

for attempt in 1 2; do
  if err=$(gsutil ls "${url}" 2>&1 >/dev/null); then
    exit 0
  fi
  if grep -q "matched no objects" <<<"${err}"; then
    echo "No production manifest found at ${url} (not found)"
    exit 2
  fi
  echo "Production manifest lookup failed (attempt ${attempt}): ${err}"
  if [[ ${attempt} -eq 1 ]]; then
    echo "Retrying in ${delay}s..."
    sleep "${delay}"
  fi
done
exit 1
