# pr_schema_diff.sh Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `scripts/pr_schema_diff.sh` from aborting CI under `set -u` (issue #53) and repair the `get_node_by_name` defect that has made the per-model schema diff a silent no-op since the repository was created.

**Architecture:** Three surgical edits to one bash script, guarded by a new dependency-free bash test harness that runs the real script against stubbed `bq` and `dbt` binaries placed first on `PATH`. The harness asserts on exit codes and on generated report files. A fourth change hardens the CI step. Validation is downstream-first: this repository has two example models and red CI, so the substantive proof runs against a real ~40-model manifest from `weightcare-pipeline-new`.

**Tech Stack:** bash 4+, jq, GitHub Actions, dbt-core 1.10.8, BigQuery.

**Spec:** `docs/superpowers/specs/2026-07-27-pr-schema-diff-set-u-fix-design.md`

## Global Constraints

- Target shell is bash 4+ (`mapfile` is used). CI is ubuntu-latest with bash 5. Stock macOS bash 3.2 is not supported.
- `scripts/pr_schema_diff.sh` keeps `set -euo pipefail` on line 2. Do not relax it globally.
- Keep `--maximum_bytes_billed=1000000000` on `bq_json`. The downstream fork removed it; that is a regression and must not be copied.
- Keep the `[warn] Could not list tables in ...` diagnostic written into `orphans.md`. The downstream fork dropped it.
- Tests must introduce no new dependency. No bats, no pip packages. Only bash, jq, coreutils.
- **Ordering rule:** status classification reads the raw `bq` output. `as_json_array` is applied only where a value is handed to `jq`. Never normalize before classifying.
- Out of scope, do not touch: `DIFF_SELECT` selection (issue #29), `scripts/drop_bq_dataset.sh` (issue #19), `scripts/pr_data_diff.sh`, query batching.
- Nothing is committed to the upstream `main` branch. All work lands on branch `fix/53-pr-schema-diff-set-u`.
- Tier 3 validation (a real downstream CI run) requires explicit human authorization and is not initiated by the implementer.

## File Structure

| File | Responsibility |
|---|---|
| `tests/test_pr_schema_diff.sh` | **Create.** Whole test harness: assertion helpers, sandbox builder, stub generators, six scenarios, summary. Self-contained so it can be copied for issue #19. |
| `scripts/pr_schema_diff.sh` | **Modify.** Three edits: orphan block (Task 1), `get_node_by_name` (Task 2), status classification and JSON guards (Task 3). |
| `Makefile` | **Modify.** Add `test-scripts` target and add it to `.PHONY`. |
| `.github/workflows/ci.yml` | **Modify.** Add `continue-on-error` to the schema-diff step; add a harness step to the `lint` job. |

The harness is deliberately one file. It is a test fixture, not production code, and keeping the stubs adjacent to the assertions they serve is what makes it copyable to the next `set -u` issue.

---

### Task 1: Test harness + fix the orphan block (issue #53)

Delivers the harness skeleton and scenarios 1-4, then fixes the defect they expose. Scenarios 1-4 all concern the orphan block, so they gate one change.

**Files:**
- Create: `tests/test_pr_schema_diff.sh`
- Modify: `scripts/pr_schema_diff.sh:309-360` (orphan block)

**Interfaces:**
- Consumes: nothing.
- Produces: shell functions later tasks reuse — `make_sandbox <mode>` (sets globals `SANDBOX`, `BQ_CALL_LOG`), `run_diff` (returns the script's exit code, sets `RUN_STDOUT`/`RUN_STDERR`), `assert_eq <expected> <actual> <msg>`, `assert_contains <haystack> <needle> <msg>`, `assert_not_contains <haystack> <needle> <msg>`, `pass <msg>`, `fail <msg>`. Scenario functions are named `scenario_1` .. `scenario_6`.

- [ ] **Step 1: Write the harness with scenarios 1-4**

Create `tests/test_pr_schema_diff.sh`:

```bash
#!/usr/bin/env bash
# Tests for scripts/pr_schema_diff.sh
#
# Dependency-free: requires bash 4+, jq, coreutils. No bats, no pip packages.
# Runs the real script against stubbed `bq` and `dbt` binaries on PATH.
#
# Usage: bash tests/test_pr_schema_diff.sh
#
# Note: `set -e` is deliberately NOT used. The harness inspects non-zero exit
# codes from the script under test; aborting on them would defeat the purpose.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO_ROOT/scripts/pr_schema_diff.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "    ok   - $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "    FAIL - $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

assert_eq() {
  local expected=$1 actual=$2 msg=$3
  if [[ "$expected" == "$actual" ]]; then
    pass "$msg"
  else
    fail "$msg (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local haystack=$1 needle=$2 msg=$3
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$msg"
  else
    fail "$msg (expected to find '$needle')"
  fi
}

assert_not_contains() {
  local haystack=$1 needle=$2 msg=$3
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$msg"
  else
    fail "$msg (did not expect to find '$needle')"
  fi
}

# Fixture manifest: two models in prod dataset `analytics`.
#   fct_example - exists in prod
#   stg_example - has no prod counterpart, so exercises NEW_MODEL
write_manifest() {
  cat > "$1" <<'JSON'
{
  "nodes": {
    "model.tpl.fct_example": {
      "resource_type": "model", "name": "fct_example", "alias": "fct_example",
      "database": "prodproj", "schema": "analytics",
      "unique_id": "model.tpl.fct_example"
    },
    "model.tpl.stg_example": {
      "resource_type": "model", "name": "stg_example", "alias": "stg_example",
      "database": "prodproj", "schema": "analytics",
      "unique_id": "model.tpl.stg_example"
    }
  },
  "sources": {}
}
JSON
}

# Builds an isolated sandbox and sets SANDBOX and BQ_CALL_LOG.
# $1 selects stub behaviour, consumed by the bq stub via STUB_MODE.
make_sandbox() {
  local mode=$1
  SANDBOX=$(mktemp -d)
  STUB_MODE=$mode
  BQ_CALL_LOG="$SANDBOX/bq_calls.log"
  mkdir -p "$SANDBOX/stubs" "$SANDBOX/target" "$SANDBOX/prod_state" "$SANDBOX/out"
  : > "$BQ_CALL_LOG"

  write_manifest "$SANDBOX/target/manifest.json"
  write_manifest "$SANDBOX/prod_state/manifest.json"

  cat > "$SANDBOX/stubs/dbt" <<'STUB'
#!/usr/bin/env bash
# Only `dbt ls` is exercised; every other subcommand is a no-op success.
if [[ "${1:-}" == "ls" ]]; then
  printf 'fct_example\nstg_example\n'
fi
exit 0
STUB

  cat > "$SANDBOX/stubs/bq" <<'STUB'
#!/usr/bin/env bash
# Stub BigQuery CLI. Records every invocation, then answers based on the
# shape of the SQL and on STUB_MODE.
args="$*"
echo "$args" >> "$BQ_CALL_LOG"

DEV_COLS='[{"column_name":"id","ordinal_position":1,"data_type":"INT64","is_nullable":"YES"},{"column_name":"amount","ordinal_position":2,"data_type":"NUMERIC","is_nullable":"YES"}]'
PROD_COLS='[{"column_name":"id","ordinal_position":1,"data_type":"INT64","is_nullable":"YES"}]'

case "$args" in
  *TABLE_OPTIONS*)
    echo '[]' ;;

  *INFORMATION_SCHEMA.COLUMNS*)
    if [[ "$STUB_MODE" == "banner_introspect" ]]; then
      echo 'Welcome to BigQuery! Update available.'
    elif [[ "$args" == *ci_pr_1* ]]; then
      echo "$DEV_COLS"
    elif [[ "$args" == *"table_name = 'fct_example'"* ]]; then
      echo "$PROD_COLS"
    else
      echo '[]'
    fi ;;

  *"INFORMATION_SCHEMA.TABLES WHERE"*)
    if [[ "$args" == *ci_pr_1* ]]; then
      echo '[{"table_type":"BASE TABLE"}]'
    elif [[ "$args" == *"table_name = 'fct_example'"* ]]; then
      echo '[{"table_type":"BASE TABLE"}]'
    else
      echo '[]'
    fi ;;

  *INFORMATION_SCHEMA.TABLES*)
    # Dataset-wide table listing, used only by the orphan block.
    case "$STUB_MODE" in
      denied)        echo 'BigQuery error: Access Denied' >&2; exit 1 ;;
      has_orphan)    echo '[{"table_name":"legacy_junk","table_type":"BASE TABLE"}]' ;;
      banner_tables) echo 'Welcome to BigQuery! Update available.' ;;
      *)             echo '[{"table_name":"fct_example","table_type":"BASE TABLE"}]' ;;
    esac ;;

  *)
    echo '[]' ;;
esac
exit 0
STUB

  chmod +x "$SANDBOX/stubs/bq" "$SANDBOX/stubs/dbt"
}

# Runs the script under test inside the sandbox. Returns its exit code and
# sets RUN_STDOUT / RUN_STDERR. stdin is closed to mimic GitHub Actions.
run_diff() {
  local rc
  RUN_STDOUT=$(
    cd "$SANDBOX" || exit 99
    PATH="$SANDBOX/stubs:$PATH" \
    STUB_MODE="$STUB_MODE" \
    BQ_CALL_LOG="$BQ_CALL_LOG" \
    DBT_GCP_PROJECT_CI=ciproj \
    DBT_BQ_DATASET=ci_pr_1 \
    DBT_GCP_PROJECT_PROD=prodproj \
    DBT_BQ_DATASET_PROD=analytics \
    ARTIFACT_DIR="$SANDBOX/out" \
      bash "$SCRIPT" 2>"$SANDBOX/stderr.txt" </dev/null
  )
  rc=$?
  RUN_STDERR=$(cat "$SANDBOX/stderr.txt")
  return $rc
}

cleanup() { [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"; }

scenario_1() {
  echo "  scenario 1: zero orphans (every prod table covered by the manifest)"
  make_sandbox ok_no_orphans
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0 when no orphans are found"
  assert_contains "$(cat "$SANDBOX/out/orphans.md")" "Found 0 orphan(s)." "reports zero orphans"
  cleanup
}

scenario_2() {
  echo "  scenario 2: prod dataset unreadable"
  make_sandbox denied
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0 when the prod dataset cannot be listed"
  assert_contains "$(cat "$SANDBOX/out/orphans.md")" "Could not list tables" \
    "keeps the unreadable-dataset diagnostic in orphans.md"
  cleanup
}

scenario_3() {
  echo "  scenario 3: an orphan is present"
  make_sandbox has_orphan
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0 when an orphan is found"
  local report; report=$(cat "$SANDBOX/out/orphans.md")
  assert_contains "$report" "Found 1 orphan(s)." "counts the orphan"
  assert_contains "$report" "prodproj.analytics.legacy_junk" "names the orphan"
  cleanup
}

scenario_4() {
  echo "  scenario 4: bq returns a non-JSON banner for the table listing"
  make_sandbox banner_tables
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0 when the table listing is unparseable"
  cleanup
}

echo "test_pr_schema_diff.sh"
scenario_1
scenario_2
scenario_3
scenario_4

echo ""
echo "passed: $PASS_COUNT  failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
```

- [ ] **Step 2: Run the harness to verify scenarios 1, 2 and 4 fail**

Run: `bash tests/test_pr_schema_diff.sh`

Expected: FAIL. Scenarios 1, 2 and 4 report `exits 0 ... (expected '0', got '1')`, and stderr from the script contains `line 353: orphans: unbound variable`. Scenario 3 passes, because that is the only path where `orphans` gets assigned.

This asymmetry is the bug: a clean prod dataset fails, a messy one passes.

- [ ] **Step 3: Fix the orphan block**

In `scripts/pr_schema_diff.sh`, replace everything from the `# Orphans report — only if we can read prod` comment (line 309) through the closing `fi` of the orphan examples block (line 360) with:

```bash
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
    list_json=$(bq_json "$PROD_PROJECT" "SELECT table_name, table_type FROM \`$PROD_PROJECT.$ds\`.INFORMATION_SCHEMA.TABLES") || true
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
```

Four changes are folded in here: the array is initialized, the `jq` parse is captured and guarded, the `< <(echo | jq)` process substitution becomes a `<<<` herestring, and the dead `tables_json=$(bq_table_type "$PROD_PROJECT" "$ds" "__all__" ...)` call is deleted — its result was never read and it issued a real BigQuery query on every run.

- [ ] **Step 4: Run the harness to verify scenarios 1-4 pass**

Run: `bash tests/test_pr_schema_diff.sh`

Expected: PASS. `passed: 8  failed: 0`.

- [ ] **Step 5: Verify the dead query is gone**

Run: `grep -c '__all__' scripts/pr_schema_diff.sh`

Expected: `0`.

- [ ] **Step 6: Commit**

```bash
git add tests/test_pr_schema_diff.sh scripts/pr_schema_diff.sh
git commit -m "fix(ci): stop schema diff aborting on uninitialized orphans array (#53)

\`declare -a orphans\` left the array unset, and \`\${#orphans[@]}\` on an unset
array is an unbound-variable error under \`set -u\` even on bash 5. The array is
only assigned inside the \`orphans+=()\` branch, so the script survived only when
at least one orphan existed: a clean prod dataset failed CI, a messy one passed.

Initializes the array, guards the jq parse against non-JSON bq output, replaces
the process substitution with a herestring, and isolates the whole block in a
subshell so this best-effort side report can never abort the core diff. Also
drops a dead bq_table_type '__all__' call that issued a real query per run.

Adds tests/test_pr_schema_diff.sh, the repo's first shell test harness."
```

---

### Task 2: Fix `get_node_by_name` — the silent no-op

**Files:**
- Modify: `tests/test_pr_schema_diff.sh` (add `scenario_5`, register it)
- Modify: `scripts/pr_schema_diff.sh:76-83`

**Interfaces:**
- Consumes: `make_sandbox`, `run_diff`, `assert_eq`, `assert_contains`, `assert_not_contains` from Task 1.
- Produces: `scenario_5`.

- [ ] **Step 1: Write the failing test**

In `tests/test_pr_schema_diff.sh`, add this function immediately after `scenario_4`:

```bash
scenario_5() {
  echo "  scenario 5: regression guard — models actually resolve (Defect B)"
  make_sandbox ok_no_orphans
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0"

  # Every model returned by `dbt ls` must produce exactly one summary row and
  # zero resolution warnings. Models with no prod counterpart satisfy the row
  # requirement with status NEW_MODEL; the assertion is on row count and
  # warning absence, not on status value.
  assert_not_contains "$RUN_STDOUT" "Could not resolve model" \
    "no model fails to resolve in the PR manifest"

  local summary rows
  summary=$(cat "$SANDBOX/out/schema-summary.md")
  rows=$(grep -c '^| [a-z]' <<< "$summary")
  assert_eq 2 "$rows" "summary table has one row per selected model"
  assert_contains "$summary" "fct_example" "fct_example appears in the summary"
  assert_contains "$summary" "stg_example" "stg_example appears in the summary"
  assert_contains "$summary" "NEW_MODEL" "model with no prod counterpart is NEW_MODEL"
  cleanup
}
```

Register it by changing the scenario invocation list near the bottom of the file from:

```bash
scenario_4
```

to:

```bash
scenario_4
scenario_5
```

- [ ] **Step 2: Run the harness to verify scenario 5 fails**

Run: `bash tests/test_pr_schema_diff.sh`

Expected: FAIL. Scenario 5 reports `no model fails to resolve in the PR manifest (did not expect to find 'Could not resolve model')` and `summary table has one row per selected model (expected '2', got '0')`. Scenarios 1-4 still pass.

- [ ] **Step 3: Fix `get_node_by_name`**

In `scripts/pr_schema_diff.sh`, replace lines 76-83:

```bash
# Helper: get model node JSON from manifest by name
get_node_by_name() {
  local manifest=$1 name=$2
  jq -r --arg n "$2" '
    .nodes 
    | to_entries[]
    | select(.value.resource_type=="model" and .value.name==$n)
    | .value'
}
```

with:

```bash
# Helper: get model node JSON from manifest by name
# The manifest path must be passed to jq. Without it jq reads stdin, which is
# empty under CI, so every lookup returned nothing and every model was skipped.
get_node_by_name() {
  local manifest=$1
  jq -r --arg n "$2" '
    .nodes
    | to_entries[]
    | select(.value.resource_type=="model" and .value.name==$n)
    | .value' "$manifest"
}
```

Two changes: `"$manifest"` is passed to `jq`, and the unused `name` local is dropped since the body reads `$2` directly.

- [ ] **Step 4: Run the harness to verify all scenarios pass**

Run: `bash tests/test_pr_schema_diff.sh`

Expected: PASS. `passed: 14  failed: 0`.

- [ ] **Step 5: Record the bq invocation count**

Run:

```bash
bash -c '
SANDBOX=$(mktemp -d); export SANDBOX
source /dev/stdin <<< "$(sed -n "/^make_sandbox()/,/^}/p;/^write_manifest()/,/^}/p" tests/test_pr_schema_diff.sh)"
make_sandbox ok_no_orphans
cd "$SANDBOX" && PATH="$SANDBOX/stubs:$PATH" STUB_MODE=ok_no_orphans BQ_CALL_LOG="$BQ_CALL_LOG" \
  DBT_GCP_PROJECT_CI=ciproj DBT_BQ_DATASET=ci_pr_1 DBT_GCP_PROJECT_PROD=prodproj \
  DBT_BQ_DATASET_PROD=analytics ARTIFACT_DIR="$SANDBOX/out" \
  bash '"$PWD"'/scripts/pr_schema_diff.sh >/dev/null 2>&1 </dev/null
echo "bq invocations for 2 models: $(wc -l < "$BQ_CALL_LOG")"
rm -rf "$SANDBOX"'
```

Expected: `13` — six per model plus one dataset listing. Write this number into the commit message. It is the input to the batching decision deferred in the spec.

- [ ] **Step 6: Commit**

```bash
git add tests/test_pr_schema_diff.sh scripts/pr_schema_diff.sh
git commit -m "fix(ci): pass manifest path to jq in get_node_by_name

get_node_by_name bound \`local manifest=\$1\` but never passed \"\$manifest\" to
jq, so jq read stdin — empty under CI — and returned nothing. That function
gates the per-model loop, so every model hit 'Could not resolve model X in PR
manifest; skipping' and the summary table was emitted with a header and no
rows. The per-model schema diff has never produced output, here or in the
downstream fork. get_node_by_uid immediately below it passes the path
correctly; the omission was isolated to this one helper.

Measured cost of activating the loop: 6 bq invocations per model (13 total for
the 2-model fixture). Batching is deferred per the design doc."
```

---

### Task 3: Guard the newly reachable path

Fixing Task 2 activates roughly 60 lines that have never executed. `jq --argjson` hard-fails on non-JSON, and under `set -e` that aborts the script. The guard must not disturb status classification, which reads the raw string.

**Files:**
- Modify: `tests/test_pr_schema_diff.sh` (add `scenario_6`, register it)
- Modify: `scripts/pr_schema_diff.sh` (add helpers near `normalize_options`; rework lines 254-273)

**Interfaces:**
- Consumes: `make_sandbox`, `run_diff`, `assert_eq`, `assert_contains`, `assert_not_contains` from Task 1.
- Produces: `scenario_6`; shell functions `is_json_array <string>` (returns 0 if the argument parses as a JSON array) and `as_json_array <string>` (echoes the argument if it is a JSON array, otherwise `[]`).

- [ ] **Step 1: Write the failing test**

In `tests/test_pr_schema_diff.sh`, add after `scenario_5`:

```bash
scenario_6() {
  echo "  scenario 6: bq returns a non-JSON banner for column introspection"
  make_sandbox banner_introspect
  run_diff; local rc=$?
  assert_eq 0 "$rc" "exits 0 when introspection output is unparseable"

  # The requirement is that unparseable output is never reported as a clean
  # diff. The exact status string is pinned here once observed.
  local summary; summary=$(cat "$SANDBOX/out/schema-summary.md")
  assert_contains "$summary" "NON_JSON" "unparseable introspection is marked NON_JSON"
  cleanup
}
```

Register it by changing `scenario_5` in the invocation list to:

```bash
scenario_5
scenario_6
```

- [ ] **Step 2: Run the harness to verify scenario 6 fails**

Run: `bash tests/test_pr_schema_diff.sh`

Expected: FAIL. Scenario 6 reports a non-zero exit code, and stderr contains a `jq: error` about invalid JSON text passed to `--argjson`. Scenarios 1-5 still pass.

- [ ] **Step 3: Add the JSON helpers**

In `scripts/pr_schema_diff.sh`, insert immediately before the `normalize_options()` definition:

```bash
# Returns 0 if the argument parses as a JSON array.
is_json_array() {
  [[ -n "${1:-}" ]] && printf '%s' "$1" | jq -e 'type=="array"' >/dev/null 2>&1
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
```

- [ ] **Step 4: Rework status classification and normalization**

Replace lines 254-268 (from `status="OK"` through the two `prod_opts=` / `dev_opts=` assignments) with:

```bash
  # --- Classify from RAW output. Do not normalize before this block: ---
  # as_json_array would rewrite "Access Denied" to "[]", which is non-empty and
  # no longer matches the substring test, silently downgrading a permissions
  # failure to a clean OK diff.
  status="OK"
  if [[ -z "$prod_cols_json" || "$prod_cols_json" == *"Access Denied"* ]]; then
    status="AUTH_ERROR"
  elif ! is_json_array "$prod_cols_json"; then
    status="NON_JSON"
  fi

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
```

Then change the column-diff call on the following line from:

```bash
    col_diff=$(compute_column_diff "${dev_cols_json:-[]}" "${prod_cols_json:-[]}")
```

to:

```bash
    col_diff=$(compute_column_diff "$dev_cols" "$prod_cols")
```

`AUTH_ERROR` and `NON_JSON` rows skip the column diff, so `added`/`removed`/`changed` stay at their initialized `0`, satisfying the spec's requirement that `NON_JSON` rows appear with zero column counts.

Note the original `NEW_MODEL` condition was `"$status" != "AUTH_ERROR"`; tightening it to `== "OK"` is what stops a `NON_JSON` row being relabelled `NEW_MODEL`.

- [ ] **Step 5: Run the harness to verify all scenarios pass**

Run: `bash tests/test_pr_schema_diff.sh`

Expected: PASS. `passed: 16  failed: 0`.

If scenario 6 reports a status other than `NON_JSON`, do not weaken the assertion — the classification block above is wrong and should be corrected until it emits `NON_JSON`.

- [ ] **Step 6: Confirm no stale references remain**

Run: `grep -n 'cols_json:-\[\]\|dev_opts_json:-\[\]\|prod_opts_json:-\[\]' scripts/pr_schema_diff.sh`

Expected: no output. All jq consumers now read the normalized variables.

- [ ] **Step 7: Commit**

```bash
git add tests/test_pr_schema_diff.sh scripts/pr_schema_diff.sh
git commit -m "fix(ci): guard non-JSON bq output in the per-model schema diff

Fixing get_node_by_name activated ~60 lines that had never executed. Those
lines pass bq output to jq --argjson, which hard-fails on non-JSON, aborting
the script under set -e whenever bq emits banner or error text.

Adds is_json_array/as_json_array and a NON_JSON status. Classification reads
the raw output and normalization happens only at the jq boundary: normalizing
first would rewrite 'Access Denied' to '[]', which no longer matches the
substring test, silently downgrading a permissions failure to a clean OK diff.
NEW_MODEL detection is tightened to only reclassify an OK status so it cannot
mask AUTH_ERROR or NON_JSON."
```

---

### Task 4: Wire the harness into Make and CI, and harden the CI step

**Files:**
- Modify: `Makefile:1` (`.PHONY`) and append a target
- Modify: `.github/workflows/ci.yml` (lint job; schema-diff step)

**Interfaces:**
- Consumes: `tests/test_pr_schema_diff.sh` from Tasks 1-3.
- Produces: `make test-scripts`.

- [ ] **Step 1: Add the Makefile target**

Change line 1 of `Makefile` from:

```make
.PHONY: init deps build test lint lint-fix docs compare clean freshness
```

to:

```make
.PHONY: init deps build test test-scripts lint lint-fix docs compare clean freshness
```

Then add after the existing `test:` target (which ends with the `dbt test` line):

```make
# Shell script tests. No warehouse connection, no credentials, no cost.
test-scripts:
	bash tests/test_pr_schema_diff.sh
```

Use a real tab for the recipe line, not spaces.

- [ ] **Step 2: Verify the target runs**

Run: `make test-scripts`

Expected: PASS, `passed: 16  failed: 0`.

- [ ] **Step 3: Add the harness to the CI lint job**

In `.github/workflows/ci.yml`, in the `lint` job, insert this step immediately after the `- uses: actions/checkout@v5` step and before `- uses: actions/setup-python@v5`:

```yaml
      - name: Test shell scripts
        run: bash tests/test_pr_schema_diff.sh
```

It goes in `lint` rather than `bigquery-ci` because the harness needs no GCP credentials and runs in seconds, so it fails fast before the expensive job starts.

- [ ] **Step 4: Harden the schema-diff step**

In the `bigquery-ci` job, change:

```yaml
      - name: Generate schema diffs for changed models
        if: ${{ steps.dbt_build.outcome == 'success' }}
        run: bash scripts/pr_schema_diff.sh
```

to:

```yaml
      - name: Generate schema diffs for changed models
        if: ${{ steps.dbt_build.outcome == 'success' }}
        continue-on-error: true
        run: bash scripts/pr_schema_diff.sh
```

This is defence in depth. Task 1 removes the known failure; this prevents the class, and matches the `continue-on-error` already on the neighbouring docs-generate and artifact-upload steps.

- [ ] **Step 5: Validate the workflow YAML parses**

Run: `python3 -c "import yaml,sys; d=yaml.safe_load(open('.github/workflows/ci.yml')); print('lint steps:', len(d['jobs']['lint']['steps'])); print('schema step continue-on-error:', [s.get('continue-on-error') for s in d['jobs']['bigquery-ci']['steps'] if 'schema diff' in str(s.get('name','')).lower()])"`

Expected: `lint steps: 5` and `schema step continue-on-error: [True]`.

- [ ] **Step 6: Commit**

```bash
git add Makefile .github/workflows/ci.yml
git commit -m "ci: run shell tests in the lint job, harden the schema-diff step

Adds \`make test-scripts\` and runs the harness in the lint job, where it needs
no GCP credentials and fails fast before the expensive bigquery-ci job.

Adds continue-on-error to the schema-diff step. Its neighbours already have it;
without it a non-zero exit from a best-effort reporting step fails the whole PR
build, which is what made #53 severe rather than cosmetic."
```

---

### Task 5: Tier 2 validation against a real downstream manifest

The stub fixture has two models. This tier runs the fixed script against a real ~40-model manifest to prove the Task 2 fix at realistic scale and to produce the true `bq` invocation count. No credentials, no BigQuery spend, no production impact.

**Files:**
- Create: `docs/superpowers/specs/2026-07-27-tier2-validation-results.md`
- Modify: none

**Interfaces:**
- Consumes: the fixed `scripts/pr_schema_diff.sh` and the stub generators in `tests/test_pr_schema_diff.sh`.
- Produces: a recorded model count, `bq` invocation count, and extrapolated query total for the batching decision.

- [ ] **Step 1: Clone the downstream repository into the scratchpad**

```bash
WORK=$(mktemp -d)
git clone --depth 1 https://github.com/jasonbhart/weightcare-pipeline-new.git "$WORK/wc"
echo "$WORK"
```

The repository is ~8.7MB. If the clone fails on authentication, stop and report — do not attempt to work around it.

- [ ] **Step 2: Generate a real manifest offline**

```bash
cd "$WORK/wc"
python3 -m venv .venv && . .venv/bin/activate
pip install -q "dbt-core==1.10.8" "dbt-bigquery==1.10.1"
dbt deps
DBT_PROFILES_DIR=./profiles DBT_TARGET=ci \
DBT_GCP_PROJECT_CI=offline-parse DBT_BQ_DATASET=offline_parse DBT_BQ_LOCATION=US \
  dbt parse
ls -la target/manifest.json
```

`dbt parse` builds the manifest from source files without contacting BigQuery. If it insists on a connection, fall back to `dbt ls --output name` with the same env vars, which also materialises `target/manifest.json`.

- [ ] **Step 3: Run the fixed script against the real manifest**

```bash
TPL="/Volumes/AnmolxHDD/Anmol/Macbook Pro Backup/Documents/GitHub/dbt-core-gcloud-template"
mkdir -p "$WORK/run/stubs" "$WORK/run/out"
cp "$WORK/wc/target/manifest.json" "$WORK/run/manifest-real.json"
mkdir -p "$WORK/run/target" "$WORK/run/prod_state"
cp "$WORK/run/manifest-real.json" "$WORK/run/target/manifest.json"
cp "$WORK/run/manifest-real.json" "$WORK/run/prod_state/manifest.json"

# Stubs mirror the harness, but drive `dbt ls` from the real manifest so the
# model list matches production rather than the two-model fixture.
cat > "$WORK/run/stubs/dbt" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "ls" ]]; then
  jq -r '.nodes | to_entries[] | .value | select(.resource_type=="model") | .name' \
    "$REAL_MANIFEST"
fi
exit 0
EOF

cat > "$WORK/run/stubs/bq" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$BQ_CALL_LOG"
case "$*" in
  *TABLE_OPTIONS*) echo '[]' ;;
  *INFORMATION_SCHEMA.COLUMNS*) echo '[{"column_name":"id","ordinal_position":1,"data_type":"INT64","is_nullable":"YES"}]' ;;
  *"INFORMATION_SCHEMA.TABLES WHERE"*) echo '[{"table_type":"BASE TABLE"}]' ;;
  *INFORMATION_SCHEMA.TABLES*) echo '[]' ;;
  *) echo '[]' ;;
esac
exit 0
EOF
chmod +x "$WORK/run/stubs/bq" "$WORK/run/stubs/dbt"

cd "$WORK/run"
: > "$WORK/run/bq_calls.log"
PATH="$WORK/run/stubs:$PATH" \
REAL_MANIFEST="$WORK/run/manifest-real.json" \
BQ_CALL_LOG="$WORK/run/bq_calls.log" \
DBT_GCP_PROJECT_CI=ciproj DBT_BQ_DATASET=ci_pr_1 \
DBT_GCP_PROJECT_PROD=prodproj DBT_BQ_DATASET_PROD=dbt_pipeline \
ARTIFACT_DIR="$WORK/run/out" \
  bash "$TPL/scripts/pr_schema_diff.sh" > "$WORK/run/stdout.txt" 2>"$WORK/run/stderr.txt" </dev/null
echo "exit: $?"
```

- [ ] **Step 4: Assert the results**

```bash
echo "models selected : $(PATH="$WORK/run/stubs:$PATH" REAL_MANIFEST="$WORK/run/manifest-real.json" dbt ls | wc -l)"
echo "unresolved      : $(grep -c 'Could not resolve model' "$WORK/run/stdout.txt" || true)"
echo "summary rows    : $(grep -c '^| [a-z]' "$WORK/run/out/schema-summary.md" || true)"
echo "bq invocations  : $(wc -l < "$WORK/run/bq_calls.log")"
```

Expected: exit `0`; `unresolved` is `0`; `summary rows` equals `models selected`; `bq invocations` is approximately `6 × models + 1`.

If `unresolved` is greater than zero, the Task 2 fix does not hold against a real manifest. Stop and report rather than adjusting the assertion.

- [ ] **Step 5: Record the results**

Create `docs/superpowers/specs/2026-07-27-tier2-validation-results.md` with the four measured numbers, the extrapolated wall-clock at an assumed 2-6 seconds per `bq` invocation, and a one-line recommendation on whether the deferred batching work is warranted. Recommend batching if the extrapolated addition exceeds five minutes.

- [ ] **Step 6: Clean up and commit**

```bash
rm -rf "$WORK"
git add docs/superpowers/specs/2026-07-27-tier2-validation-results.md
git commit -m "docs: Tier 2 validation results against a real downstream manifest

Runs the fixed script against weightcare-pipeline-new's real manifest with
stubbed bq. Records model count, resolution failures, summary row count and
measured bq invocations, and makes a batching recommendation from the
extrapolated wall-clock. No credentials, no BigQuery spend."
```

---

## Stopping point

Tasks 1-5 complete the work that can be done without spending money or touching a production project.

**Do not proceed past this point without explicit human authorization.** The remaining spec items are:

- **Tier 3** — a draft PR on `jasonbhart/weightcare-pipeline-new` triggering its real `bigquery-ci` job. Costs real BigQuery spend against a production GCP project, takes ~17 minutes, and is visible to the repository owner. Access is push, not admin.
- **Upstream PR** — open against `domainmethods/dbt-core-gcloud-template`, closing issue #53 and citing the Tier 2 and Tier 3 results.
- **New upstream issue** for Defect B, cross-referencing #53, carrying the evidence from the design document.
- **Downstream PR** — Tasks 2 and 3 only, since `weightcare-pipeline-new` already has the Task 1 fix. Opened for the owner's review, never merged unilaterally.

Report the Tier 2 numbers and ask which of these to proceed with.
