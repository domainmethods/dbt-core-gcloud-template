{% macro guard_dev_environment() %}

  {% if target.name == 'prod' %}
    {% set is_ci = (env_var('CI', '') | lower == 'true') or (env_var('GITHUB_ACTIONS', '') | lower == 'true') %}
    {% if not is_ci %}
      {{ exceptions.raise_compiler_error(
        "Blocked: target 'prod' is reserved for CI/CD.\n"
        ~ "  Production deploys run automatically via GitHub Actions on merge to main.\n"
        ~ "  Local developers do not need (and should not have) prod credentials.\n\n"
        ~ "  Instead, use:\n"
        ~ "    dbt build                              (builds against your dev dataset)\n"
        ~ "    dbt run-operation dev_prod_diff         (compare dev vs prod read-only)"
      ) }}
    {% endif %}
  {% endif %}

  {% if target.name == 'dev' %}
    {% set user = env_var('DBT_USER', '') %}
    {% if not user or user == 'local' %}
      {{ log(
        "WARNING: DBT_USER is not set (dataset defaults to analytics_local). "
        ~ "Run 'source ./setup-env.sh' for proper per-developer isolation.",
        info=True
      ) }}
    {% endif %}
  {% endif %}

{% endmacro %}
