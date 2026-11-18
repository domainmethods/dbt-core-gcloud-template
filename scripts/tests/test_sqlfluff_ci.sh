#!/usr/bin/env bash
# Exercises CI lint with dbt and SQLFluff installed and an empty credential environment.
set -euo pipefail

# sqlfluff is not in requirements.txt (locally it lives in pre-commit's env), so a
# developer machine may lack it: skip there, but fail in CI where the lint job installs it.
for tool in dbt sqlfluff jq; do
  command -v "$tool" >/dev/null || {
    if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
      echo "test_sqlfluff_ci.sh needs $tool on PATH" >&2
      exit 1
    fi
    echo "SKIP test_sqlfluff_ci.sh: $tool not on PATH (needs dbt from make deps, sqlfluff==3.4.2 and jq)" >&2
    exit 0
  }
done

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
# Package macros and env_var are valid dbt but undefined in SQLFluff's Jinja builtins.
# A local stand-in for dbt_utils keeps dbt ls offline.
mkdir -p utils_stub/macros
printf 'name: dbt_utils\nversion: "1.0.0"\nconfig-version: 2\n' > utils_stub/dbt_project.yml
cat > utils_stub/macros/keys.sql <<'SQL'
{% macro generate_surrogate_key(cols) %}md5(cast({{ cols | join(' || ') }} as string)){% endmacro %}
SQL
printf 'packages:\n  - local: utils_stub\n' > packages.yml
cat > models/uses_package.sql <<'SQL'
select
    {{ dbt_utils.generate_surrogate_key(['id']) }} as sk,
    '{{ env_var("DBT_LINT_LABEL", "none") }}' as label
from {{ source('raw', 'example') }}
SQL
printf '{{ config(enabled=false) }}\n\nselect  1 as lint_value\n' > models/disabled.sql

offline() {
  env -i HOME="$fixture_dir" PATH="$PATH" DBT_TARGET=ci DBT_PROFILES_DIR=./profiles \
    DBT_GCP_PROJECT_CI=lint-ci DBT_BQ_DATASET=lint_ci DBT_SEND_ANONYMOUS_USAGE_STATS=false "$@"
}
lint_models() { offline bash "$repo_root/scripts/lint_ci_sql.sh" --format json; }

offline dbt deps --quiet

if ! report=$(lint_models) || ! jq -e '
  (map(.filepath) | sort) == ["models/enabled.sql", "models/uses_package.sql"]
  and all(.[]; .statistics.templated_chars > 0 and .violations == [])
' <<< "$report" >/dev/null; then
  printf 'Expected valid, linted enabled models. Got:\n%s\n' "$report" >&2
  exit 1
fi
echo "Accepted enabled models, including dbt_utils and env_var calls"

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

rm models/invalid.sql
printf "select 1 from {{ ref('no_such_model') }}\n" > models/broken.sql
status=0
output=$(lint_models 2>&1) || status=$?
if [[ $status == 0 ]] || [[ $output != *"dbt ls failed"* ]] || [[ $output != *no_such_model* ]] \
  || [[ $output == *"parse error"* ]]; then
  printf 'Expected dbt ls error to be shown and exit non-zero. Got (%s):\n%s\n' "$status" "$output" >&2
  exit 1
fi
echo "Reported dbt ls failure"
