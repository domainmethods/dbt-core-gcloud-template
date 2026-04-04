#!/usr/bin/env bash
set -euo pipefail

# Schema diff for dbt CI on BigQuery
# - Compares PR (dev) relations vs prod: columns/types/nullability, table type, partitioning, clustering
# - Detects movement (dataset/identifier changes) via manifests when available
# - Lists orphaned prod relations not covered by dbt models/sources
#
# Inputs via env:
#   DBT_GCP_PROJECT_CI   (required)
#   DBT_BQ_DATASET       (required)
#   DBT_GCP_PROJECT_PROD (optional, defaults to CI project)
#   DBT_BQ_DATASET_PROD  (optional, default: analytics)
#   SCHEMA_DIFF_PROD_DATASETS (optional, comma-separated; overrides DBT_BQ_DATASET_PROD)
#   ARTIFACT_DIR         (optional, default: schema_diff_reports)
#
# Requires: dbt, bq, jq

ARTIFACT_DIR=${ARTIFACT_DIR:-schema_diff_reports}
DEV_PROJECT=${DBT_GCP_PROJECT_CI:?set DBT_GCP_PROJECT_CI}
DEV_DATASET=${DBT_BQ_DATASET:?set DBT_BQ_DATASET}
PROD_PROJECT=${DBT_GCP_PROJECT_PROD:-$DEV_PROJECT}
DEFAULT_PROD_DATASET=${DBT_BQ_DATASET_PROD:-analytics}

command -v jq >/dev/null || {
  echo "[warn] jq not found; schema diff requires jq. Skipping." >&2
  exit 0
}
command -v bq >/dev/null || {
  echo "[warn] bq CLI not found; skipping schema diff." >&2
  exit 0
}

mkdir -p "$ARTIFACT_DIR"

PR_MANIFEST=target/manifest.json
PROD_MANIFEST=prod_state/manifest.json

echo "=== Schema Diff: State Detection ==="
if [[ -f "$PROD_MANIFEST" ]]; then
  echo "✓ Found production manifest for state selection and movement detection"
else
  echo "⚠ No production manifest found; will select all models and movement=UNKNOWN"
fi

if [[ ! -f "$PR_MANIFEST" ]]; then
  echo "⚠ PR manifest not found at $PR_MANIFEST; running 'dbt docs generate --static' to produce it" >&2
  dbt docs generate --static || true
fi

if [[ ! -f "$PR_MANIFEST" ]]; then
  echo "[error] Could not find or generate $PR_MANIFEST. Exiting schema diff." >&2
  exit 0
fi

