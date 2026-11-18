#!/usr/bin/env bash
# Exercises CI lint with dbt and SQLFluff installed and an empty credential environment.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT
cd "$fixture_dir"
cp "$repo_root/.sqlfluff" "$repo_root/dbt_project.yml" .
cp -R "$repo_root/profiles" "$repo_root/macros" .
mkdir models
cat > models/sources.yml <<'YAML'
version: 2
sources:
  - name: raw
    tables:
      - name: example
YAML
cat > models/enabled.sql <<'SQL'
{{ config(enabled=true) }}

select id
from {{ source('raw', 'example') }}
SQL
printf '{{ config(enabled=false) }}\n\nselect  1 as lint_value\n' > models/disabled.sql

lint_models() {
  env -i HOME="$fixture_dir" PATH="$PATH" DBT_TARGET=ci DBT_PROFILES_DIR=./profiles \
    DBT_GCP_PROJECT_CI=lint-ci DBT_BQ_DATASET=lint_ci DBT_SEND_ANONYMOUS_USAGE_STATS=false \
    bash "$repo_root/scripts/lint_ci_sql.sh" --format json
}

if ! report=$(lint_models) || ! jq -e '
  length == 1 and .[0].filepath == "models/enabled.sql"
  and .[0].statistics.templated_chars > 0 and .[0].violations == []
' <<< "$report" >/dev/null; then
  printf 'Expected a valid, linted enabled model. Got:\n%s\n' "$report" >&2
  exit 1
fi
echo "Accepted enabled model"

sed 's/select id/select  id/' models/enabled.sql > models/invalid.sql
status=0
report=$(lint_models) || status=$?
if [[ $status == 0 ]] || ! jq -e '
  any(.[] | select(.filepath == "models/invalid.sql").violations[]; .code == "LT01")
' <<< "$report" >/dev/null; then
  printf 'Expected an LT01 violation on the invalid model. Got:\n%s\n' "$report" >&2
  exit 1
fi
echo "Rejected invalid enabled model with LT01"
