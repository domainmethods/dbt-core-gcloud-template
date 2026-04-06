{#
  generate_schema_name: Controls how dbt resolves schema (dataset) names.

  Default behavior:
    - If a model specifies a custom schema (e.g., +schema: finance), dbt appends
      it to the target dataset: analytics_dev_finance
    - If no custom schema, uses the target dataset as-is: analytics_dev

  This macro keeps the default dbt behavior. Override it here if your team needs
  custom routing (e.g., multi-tenant datasets, environment-specific prefixes).

  See: https://docs.getdbt.com/docs/build/custom-schemas
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {{ default_schema }}_{{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
