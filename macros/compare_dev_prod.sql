{% macro dev_prod_diff(table_name, dev_project=None, prod_project=None, dev_dataset_prefix='analytics_', dev_dataset=None, prod_dataset=None, limit=100, execute_query=True, new_model=False) %}
  {#
    Compare a dev table (derived from DBT_USER) vs prod using EXCEPT DISTINCT and counts.
    Usage:
      dbt run-operation dev_prod_diff --args '{"table_name":"fct_example"}'
    Optional args:
      dev_project, prod_project, dev_dataset_prefix, prod_dataset, execute_query (bool)
      new_model (bool): report as new without checking prod. pr_data_diff.sh sets it for a
        model missing from the prod manifest, so a leftover prod table with the same name
        isn't diffed as if it were the model's (#12).
  #}

  {% set user = env_var('DBT_USER') %}
  {% if not user %}
    {{ exceptions.raise_compiler_error("DBT_USER is not set. Export DBT_USER to derive the dev dataset.") }}
  {% endif %}

  {% set _dev_project = dev_project or target.project %}
  {% set _prod_project = prod_project or env_var('DBT_GCP_PROJECT_PROD') or target.project %}
  {% set _dev_dataset = dev_dataset or (dev_dataset_prefix ~ user) %}
  {% set _prod_dataset = prod_dataset or env_var('DBT_BQ_DATASET_PROD', 'analytics') %}

  {# Check if production table exists #}
  {% set table_exists_sql %}
    SELECT COUNT(*) as table_count
    FROM `{{ _prod_project }}.{{ _prod_dataset }}.INFORMATION_SCHEMA.TABLES`
    WHERE table_name = '{{ table_name }}'
  {% endset %}

  {% if execute_query %}
    {% do log('Comparing ' ~ _dev_project ~ '.' ~ _dev_dataset ~ '.' ~ table_name ~ ' vs ' ~ _prod_project ~ '.' ~ _prod_dataset ~ '.' ~ table_name, info=True) %}

    {# First get dev count since we always need this #}
    {% set dev_count_sql %}
      SELECT COUNT(*) FROM `{{ _dev_project }}.{{ _dev_dataset }}.{{ table_name }}`
    {% endset %}
    {% set dev_count_result = run_query(dev_count_sql) %}
    {% set dev_count = dev_count_result.columns[0].values()[0] %}

    {# Try to check if production table exists - use safe SQL that handles auth errors #}
    {% set safe_table_check_sql %}
      SELECT
        CASE
          WHEN (
            SELECT COUNT(*)
            FROM `{{ _prod_project }}.{{ _prod_dataset }}.INFORMATION_SCHEMA.TABLES`
            WHERE table_name = '{{ table_name }}'
          ) > 0 THEN 'EXISTS'
          ELSE 'NEW_MODEL'
        END as table_status,
        'SUCCESS' as check_status
    {% endset %}

    {# Execute the check and handle any errors by treating as auth error #}
    {% set prod_table_exists = false %}
    {% set table_status = 'AUTH_ERROR' %}

    {# The run_query will fail if there are auth issues, but script continues due to || true in calling script #}
    {% if new_model %}
      {% set table_status = 'NEW_MODEL' %}
      {% do log('Not in the production manifest; skipping the production table check', info=True) %}
    {% else %}
    {% set table_check_result = run_query(safe_table_check_sql) %}
    {% endif %}
    {% if not new_model and table_check_result and table_check_result.columns and table_check_result.columns|length > 0 %}
      {% set table_status = table_check_result.columns[0].values()[0] %}
      {% if table_status == 'EXISTS' %}
        {% set prod_table_exists = true %}
      {% endif %}
    {% endif %}

    {% if table_status == 'AUTH_ERROR' %}
      {# Could not determine if production table exists due to auth/network error #}
      {% do log('Unable to check production table existence due to authentication/network issues', info=True) %}
      {% do log('Treating as new model for safety', info=True) %}
      {% set summary = 'SUMMARY|' ~ 'table=' ~ table_name ~ '|dev=' ~ dev_count ~ '|prod=AUTH_ERROR|dev_not_in_prod=AUTH_ERROR|prod_not_in_dev=AUTH_ERROR' %}
      {% do log(summary, info=True) %}
      {% do log('Authentication/network error - could not verify production table status. Dev environment has ' ~ dev_count ~ ' rows', info=True) %}
    {% elif not prod_table_exists %}
      {# Production table doesn't exist - this is a new model #}
      {% do log('Production table does not exist - this appears to be a new model', info=True) %}
      {% set summary = 'SUMMARY|' ~ 'table=' ~ table_name ~ '|dev=' ~ dev_count ~ '|prod=NEW_MODEL|dev_not_in_prod=NEW_MODEL|prod_not_in_dev=NEW_MODEL' %}
      {% do log(summary, info=True) %}
      {% do log('This is a new model with ' ~ dev_count ~ ' rows in the dev environment', info=True) %}
    {% else %}
      {# Production table exists - proceed with normal comparison #}
      {% set counts_sql %}
        SELECT
          (SELECT COUNT(*) FROM `{{ _prod_project }}.{{ _prod_dataset }}.{{ table_name }}`) AS prod_count,
          (SELECT COUNT(*) FROM `{{ _dev_project }}.{{ _dev_dataset }}.{{ table_name }}`)  AS dev_count
      {% endset %}

      {% set diff_counts_sql %}
        WITH prod AS (
          SELECT * FROM `{{ _prod_project }}.{{ _prod_dataset }}.{{ table_name }}`
        ),
        dev AS (
          SELECT * FROM `{{ _dev_project }}.{{ _dev_dataset }}.{{ table_name }}`
        )
        SELECT
          (SELECT COUNT(*) FROM (SELECT * FROM dev EXCEPT DISTINCT SELECT * FROM prod)) AS dev_not_in_prod,
          (SELECT COUNT(*) FROM (SELECT * FROM prod EXCEPT DISTINCT SELECT * FROM dev)) AS prod_not_in_dev
      {% endset %}

      {% set diffs_sql %}
        WITH prod AS (
          SELECT * FROM `{{ _prod_project }}.{{ _prod_dataset }}.{{ table_name }}`
        ),
        dev AS (
          SELECT * FROM `{{ _dev_project }}.{{ _dev_dataset }}.{{ table_name }}`
        )
        -- BigQuery needs the parentheses to mix EXCEPT and UNION ALL.
        (SELECT 'in_dev_not_in_prod' AS diff_type, * FROM dev
         EXCEPT DISTINCT
         SELECT 'in_dev_not_in_prod' AS diff_type, * FROM prod)
        UNION ALL
        (SELECT 'in_prod_not_in_dev' AS diff_type, * FROM prod
         EXCEPT DISTINCT
         SELECT 'in_prod_not_in_dev' AS diff_type, * FROM dev)
        {% if limit|int > 0 %}
        LIMIT {{ limit|int }}
        {% endif %}
      {% endset %}

      {% set counts = run_query(counts_sql) %}
      {% set diff_counts = run_query(diff_counts_sql) %}
      {% set prod_count = counts.columns[0].values()[0] %}
      {% set dev_count = counts.columns[1].values()[0] %}
      {% set dev_not_in_prod = diff_counts.columns[0].values()[0] %}
      {% set prod_not_in_dev = diff_counts.columns[1].values()[0] %}
      {% set summary = 'SUMMARY|' ~ 'table=' ~ table_name ~ '|dev=' ~ dev_count ~ '|prod=' ~ prod_count ~ '|dev_not_in_prod=' ~ dev_not_in_prod ~ '|prod_not_in_dev=' ~ prod_not_in_dev %}
      {% do log(summary, info=True) %}
      {% do log('Showing up to ' ~ (limit|int) ~ ' diff rows (set limit arg to control).', info=True) %}
      {% set sample = run_query(diffs_sql) %}
      {% do log(sample, info=True) %}
    {% endif %}
  {% elif new_model %}
    {# Non-execute mode, model not in the prod manifest: there is no prod table to compare #}
    {% do log('Not in the production manifest; nothing to compare ' ~ _dev_project ~ '.' ~ _dev_dataset ~ '.' ~ table_name ~ ' against', info=True) %}
  {% else %}
    {# Non-execute mode - just show the SQL #}
    {% do log('-- Table existence check', info=True) %}
    {% do log(table_exists_sql, info=True) %}
    {% do log('-- Counts (if table exists)', info=True) %}
    {% set counts_sql %}
      SELECT
        (SELECT COUNT(*) FROM `{{ _prod_project }}.{{ _prod_dataset }}.{{ table_name }}`) AS prod_count,
        (SELECT COUNT(*) FROM `{{ _dev_project }}.{{ _dev_dataset }}.{{ table_name }}`)  AS dev_count
    {% endset %}
    {% do log(counts_sql, info=True) %}
    {% do log('-- Diff counts (if table exists)', info=True) %}
    {% set diff_counts_sql %}
      WITH prod AS (
        SELECT * FROM `{{ _prod_project }}.{{ _prod_dataset }}.{{ table_name }}`
      ),
      dev AS (
        SELECT * FROM `{{ _dev_project }}.{{ _dev_dataset }}.{{ table_name }}`
      )
      SELECT
        (SELECT COUNT(*) FROM (SELECT * FROM dev EXCEPT DISTINCT SELECT * FROM prod)) AS dev_not_in_prod,
        (SELECT COUNT(*) FROM (SELECT * FROM prod EXCEPT DISTINCT SELECT * FROM dev)) AS prod_not_in_dev
    {% endset %}
    {% do log(diff_counts_sql, info=True) %}
    {% do log('-- Diff sample (if table exists)', info=True) %}
    {% set diffs_sql %}
      WITH prod AS (
        SELECT * FROM `{{ _prod_project }}.{{ _prod_dataset }}.{{ table_name }}`
      ),
      dev AS (
        SELECT * FROM `{{ _dev_project }}.{{ _dev_dataset }}.{{ table_name }}`
      )
      -- BigQuery needs the parentheses to mix EXCEPT and UNION ALL.
      (SELECT 'in_dev_not_in_prod' AS diff_type, * FROM dev
       EXCEPT DISTINCT
       SELECT 'in_dev_not_in_prod' AS diff_type, * FROM prod)
      UNION ALL
      (SELECT 'in_prod_not_in_dev' AS diff_type, * FROM prod
       EXCEPT DISTINCT
       SELECT 'in_prod_not_in_dev' AS diff_type, * FROM dev)
      {% if limit|int > 0 %}
      LIMIT {{ limit|int }}
      {% endif %}
    {% endset %}
    {% do log(diffs_sql, info=True) %}
  {% endif %}

{% endmacro %}

{% macro dev_prod_diff_for_model(model_name, dev_project=None, prod_project=None, dev_dataset_prefix='analytics_', dev_dataset=None, prod_dataset=None, limit=100, execute_query=True, new_model=False) %}
  {# Resolve the relation for the model in the current target to get its identifier #}
  {% set rel = ref(model_name) %}
  {% set identifier = rel.identifier %}
  {% set _dev_project = dev_project or rel.database or target.project %}
  {% do dev_prod_diff(identifier, dev_project=_dev_project, prod_project=prod_project, dev_dataset_prefix=dev_dataset_prefix, dev_dataset=dev_dataset, prod_dataset=prod_dataset, limit=limit, execute_query=execute_query, new_model=new_model) %}
{% endmacro %}
