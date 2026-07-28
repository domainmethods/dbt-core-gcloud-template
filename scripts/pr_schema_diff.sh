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
# The manifest path must be passed to jq. Without it jq reads stdin, which is
# empty under CI, so every lookup returned nothing and every model was skipped.
# Model names are only unique within a package, so a name shared with an
# installed package used to emit two concatenated objects and corrupt the SQL.
# Return exactly one node: this project's own model wins, otherwise the first
# match in manifest order.
get_node_by_name() {
  local manifest=$1
  jq -r --arg n "$2" '
    (.metadata.project_name // "") as $proj
    | [ .nodes
        | to_entries[]
        | select(.value.resource_type=="model" and .value.name==$n)
        | .value ]
    | (map(select(.package_name == $proj)) + .)
    | (.[0] // empty)' "$manifest"
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

# Returns 0 if the argument parses as a JSON array.
is_json_array() {
  [[ -n "${1:-}" ]] && printf '%s' "$1" | jq -e 'type=="array"' >/dev/null 2>&1
}

# --- Dataset-wide INFORMATION_SCHEMA cache -------------------------------
#
# The per-model loop asks six questions per model. Asked per model that is
# 6 * N queries (241 at the real CI selection size of 40 models), each one a
# fresh `bq` process plus an API round trip, against a step capped at
# timeout-minutes: 10. Asked per (project, dataset) it is 3 queries per dataset
# — 6 for a typical dev+prod run — regardless of model count.
#
# So: query the whole dataset once, cache the RAW output, and filter per model
# locally with jq. The three helpers below keep their original signatures and
# still echo a JSON array for one table, so the call sites and the status
# classification block are untouched.
#
# Declared initialized. A bare `declare -A` leaves the array unset, and reading
# an unset array under `set -u` is the class of defect this file was fixed for.
# Loaded-ness is tracked separately from content so a genuinely empty result is
# distinguishable from "not fetched yet" — a failed fetch caches as an empty
# string and must NOT be retried per model, or the query volume comes back.
declare -A DS_LOADED=()
declare -A DS_COLS=()
declare -A DS_TBL=()
declare -A DS_OPT=()

ensure_columns_cached() {
  local project=$1 dataset=$2 key="$1.$2"
  if [[ -z "${DS_LOADED[cols:$key]:-}" ]]; then
    DS_LOADED[cols:$key]=1
    DS_COLS[$key]=$(bq_json "$project" "SELECT table_name, column_name, ordinal_position, data_type, is_nullable FROM \`$project.$dataset\`.INFORMATION_SCHEMA.COLUMNS ORDER BY table_name, ordinal_position" || true)
  fi
  return 0
}

ensure_tables_cached() {
  local project=$1 dataset=$2 key="$1.$2"
  if [[ -z "${DS_LOADED[tbl:$key]:-}" ]]; then
    DS_LOADED[tbl:$key]=1
    DS_TBL[$key]=$(bq_json "$project" "SELECT table_name, table_type FROM \`$project.$dataset\`.INFORMATION_SCHEMA.TABLES" || true)
  fi
  return 0
}

ensure_options_cached() {
  local project=$1 dataset=$2 key="$1.$2"
  if [[ -z "${DS_LOADED[opt:$key]:-}" ]]; then
    DS_LOADED[opt:$key]=1
    DS_OPT[$key]=$(bq_json "$project" "SELECT table_name, option_name, option_value FROM \`$project.$dataset\`.INFORMATION_SCHEMA.TABLE_OPTIONS WHERE option_name IN ('partitioning_type','partitioning_field','require_partition_filter','clustering_fields')" || true)
  fi
  return 0
}

# Warms all three blobs for one (project, dataset) pair.
#
# This MUST be called as a plain statement from the shell that owns the cache.
# The helpers below are invoked as `x=$(bq_columns ...)`, i.e. inside command
# substitutions, which are subshells: anything they cache dies with them. A
# lazy load driven only from inside the helpers would therefore never survive a
# single model and the query count would be worse than before batching.
ensure_dataset_cached() {
  local project=$1 dataset=$2
  ensure_columns_cached "$project" "$dataset"
  ensure_tables_cached "$project" "$dataset"
  ensure_options_cached "$project" "$dataset"
  return 0
}

# Filters a cached dataset-wide blob down to one table.
#
# ERROR PASSTHROUGH — the load-bearing part. Status classification reads the
# raw bq output and tests it as a string ("Access Denied", empty, banner text).
# Before batching each model triggered its own query and so saw the failure
# directly. Now the failure happens once, at load time, for the whole dataset.
# A blob that is not a JSON array is therefore handed back VERBATIM to every
# model in that dataset, so each one classifies exactly as it would have. Try
# to jq-filter it instead and jq fails, the helper emits an empty array, and a
# whole dataset's permissions failure turns into a clean OK diff on every row.
ds_filter() {
  local raw=${1:-} ident=$2 projection=$3
  if ! is_json_array "$raw"; then
    printf '%s' "$raw"
    return 0
  fi
  printf '%s' "$raw" | jq -c --arg t "$ident" "[ .[] | select(.table_name == \$t) | $projection ]"
}

bq_columns() {
  local project=$1 dataset=$2 ident=$3
  ensure_columns_cached "$project" "$dataset"
  ds_filter "${DS_COLS[$project.$dataset]:-}" "$ident" \
    '{column_name, ordinal_position, data_type, is_nullable}'
}

bq_table_type() {
  local project=$1 dataset=$2 ident=$3
  ensure_tables_cached "$project" "$dataset"
  ds_filter "${DS_TBL[$project.$dataset]:-}" "$ident" '{table_type}'
}

bq_table_options() {
  local project=$1 dataset=$2 ident=$3
  ensure_options_cached "$project" "$dataset"
  ds_filter "${DS_OPT[$project.$dataset]:-}" "$ident" '{option_name, option_value}'
}

# Raw dataset-wide TABLES listing, for the orphan report.
#
# The orphan block wants exactly what the batched TABLES query already fetched:
# `SELECT table_name, table_type` over the whole dataset. The two are the same
# query, so they deliberately SHARE one cache entry rather than being issued
# twice. Returns the raw blob; the caller does its own guarded parse.
bq_tables_raw() {
  local project=$1 dataset=$2
  ensure_tables_cached "$project" "$dataset"
  printf '%s' "${DS_TBL[$project.$dataset]:-}"
}

# Classifies ONE raw bq result: OK | AUTH_ERROR | NON_JSON.
# Must be called on the raw value, before as_json_array touches it.
classify_raw() {
  local raw=${1:-}
  if [[ -z "$raw" || "$raw" == *"Access Denied"* ]]; then
    echo "AUTH_ERROR"
  elif ! is_json_array "$raw"; then
    echo "NON_JSON"
  else
    echo "OK"
  fi
}

# Echoes the argument if it is a JSON array, otherwise an empty array.
# Apply ONLY where a value is handed to jq. Status classification reads the
# raw bq output, because "Access Denied" is a signal that normalizing destroys.
as_json_array() {
  if is_json_array "${1:-}"; then
    printf '%s' "$1"
  else
    printf '[]'
  fi
}

normalize_options() {
  jq -r '[.[] | {key: .option_name, val: .option_value}] | map({(.key): .val}) | add // {}'
}

compute_column_diff() {
  local dev_json=$1 prod_json=$2
  # `-n` is required: nothing is piped in, so without it jq has zero inputs,
  # runs the filter zero times, and exits 0 having printed nothing.
  jq -n -r --argjson dev "$dev_json" --argjson prod "$prod_json" '
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
  # `-n` is required here for the same reason as in compute_column_diff.
  jq -n -r --arg devt "$dev_type" --arg prodt "$prod_type" --argjson devo "$dev_opts_json" --argjson prodo "$prod_opts_json" '
    def norm($o): {
      partitioning_type: ($o.partitioning_type // null),
      partitioning_field: ($o.partitioning_field // null),
      require_partition_filter: ($o.require_partition_filter // null),
      clustering_fields: ($o.clustering_fields // null)
    };
    (norm($devo)) as $d | (norm($prodo)) as $p |
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

# Movement is a LOGICAL question: did this PR change the model's database,
# schema or alias relative to production? It must therefore compare the PR
# manifest node against the PROD manifest node.
#
# It must NOT compare the physical locations that were introspected: DEV_P/DEV_D
# are deliberately forced to the CI project and the ephemeral CI dataset, so a
# physical comparison differs by construction and reported every model as MOVED
# (measured: 37/37 on a replay of PR #72).
#
# $3 is "true" only when the prod FQN came from a real prod-manifest node. When
# no prod node was found the prod FQN is synthesised from the PR's own
# identifier, so comparing against it would manufacture a confident UNCHANGED
# that was never actually checked. That case is genuinely UNKNOWN.
movement_status() {
  local pr_fqn=$1 prod_fqn=$2 prod_from_manifest=${3:-false}
  if [[ "$prod_from_manifest" != "true" || -z "$prod_fqn" ]]; then echo "UNKNOWN"; return; fi
  if [[ "$pr_fqn" == "$prod_fqn" ]]; then echo "UNCHANGED"; else echo "MOVED"; fi
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

  # Prod node (from prod manifest preferred).
  # prod_from_manifest records whether the prod FQN below is a real observation
  # of production or a fallback synthesised from configuration. Movement is only
  # answerable in the former case.
  prod_fqn_json=""
  prod_from_manifest=false
  if [[ -f "$PROD_MANIFEST" && -n "$pr_uid" && "$pr_uid" != "null" ]]; then
    prod_node=$(get_node_by_uid "$PROD_MANIFEST" "$pr_uid")
    if [[ -z "$prod_node" || "$prod_node" == "null" ]]; then
      # try by name fallback
      prod_node=$(get_node_by_name "$PROD_MANIFEST" "$m")
    fi
    if [[ -n "$prod_node" && "$prod_node" != "null" ]]; then
      prod_fqn_json=$(echo "$prod_node" | node_to_fqn)
      prod_from_manifest=true
    fi
  fi

  if [[ -z "$prod_fqn_json" ]]; then
    # default to configured prod dataset with same identifier
    prod_fqn_json=$(jq -n --arg p "$PROD_PROJECT" --arg d "${PROD_DATASETS_ARR[0]}" --arg t "$pr_ident" '{project:$p,dataset:$d,identifier:$t}')
  fi
  PROD_P=$(echo "$prod_fqn_json" | jq -r .project)
  PROD_D=$(echo "$prod_fqn_json" | jq -r .dataset)
  PROD_T=$(echo "$prod_fqn_json" | jq -r .identifier)

  # Physical relations that are actually introspected below. The dev side is
  # pinned to the ephemeral CI dataset on purpose; these two lines are for
  # debugging the queries, NOT for movement detection.
  dev_fqn_str="$DEV_P.$DEV_D.$DEV_T"
  prod_fqn_str="$PROD_P.$PROD_D.$PROD_T"
  echo "Physical relations queried:" | tee -a "$out"
  echo "Dev:  $dev_fqn_str" | tee -a "$out"
  echo "Prod: $prod_fqn_str" | tee -a "$out"

  # Logical (manifest) locations. Movement compares these.
  pr_logical_fqn="$pr_proj.$pr_ds.$pr_ident"
  prod_logical_fqn=""
  if [[ "$prod_from_manifest" == "true" ]]; then
    prod_logical_fqn="$PROD_P.$PROD_D.$PROD_T"
  fi
  echo "Logical PR:   $pr_logical_fqn" | tee -a "$out"
  echo "Logical prod: ${prod_logical_fqn:-<not in prod manifest>}" | tee -a "$out"

  move=$(movement_status "$pr_logical_fqn" "$prod_logical_fqn" "$prod_from_manifest")
  if [[ "$move" == "MOVED" ]]; then
    echo "Movement: $prod_logical_fqn -> $pr_logical_fqn" | tee -a "$out"
  else
    echo "Movement: $move" | tee -a "$out"
  fi

  # Warm the dataset-wide cache in THIS shell, before the six calls below. Each
  # of those runs inside a command substitution — a subshell — so a cache it
  # populates is discarded the moment it returns. Warming here is what makes the
  # cache survive from one model to the next; without it every model would
  # re-query and batching would buy nothing.
  ensure_dataset_cached "$DEV_P" "$DEV_D"
  ensure_dataset_cached "$PROD_P" "$PROD_D"

  # Introspect
  dev_cols_json=$(bq_columns "$DEV_P" "$DEV_D" "$DEV_T" 2>/dev/null || true)
  prod_cols_json=$(bq_columns "$PROD_P" "$PROD_D" "$PROD_T" 2>/dev/null || true)
  dev_type_json=$(bq_table_type "$DEV_P" "$DEV_D" "$DEV_T" 2>/dev/null || true)
  prod_type_json=$(bq_table_type "$PROD_P" "$PROD_D" "$PROD_T" 2>/dev/null || true)
  dev_opts_json=$(bq_table_options "$DEV_P" "$DEV_D" "$DEV_T" 2>/dev/null || true)
  prod_opts_json=$(bq_table_options "$PROD_P" "$PROD_D" "$PROD_T" 2>/dev/null || true)

  # --- Classify from RAW output. Do not normalize before this block: ---
  # as_json_array would rewrite "Access Denied" to "[]", which is non-empty and
  # no longer matches the substring test, silently downgrading a permissions
  # failure to a clean OK diff.
  #
  # Every value that feeds the diff is classified, on both sides. Classifying
  # only prod columns left two silent downgrades: a denial on the prod TABLES
  # query reported a permissions failure as NEW_MODEL, and a denial on the dev
  # COLUMNS query reported every prod column as removed under status=OK.
  # Table options are deliberately excluded: a zero-row TABLE_OPTIONS result is
  # normal for an unpartitioned table and is not distinguishable from a failure.
  status="OK"
  for raw_result in "$prod_cols_json" "$dev_cols_json" "$prod_type_json" "$dev_type_json"; do
    raw_class=$(classify_raw "$raw_result")
    if [[ "$raw_class" == "AUTH_ERROR" ]]; then
      status="AUTH_ERROR"
      break
    elif [[ "$raw_class" == "NON_JSON" && "$status" == "OK" ]]; then
      status="NON_JSON"
    fi
  done

  # --- Normalize at the jq boundary. ---
  dev_cols=$(as_json_array "${dev_cols_json:-}")
  prod_cols=$(as_json_array "${prod_cols_json:-}")
  dev_type_arr=$(as_json_array "${dev_type_json:-}")
  prod_type_arr=$(as_json_array "${prod_type_json:-}")
  dev_opts_arr=$(as_json_array "${dev_opts_json:-}")
  prod_opts_arr=$(as_json_array "${prod_opts_json:-}")

  # Detect new model (no prod table row). Only reclassify a clean OK status so
  # AUTH_ERROR and NON_JSON are not overwritten.
  prod_type=$(printf '%s' "$prod_type_arr" | jq -r '.[0].table_type // empty')
  if [[ -z "$prod_type" && "$status" == "OK" ]]; then
    status="NEW_MODEL"
  fi
  dev_type=$(printf '%s' "$dev_type_arr" | jq -r '.[0].table_type // empty')

  # Normalize options
  dev_opts=$(printf '%s' "$dev_opts_arr" | normalize_options)
  prod_opts=$(printf '%s' "$prod_opts_arr" | normalize_options)

  # Column diff (skip if auth error and not new model)
  added=0; removed=0; changed=0
  if [[ "$status" == "OK" || "$status" == "NEW_MODEL" ]]; then
    col_diff=$(compute_column_diff "$dev_cols" "$prod_cols")
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
  # Show the LOGICAL move (prod manifest → PR manifest), never the CI dataset.
  moved_cell="$move"
  if [[ "$move" == "MOVED" ]]; then
    moved_cell="$prod_logical_fqn → $pr_logical_fqn"
  fi
  partcell=$( [[ "$opt_changes_cnt" -gt 0 ]] && echo "yes" || echo "no" )
  echo "| $m | $status | $moved_cell | ${type_change:-} | $added | $removed | $changed | $partcell |" >> "$summary_md"
done

# Orphans report — best-effort, never fails CI.
# Isolated in a subshell with relaxed error handling: this is a side report,
# and a failure here must never abort the schema diff for changed models.
orphans_md="$ARTIFACT_DIR/orphans.md"
(
  set +euo pipefail

  echo "# Orphaned Production Relations" > "$orphans_md"
  echo >> "$orphans_md"
  echo "_Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")_" >> "$orphans_md"
  echo >> "$orphans_md"

  # Build coverage set from manifest (prefer prod manifest, else PR manifest)
  manifest_for_orphans="$PR_MANIFEST"
  if [[ -f "$PROD_MANIFEST" ]]; then
    manifest_for_orphans="$PROD_MANIFEST"
  fi

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

  # Explicitly initialized: `declare -a orphans` alone leaves the array unset,
  # and `${#orphans[@]}` on an unset array is an unbound-variable error under
  # `set -u` even on bash 5 (the 4.4 relaxation covers ${a[@]}, not ${#a[@]}).
  declare -a orphans=()
  for ds in "${PROD_DATASETS_ARR[@]}"; do
    # Same query as the batched TABLES fetch, so it reuses that cache entry
    # instead of issuing a duplicate. For a prod dataset the model loop already
    # visited this costs nothing.
    list_json=$(bq_tables_raw "$PROD_PROJECT" "$ds") || true
    if [[ -z "$list_json" ]]; then
      echo "[warn] Could not list tables in $PROD_PROJECT.$ds (no access?)" >> "$orphans_md"
      continue
    fi
    # Guard the parse: bq can emit banner text that is not valid JSON.
    table_names=$(printf '%s' "$list_json" | jq -r '.[].table_name' 2>/dev/null) || true
    if [[ -z "$table_names" ]]; then
      echo "[warn] Could not parse table list for $PROD_PROJECT.$ds" >> "$orphans_md"
      continue
    fi
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      key="$ds.$name"
      if [[ -z "${covered[$key]:-}" ]]; then
        orphans+=("$PROD_PROJECT.$ds.$name")
      fi
    done <<< "$table_names"
  done

  echo "Found ${#orphans[@]} orphan(s)." >> "$orphans_md"
  if (( ${#orphans[@]} > 0 )); then
    echo "" >> "$orphans_md"
    echo "## Examples" >> "$orphans_md"
    for o in "${orphans[@]:0:50}"; do
      echo "- $o" >> "$orphans_md"
    done
  fi
) || echo "[warn] Orphan detection encountered errors; see $orphans_md" >&2

echo "Schema diff reports written to $ARTIFACT_DIR/"
exit 0

