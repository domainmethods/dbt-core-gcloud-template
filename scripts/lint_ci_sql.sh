#!/usr/bin/env bash
set -euo pipefail

# dbt ls selects enabled project models without opening a BigQuery connection.
# SQLFluff's dbt templater opens one to populate the relation cache, so CI uses Jinja.
dbt ls --quiet --resource-type model --select 'package:this,path:models' \
  --output json --output-keys original_file_path \
  | jq -j '.original_file_path | select(startswith("models/") and endswith(".sql")) | ., "\u0000"' \
  | xargs -0 -r sqlfluff lint --templater jinja "$@"
