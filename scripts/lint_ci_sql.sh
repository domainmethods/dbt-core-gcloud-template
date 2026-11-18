#!/usr/bin/env bash
set -euo pipefail

# dbt ls selects enabled project models without opening a BigQuery connection.
# SQLFluff's dbt templater opens one to populate the relation cache, so CI uses Jinja.
# dbt logs its errors to stdout as text, so show that instead of handing it to jq.
dbt_err=$(mktemp)
trap 'rm -f "$dbt_err"' EXIT
if ! models=$(dbt ls --quiet --resource-type model --select 'package:this,path:models' \
  --output json --output-keys original_file_path 2>"$dbt_err"); then
  printf 'dbt ls failed:\n%s\n' "$models" >&2
  cat "$dbt_err" >&2
  exit 1
fi

# The Jinja builtins cover ref/source/config/var but not env_var or package macros
# (dbt_utils.*). --ignore templating renders those as placeholders instead of failing
# the file. Scoped here so the local dbt templater hooks keep full rendering.
jq -j '.original_file_path | select(startswith("models/") and endswith(".sql")) | ., "\u0000"' <<< "$models" \
  | xargs -0 -r sqlfluff lint --templater jinja --ignore templating "$@"
