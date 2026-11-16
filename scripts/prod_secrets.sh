#!/usr/bin/env bash
# Parse PROD_SECRETS: comma-separated ENV_VAR=secret-name[:version] pairs that map
# Secret Manager secrets to env vars in the prod Cloud Run job (#32). Sourced by
# infra/12-secret-manager.sh, infra/30-deploy-cloud-run-job.sh and release.yml.
# bash 3.2 safe: no mapfile, no associative arrays.

# Print one validated "ENV_VAR=secret-name[:version]" per line; exit 2 on a bad entry.
_prod_secret_entries() {
  local raw="$1" entry seen=" " var
  local IFS=','
  for entry in $raw; do
    entry=$(echo "$entry" | tr -d '[:space:]')
    [[ -z "$entry" ]] && continue
    if [[ ! "$entry" =~ ^[A-Z_][A-Z0-9_]*=[A-Za-z0-9_-]+(:([0-9]+|latest))?$ ]]; then
      echo "[error] PROD_SECRETS entry '$entry': use ENV_VAR=secret-name or ENV_VAR=secret-name:version" >&2
      return 2
    fi
    var="${entry%%=*}"
    if [[ "$seen" == *" $var "* ]]; then
      echo "[error] PROD_SECRETS sets $var twice" >&2
      return 2
    fi
    seen="${seen}${var} "
    echo "$entry"
  done
}

# Value for `gcloud run jobs ... --set-secrets`: unpinned entries get :latest.
prod_secrets_flag() {
  local entries entry out=""
  entries=$(_prod_secret_entries "$1") || return 2
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ "${entry#*=}" == *:* ]] || entry="${entry}:latest"
    out="${out:+${out},}${entry}"
  done <<<"$entries"
  echo "$out"
}

# Secret names, one per line, versions stripped.
prod_secret_names() {
  local entries entry name
  entries=$(_prod_secret_entries "$1") || return 2
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    name="${entry#*=}"
    echo "${name%%:*}"
  done <<<"$entries"
}
