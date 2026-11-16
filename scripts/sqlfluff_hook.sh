#!/usr/bin/env bash
# pre-commit entry for the sqlfluff hooks (#15).
#
# sqlfluff's dbt templater compiles the project, and dbt refuses to compile
# while a package in packages.yml is not installed. So a fresh clone, or any
# packages.yml change, failed every push with UninstalledPackagesFoundError
# until someone ran `dbt deps` by hand. This runs `dbt deps` first when
# dbt_packages/ is missing or older than packages.yml (or package-lock.yml),
# then hands over to sqlfluff. dbt and sqlfluff come from the hook's own env.
#
# Usage (from .pre-commit-config.yaml): sqlfluff_hook.sh lint|fix [files...]
set -euo pipefail

needs_deps() {
  [[ -f packages.yml ]] || return 1
  [[ -d dbt_packages ]] || return 0
  local f
  for f in packages.yml package-lock.yml; do
    [[ -f "$f" && "$f" -nt dbt_packages ]] && return 0
  done
  return 1
}

if needs_deps; then
  echo "[sqlfluff] dbt_packages/ missing or stale -- running dbt deps" >&2
  dbt deps --quiet
  touch dbt_packages
fi

exec sqlfluff "$@"