echo ""
echo "=== Model Selection ==="
if [[ -f "$PROD_MANIFEST" ]]; then
  mapfile -t MODELS < <(dbt ls --select "state:modified+" --state prod_state --resource-type model --output name --quiet 2>/dev/null || true)
  if (( ${#MODELS[@]} == 0 )); then
    echo "  (none - no models changed)"
  else
    printf "  - %s\n" "${MODELS[@]}"
  fi
else
  mapfile -t MODELS < <(dbt ls --resource-type model --output name --quiet 2>/dev/null || true)
  echo "Selected all models (${#MODELS[@]} total)"
fi

if (( ${#MODELS[@]} == 0 )); then
  echo "No models to schema-diff."
  exit 0
fi

# Helper: get model node JSON from manifest by name
get_node_by_name() {
  local manifest=$1 name=$2
  jq -r --arg n "$2" '
    .nodes 
    | to_entries[]
    | select(.value.resource_type=="model" and .value.name==$n)
    | .value'
}

# Helper: get node by unique_id from manifest
get_node_by_uid() {
  local manifest=$1 uid=$2
  jq -r --arg uid "$uid" '.nodes[$uid] // empty' "$manifest"
}

# Helper: extract FQN parts {project,dataset,identifier,uid}
node_to_fqn() {
  jq -r '{
    project: (.database // ""),
    dataset: (.schema // ""),
    identifier: ((.alias // .name) // ""),
    uid: .unique_id
  }'
}

# Helper: safe bq query to JSON; echoes JSON or empty and returns non-zero on error
# Cap at 1GB scanned to prevent runaway costs on INFORMATION_SCHEMA queries
bq_json() {
  local project=$1 sql=$2
  local out
  out=$(bq --project_id="$project" query --nouse_legacy_sql --format=json --maximum_bytes_billed=1000000000 "$sql" 2>&1) || {
    echo "$out" >&2
    return 1
  }
  echo "$out"
}

bq_columns() {
  local project=$1 dataset=$2 ident=$3
  local sql="SELECT column_name, ordinal_position, data_type, is_nullable FROM \`$project.$dataset\`.INFORMATION_SCHEMA.COLUMNS WHERE table_name = '$ident' ORDER BY ordinal_position"
  bq_json "$project" "$sql"
}

bq_table_type() {
  local project=$1 dataset=$2 ident=$3
  local sql="SELECT table_type FROM \`$project.$dataset\`.INFORMATION_SCHEMA.TABLES WHERE table_name = '$ident'"
  bq_json "$project" "$sql"
}

bq_table_options() {
  local project=$1 dataset=$2 ident=$3
  local sql="SELECT option_name, option_value FROM \`$project.$dataset\`.INFORMATION_SCHEMA.TABLE_OPTIONS WHERE table_name = '$ident' AND option_name IN ('partitioning_type','partitioning_field','require_partition_filter','clustering_fields')"
  bq_json "$project" "$sql"
}

normalize_options() {
  jq -r '[.[] | {key: .option_name, val: .option_value}] | map({(.key): .val}) | add // {}'
}

compute_column_diff() {
  local dev_json=$1 prod_json=$2
  jq -r --argjson dev "$dev_json" --argjson prod "$prod_json" '
    def mapcols($arr): reduce $arr[] as $c ({}; .[$c.column_name] = {type: $c.data_type, nullable: $c.is_nullable});
    def keys_of($m): ($m|keys|sort);
    def inter($a;$b): ($a + $b | group_by(.) | map(select(length==2) | .[0]));
    def minus($a;$b): ($a - $b);
    
    (mapcols($dev)) as $dm
    | (mapcols($prod)) as $pm
    | (keys_of($dm)) as $dk
    | (keys_of($pm)) as $pk
    | {
        added: minus($dk; $pk),
        removed: minus($pk; $dk),
        changed: (inter($dk;$pk) | map(select(($dm[.].type != $pm[.].type) or ($dm[.].nullable != $pm[.].nullable))
                 | {name: ., dev: $dm[.], prod: $pm[.]}))
      }'
}

compute_meta_diff() {
  local dev_type=$1 prod_type=$2 dev_opts_json=$3 prod_opts_json=$4
  jq -r --arg devt "$dev_type" --arg prodt "$prod_type" --argjson devo "$dev_opts_json" --argjson prodo "$prod_opts_json" '
    def norm($o): {
      partitioning_type: ($o.partitioning_type // null),
      partitioning_field: ($o.partitioning_field // null),
      require_partition_filter: ($o.require_partition_filter // null),
      clustering_fields: ($o.clustering_fields // null)
    };
    (norm(devo)) as $d | (norm(prodo)) as $p |
    {
      table_type_change: (if ($devt|length)==0 or ($prodt|length)==0 then null else (if $devt==$prodt then null else {from:$prodt, to:$devt} end) end),
      option_changes: ( [
        (if $d.partitioning_type != $p.partitioning_type then {key:"partitioning_type", from:$p.partitioning_type, to:$d.partitioning_type} else empty end),
        (if $d.partitioning_field != $p.partitioning_field then {key:"partitioning_field", from:$p.partitioning_field, to:$d.partitioning_field} else empty end),
        (if $d.require_partition_filter != $p.require_partition_filter then {key:"require_partition_filter", from:$p.require_partition_filter, to:$d.require_partition_filter} else empty end),
        (if $d.clustering_fields != $p.clustering_fields then {key:"clustering_fields", from:$p.clustering_fields, to:$d.clustering_fields} else empty end)
      ])
    }'
}

# Build prod dataset list
IFS="," read -r -a PROD_DATASETS_ARR <<< "${SCHEMA_DIFF_PROD_DATASETS:-$DEFAULT_PROD_DATASET}"

summary_md="$ARTIFACT_DIR/schema-summary.md"
echo "# dbt Schema Diff Summary" > "$summary_md"
echo >> "$summary_md"
echo "_Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")_" >> "$summary_md"
echo >> "$summary_md"
echo "| Model | Status | Moved | Type Change | +Cols | -Cols | Changed | Part/Cluster Changes |" >> "$summary_md"
echo "|---|---|---|---|---:|---:|---:|---|" >> "$summary_md"

movement_status() {
  local dev_fqn=$1 prod_fqn=$2
  if [[ -z "$prod_fqn" ]]; then echo "UNKNOWN"; return; fi
  if [[ "$dev_fqn" == "$prod_fqn" ]]; then echo "UNCHANGED"; else echo "MOVED"; fi
}

for m in "${MODELS[@]}"; do
  safe="${m//\//_}"
  out="$ARTIFACT_DIR/${safe}.txt"
  echo "== ${m} ==" | tee "$out"

  # PR node
  pr_node=$(get_node_by_name "$PR_MANIFEST" "$m")
  if [[ -z "$pr_node" || "$pr_node" == "null" ]]; then
    echo "[warn] Could not resolve model $m in PR manifest; skipping" | tee -a "$out"
    continue
  fi
  pr_fqn=$(echo "$pr_node" | node_to_fqn)
  pr_proj=$(echo "$pr_fqn" | jq -r .project)
  pr_ds=$(echo "$pr_fqn" | jq -r .dataset)
  pr_ident=$(echo "$pr_fqn" | jq -r .identifier)
  pr_uid=$(echo "$pr_fqn" | jq -r .uid)

  # Dev side uses CI env regardless of manifest database to ensure correctness
  DEV_P="$DEV_PROJECT"; DEV_D="$DEV_DATASET"; DEV_T="$pr_ident"

  # Prod node (from prod manifest preferred)
  prod_fqn_json=""
  if [[ -f "$PROD_MANIFEST" && -n "$pr_uid" && "$pr_uid" != "null" ]]; then
    prod_node=$(get_node_by_uid "$PROD_MANIFEST" "$pr_uid")
    if [[ -z "$prod_node" || "$prod_node" == "null" ]]; then
      # try by name fallback
      prod_node=$(get_node_by_name "$PROD_MANIFEST" "$m")
    fi
    if [[ -n "$prod_node" && "$prod_node" != "null" ]]; then
      prod_fqn_json=$(echo "$prod_node" | node_to_fqn)
    fi
  fi

  if [[ -z "$prod_fqn_json" ]]; then
    # default to configured prod dataset with same identifier
    prod_fqn_json=$(jq -n --arg p "$PROD_PROJECT" --arg d "${PROD_DATASETS_ARR[0]}" --arg t "$pr_ident" '{project:$p,dataset:$d,identifier:$t}')
  fi
  PROD_P=$(echo "$prod_fqn_json" | jq -r .project)
  PROD_D=$(echo "$prod_fqn_json" | jq -r .dataset)
  PROD_T=$(echo "$prod_fqn_json" | jq -r .identifier)

  dev_fqn_str="$DEV_P.$DEV_D.$DEV_T"
  prod_fqn_str="$PROD_P.$PROD_D.$PROD_T"
  echo "Dev:  $dev_fqn_str" | tee -a "$out"
  echo "Prod: $prod_fqn_str" | tee -a "$out"

  move=$(movement_status "$dev_fqn_str" "$prod_fqn_str")
  if [[ "$move" == "MOVED" ]]; then
    echo "Movement: $prod_fqn_str -> $dev_fqn_str" | tee -a "$out"
  else
    echo "Movement: $move" | tee -a "$out"
  fi

  # Introspect
  dev_cols_json=$(bq_columns "$DEV_P" "$DEV_D" "$DEV_T" 2>/dev/null || true)
  prod_cols_json=$(bq_columns "$PROD_P" "$PROD_D" "$PROD_T" 2>/dev/null || true)
  dev_type_json=$(bq_table_type "$DEV_P" "$DEV_D" "$DEV_T" 2>/dev/null || true)
  prod_type_json=$(bq_table_type "$PROD_P" "$PROD_D" "$PROD_T" 2>/dev/null || true)
  dev_opts_json=$(bq_table_options "$DEV_P" "$DEV_D" "$DEV_T" 2>/dev/null || true)
  prod_opts_json=$(bq_table_options "$PROD_P" "$PROD_D" "$PROD_T" 2>/dev/null || true)

  status="OK"
  if [[ -z "$prod_cols_json" || "$prod_cols_json" == *"Access Denied"* ]]; then
    status="AUTH_ERROR"
  fi

  # Detect new model (no prod cols and no tables row)
  prod_type=$(echo "${prod_type_json:-[]}" | jq -r '.[0].table_type // empty')
  if [[ -z "$prod_type" && "$status" != "AUTH_ERROR" ]]; then
    status="NEW_MODEL"
  fi
  dev_type=$(echo "${dev_type_json:-[]}" | jq -r '.[0].table_type // empty')

  # Normalize options
  dev_opts=$(echo "${dev_opts_json:-[]}" | jq -r ' . | (if type=="array" then . else [] end) ' | normalize_options)
  prod_opts=$(echo "${prod_opts_json:-[]}" | jq -r ' . | (if type=="array" then . else [] end) ' | normalize_options)

  # Column diff (skip if auth error and not new model)
  added=0; removed=0; changed=0
  if [[ "$status" == "OK" || "$status" == "NEW_MODEL" ]]; then
    col_diff=$(compute_column_diff "${dev_cols_json:-[]}" "${prod_cols_json:-[]}")
    added=$(echo "$col_diff" | jq -r '.added | length')
    removed=$(echo "$col_diff" | jq -r '.removed | length')
    changed=$(echo "$col_diff" | jq -r '.changed | length')
  fi

  meta_diff=$(compute_meta_diff "$dev_type" "$prod_type" "$dev_opts" "$prod_opts")
  type_change=$(echo "$meta_diff" | jq -r '.table_type_change | if .==null then "" else (.from + "→" + .to) end')
  opt_changes_cnt=$(echo "$meta_diff" | jq -r '.option_changes | length')

  echo "Table types: dev=$dev_type prod=${prod_type:-<none>}" | tee -a "$out"

  if [[ "$status" == "OK" || "$status" == "NEW_MODEL" ]]; then
    echo "Columns added ($added):" | tee -a "$out"
    echo "$col_diff" | jq -r '.added[]? | "  + " + .' | tee -a "$out"
    echo "Columns removed ($removed):" | tee -a "$out"
    echo "$col_diff" | jq -r '.removed[]? | "  - " + .' | tee -a "$out"
    echo "Columns changed ($changed):" | tee -a "$out"
    echo "$col_diff" | jq -r '.changed[]? | "  * " + .name + ": dev=(" + .dev.type + "/" + .dev.nullable + ") prod=(" + .prod.type + "/" + .prod.nullable + ")"' | tee -a "$out"
  fi

  echo "Partition/Clustering changes ($opt_changes_cnt):" | tee -a "$out"
  echo "$meta_diff" | jq -r '.option_changes[]? | "  ~ " + .key + ": dev=" + (.to|tostring) + ", prod=" + (.from|tostring)' | tee -a "$out"

  # Summary line for downstream parsing if needed
  echo "SUMMARY|model=$m|status=$status|moved=$move|type_change=${type_change:-none}|added=$added|removed=$removed|changed=$changed|opt_changes=$opt_changes_cnt" | tee -a "$out"

  # Append to markdown table
  moved_cell="$move"
  if [[ "$move" == "MOVED" ]]; then
    moved_cell="$prod_fqn_str → $dev_fqn_str"
  fi
  partcell=$( [[ "$opt_changes_cnt" -gt 0 ]] && echo "yes" || echo "no" )
  echo "| $m | $status | $moved_cell | ${type_change:-} | $added | $removed | $changed | $partcell |" >> "$summary_md"
done

# Orphans report — only if we can read prod
orphans_md="$ARTIFACT_DIR/orphans.md"
echo "# Orphaned Production Relations" > "$orphans_md"
echo >> "$orphans_md"
echo "_Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")_" >> "$orphans_md"
echo >> "$orphans_md"

# Build coverage set from manifest (prefer prod manifest, else PR manifest)
manifest_for_orphans="$PR_MANIFEST"
if [[ -f "$PROD_MANIFEST" ]]; then
  manifest_for_orphans="$PROD_MANIFEST"
fi

# Helper: coverage keys as dataset.table strings
coverage=$(jq -r '
  def model_key($p): (.schema + "." + ((.alias // .name) // ""));
  def source_key($p): (.schema + "." + ((.identifier // .name) // ""));
  [
    (.nodes | to_entries[] | .value | select(.resource_type=="model") | model_key(.)) ,
    (.sources | to_entries[] | .value | source_key(.))
  ] | flatten | unique | .[]' "$manifest_for_orphans" 2>/dev/null || true)

declare -A covered
while IFS= read -r line; do
  [[ -n "$line" ]] && covered["$line"]=1
done <<< "$coverage"

declare -a orphans
for ds in "${PROD_DATASETS_ARR[@]}"; do
  tables_json=$(bq_table_type "$PROD_PROJECT" "$ds" "__all__" 2>/dev/null || true)
  # If we queried __all__, it will be empty; instead list via INFORMATION_SCHEMA.TABLES
  list_json=$(bq_json "$PROD_PROJECT" "SELECT table_name, table_type FROM \`$PROD_PROJECT.$ds\`.INFORMATION_SCHEMA.TABLES") || true
  if [[ -z "$list_json" ]]; then
    echo "[warn] Could not list tables in $PROD_PROJECT.$ds (no access?)" >> "$orphans_md"
    continue
  fi
  while IFS= read -r name; do
    key="$ds.$name"
    if [[ -z "${covered[$key]:-}" ]]; then
      orphans+=("$PROD_PROJECT.$ds.$name")
    fi
  done < <(echo "$list_json" | jq -r '.[].table_name')
done

echo "Found ${#orphans[@]} orphan(s)." >> "$orphans_md"
if (( ${#orphans[@]} > 0 )); then
  echo "" >> "$orphans_md"
  echo "## Examples" >> "$orphans_md"
  for o in "${orphans[@]:0:50}"; do
    echo "- $o" >> "$orphans_md"
  done
fi

echo "Schema diff reports written to $ARTIFACT_DIR/"
exit 0

