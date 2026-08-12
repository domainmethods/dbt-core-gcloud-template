# Template Build-Selection Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the template build git-diff-scoped so build and diff use the same selector, by emitting `BUILD_SELECT`/`NEEDS_FALLBACK` from `get_changed_models.sh` and rewriting `ci_build.sh`'s build tiers.

**Architecture:** Two tasks. Task 1 (producer): `get_changed_models.sh` tracks model/seed/snapshot nodes and emits `BUILD_SELECT` (= `DIFF_SELECT`) and `NEEDS_FALLBACK`, self-exported to `$GITHUB_ENV`. Task 2 (consumer): `ci_build.sh` builds git-diff-scoped (`BUILD_SELECT` + `--defer`), falling back to `state:modified+` only for macro/config/yaml-only changes, and only when a prod manifest exists.

**Tech Stack:** GitHub Actions, bash, dbt-core 1.10.8 / dbt-bigquery 1.10.1, BigQuery. Dependency-free shell test harnesses (bash 4+, coreutils, real throwaway git repos), same pattern as the existing `tests/test_get_changed_models.sh` / `tests/test_ci_build.sh`.

## Global Constraints

- dbt-core **1.10.8** / dbt-bigquery **1.10.1** — no flags newer than 1.10. `--exclude-resource-type test` and space-unioned `--select "a+ state:modified+"` are valid at this floor.
- Shell tests dependency-free: bash 4+, coreutils only; stub `dbt`/`gsutil` on `PATH`; do **not** use `set -e` in the harness; build real throwaway git repos for `get_changed_models` fixtures.
- Template repo only (`dbt-core-gcloud-template`). Do **not** modify `macros/compare_dev_prod.sql`, `scripts/compare_template.sql`, `scripts/pr_data_diff.sh`, or `scripts/pr_schema_diff.sh`.
- Preserve `ci_build.sh`'s `--exclude-resource-type test` on every build and the `export_ci_select_defer` / `CI_SELECT` / `CI_DEFER` contract (consumed by the non-blocking `dbt test` step).
- Commit messages neutral, conventional-commit; no co-author or AI-assistant trailers.
- Emitted `BUILD_SELECT` and `DIFF_SELECT` are **identical** values (`name+` per changed node).

---

### Task 1: `get_changed_models.sh` emits `BUILD_SELECT` + `NEEDS_FALLBACK`

**Files:**
- Modify: `scripts/get_changed_models.sh` (detection loop + derivation + emit/export, ~lines 21-64)
- Modify: `tests/test_get_changed_models.sh` (add/adjust scenarios)

**Interfaces:**
- Produces (stdout + `$GITHUB_ENV`): `HAS_MODEL_CHANGES`, `DIFF_SELECT`, **`BUILD_SELECT`** (= `DIFF_SELECT`), **`NEEDS_FALLBACK`**; plus `CHANGED_MODELS` (now = all changed buildable node names) to stdout/`$GITHUB_OUTPUT`.
- `BUILD_SELECT`/`DIFF_SELECT` = space-separated `name+` for each changed model `.sql` / seed `.csv` / snapshot `.sql`. Empty for docs-only or macro/config-only changes.
- `NEEDS_FALLBACK=true` iff a `macros/**/*.sql` or `dbt_project.yml`/`packages.yml` changed, OR a `models/**/*.yml`/`*.yaml` changed with no node in `CHANGED_MODELS`.

- [ ] **Step 1: Update the tests to assert the new outputs (RED)**

In `tests/test_get_changed_models.sh`, keep the existing helper/fixtures (real throwaway git repo per scenario). Add/adjust scenarios so each asserts on the script's emitted `BUILD_SELECT=`/`NEEDS_FALLBACK=`/`DIFF_SELECT=` lines:

```bash
echo "scenario: one model .sql → BUILD_SELECT=name+, DIFF_SELECT=name+, NEEDS_FALLBACK=false"
# commit base, then add models/marts/fct_a.sql on the branch; run script
assert_contains "$RUN_OUT" "BUILD_SELECT=fct_a+"
assert_contains "$RUN_OUT" "DIFF_SELECT=fct_a+"
assert_contains "$RUN_OUT" "NEEDS_FALLBACK=false"

echo "scenario: seed .csv → BUILD_SELECT/DIFF_SELECT include seed+"
# add seeds/my_seed.csv
assert_contains "$RUN_OUT" "BUILD_SELECT=my_seed+"
assert_contains "$RUN_OUT" "NEEDS_FALLBACK=false"

echo "scenario: snapshot .sql → include snap+"
# add snapshots/snap_a.sql
assert_contains "$RUN_OUT" "BUILD_SELECT=snap_a+"

echo "scenario: macro-only → NEEDS_FALLBACK=true, BUILD_SELECT empty, HAS_MODEL_CHANGES=true"
# add macros/my_macro.sql
assert_contains "$RUN_OUT" "HAS_MODEL_CHANGES=true"
assert_contains "$RUN_OUT" "NEEDS_FALLBACK=true"
assert_contains "$RUN_OUT" "BUILD_SELECT="     # empty value → line is exactly 'BUILD_SELECT='
assert_not_contains "$RUN_ENV" "BUILD_SELECT=."  # no non-empty token exported

echo "scenario: dbt_project.yml-only → NEEDS_FALLBACK=true, BUILD_SELECT empty"
assert_contains "$RUN_OUT" "NEEDS_FALLBACK=true"

echo "scenario: models/*.yml-only (no sql) → NEEDS_FALLBACK=true, BUILD_SELECT empty"
# add models/marts/schema.yml only
assert_contains "$RUN_OUT" "NEEDS_FALLBACK=true"

echo "scenario: macro + model together → NEEDS_FALLBACK=true, BUILD_SELECT=name+"
# add macros/m.sql AND models/marts/fct_a.sql
assert_contains "$RUN_OUT" "NEEDS_FALLBACK=true"
assert_contains "$RUN_OUT" "BUILD_SELECT=fct_a+"

echo "scenario: docs-only (README) → all empty, HAS_MODEL_CHANGES=false"
assert_contains "$RUN_OUT" "HAS_MODEL_CHANGES=false"
assert_contains "$RUN_OUT" "NEEDS_FALLBACK=false"
```

Use the file's existing runner (the variable it captures stdout into, and the `$GITHUB_ENV` capture) — read the current file first and reuse its exact helper names; the snippet above uses `RUN_OUT`/`RUN_ENV` as placeholders for whatever the harness already uses.

- [ ] **Step 2: Run to confirm RED**

Run: `bash tests/test_get_changed_models.sh`
Expected: FAIL on the new `BUILD_SELECT`/`NEEDS_FALLBACK` assertions (script emits neither today).

- [ ] **Step 3: Rewrite the detection + derivation block in `scripts/get_changed_models.sh`**

Replace the detection loop and DIFF_SELECT derivation (current lines ~21-48) with:

```bash
# Categorize changed files; collect buildable node names (models, seeds, snapshots).
HAS_MODEL_CHANGES=false
CHANGED_NODES=""
MACRO_OR_CONFIG=false
YAML_CHANGED=false

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  case "$file" in
    models/*.sql)
      HAS_MODEL_CHANGES=true
      CHANGED_NODES="${CHANGED_NODES} $(basename "$file" .sql)" ;;
    seeds/*.csv)
      HAS_MODEL_CHANGES=true
      CHANGED_NODES="${CHANGED_NODES} $(basename "$file" .csv)" ;;
    snapshots/*.sql)
      HAS_MODEL_CHANGES=true
      CHANGED_NODES="${CHANGED_NODES} $(basename "$file" .sql)" ;;
    models/*.yml|models/*.yaml)
      HAS_MODEL_CHANGES=true
      YAML_CHANGED=true ;;
    macros/*.sql|dbt_project.yml|packages.yml)
      HAS_MODEL_CHANGES=true
      MACRO_OR_CONFIG=true ;;
  esac
done <<< "$CHANGED_FILES"

CHANGED_NODES=$(echo "$CHANGED_NODES" | xargs)  # trim/normalize whitespace

# BUILD_SELECT == DIFF_SELECT: one 'name+' token per changed node (model + downstream;
# no leading '+' so unchanged ancestors defer to prod). Empty for docs/macro/config-only.
BUILD_SELECT=""
for node in ${CHANGED_NODES}; do
  BUILD_SELECT="${BUILD_SELECT} ${node}+"
done
BUILD_SELECT=$(echo "$BUILD_SELECT" | xargs)
DIFF_SELECT="$BUILD_SELECT"

# Fallback needed when a change can't be scoped by filename: macros/config affect any model;
# a yaml-only change (no node) can alter tests/configs on any model.
NEEDS_FALLBACK=false
if [[ "$MACRO_OR_CONFIG" == "true" ]]; then NEEDS_FALLBACK=true; fi
if [[ "$YAML_CHANGED" == "true" && -z "$CHANGED_NODES" ]]; then NEEDS_FALLBACK=true; fi
```

- [ ] **Step 4: Update the emit + export block**

Replace the emit/export block (current lines ~50-64) with:

```bash
echo ""
echo "HAS_MODEL_CHANGES=${HAS_MODEL_CHANGES}"
echo "CHANGED_MODELS=${CHANGED_NODES:-<none>}"
echo "DIFF_SELECT=${DIFF_SELECT:-<none>}"
echo "BUILD_SELECT=${BUILD_SELECT:-<none>}"
echo "NEEDS_FALLBACK=${NEEDS_FALLBACK}"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "HAS_MODEL_CHANGES=${HAS_MODEL_CHANGES}" >> "$GITHUB_ENV"
  echo "DIFF_SELECT=${DIFF_SELECT}" >> "$GITHUB_ENV"
  echo "BUILD_SELECT=${BUILD_SELECT}" >> "$GITHUB_ENV"
  echo "NEEDS_FALLBACK=${NEEDS_FALLBACK}" >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "has_model_changes=${HAS_MODEL_CHANGES}" >> "$GITHUB_OUTPUT"
  echo "changed_models=${CHANGED_NODES}" >> "$GITHUB_OUTPUT"
  echo "diff_select=${DIFF_SELECT}" >> "$GITHUB_OUTPUT"
  echo "build_select=${BUILD_SELECT}" >> "$GITHUB_OUTPUT"
  echo "needs_fallback=${NEEDS_FALLBACK}" >> "$GITHUB_OUTPUT"
fi
```

Also update the header comment (lines ~4-9) to list the new outputs.

- [ ] **Step 5: Run to confirm GREEN**

Run: `bash tests/test_get_changed_models.sh`
Expected: PASS (all scenarios). Also run `bash tests/test_pr_data_diff.sh` and `bash tests/test_pr_schema_diff.sh` — still green (DIFF_SELECT value shape unchanged for model-only cases).

- [ ] **Step 6: Commit**

```bash
git add scripts/get_changed_models.sh tests/test_get_changed_models.sh
git commit -m "feat(ci): emit BUILD_SELECT and NEEDS_FALLBACK from get_changed_models (git-diff build scope)"
```

---

### Task 2: `ci_build.sh` git-diff-scoped build tiers

**Files:**
- Modify: `scripts/ci_build.sh` (build-strategy block, current lines ~66-104, + header comment)
- Modify: `tests/test_ci_build.sh` (add tier scenarios)

**Interfaces:**
- Consumes (env): `HAS_MODEL_CHANGES`, `HAS_STATE` (internal), `BUILD_SELECT`, `NEEDS_FALLBACK`.
- Preserves: `--exclude-resource-type test` on every build; `export_ci_select_defer` at the end; `CI_SELECT`/`CI_DEFER` semantics.

- [ ] **Step 1: Add tier scenarios to `tests/test_ci_build.sh` (RED)**

Reuse the file's existing `dbt`-stub-arg-log harness. Add:

```bash
echo "scenario: HAS_STATE + no fallback + BUILD_SELECT → git-diff scoped build"
# stub gsutil+python so HAS_STATE=true (valid manifest); env: HAS_MODEL_CHANGES=true NEEDS_FALLBACK=false BUILD_SELECT="fct_a+"
assert_contains "$(cat "$DBT_CALL_LOG")" 'build --target ci --select fct_a+ --defer --state prod_state --exclude-resource-type test'

echo "scenario: HAS_STATE + fallback + BUILD_SELECT → combined select"
# env: NEEDS_FALLBACK=true BUILD_SELECT="fct_a+"
assert_contains "$(cat "$DBT_CALL_LOG")" 'build --target ci --select fct_a+ state:modified+ --defer --state prod_state --exclude-resource-type test'

echo "scenario: HAS_STATE + fallback + no BUILD_SELECT → state:modified+ only"
# env: NEEDS_FALLBACK=true BUILD_SELECT=""
assert_contains "$(cat "$DBT_CALL_LOG")" 'build --target ci --select state:modified+ --defer --state prod_state --exclude-resource-type test'

echo "scenario: no manifest (HAS_STATE false) → full build, no defer"
# stub gsutil to fail → no manifest; env: HAS_MODEL_CHANGES=true BUILD_SELECT="fct_a+"
assert_contains "$(cat "$DBT_CALL_LOG")" 'build --target ci --exclude-resource-type test'
assert_not_contains "$(cat "$DBT_CALL_LOG")" '--defer'
```

Match the harness's real stub setup for the `HAS_STATE=true` case (it must produce a valid `prod_state/manifest.json` — the harness likely already stubs `gsutil`/`python3`; reuse it). Read the current file first.

- [ ] **Step 2: Run to confirm RED**

Run: `bash tests/test_ci_build.sh`
Expected: FAIL (current script emits `state:modified+` for the scoped case, never `--select fct_a+`).

- [ ] **Step 3: Rewrite the build-strategy block in `scripts/ci_build.sh`**

Replace lines from `# Tier 1: No model changes → parse only` (~68) through the closing `fi` of the build strategy (~104) with:

```bash
# No dbt model changes → parse only (docs-only)
if [[ "${HAS_MODEL_CHANGES:-true}" == "false" ]]; then
  echo "No dbt model changes detected in this PR. Running parse-only validation."
  dbt parse --target ci
  echo ""
  echo "=== Parse Complete (no model changes) ==="
  exit 0
fi

if [[ "${HAS_STATE}" != "true" ]]; then
  # No prod manifest → cannot defer safely → full build.
  echo "No production state available, running full build"
  dbt build --target ci --exclude-resource-type test
  CI_SELECT=""; CI_DEFER=""
elif [[ "${NEEDS_FALLBACK:-false}" == "false" && -n "${BUILD_SELECT:-}" ]]; then
  # Git-diff scoped build; unchanged ancestors defer to prod (build scope == diff scope).
  echo "Strategy: git-diff scoped build — ${BUILD_SELECT}"
  dbt build --target ci --select "${BUILD_SELECT}" --defer --state prod_state --exclude-resource-type test
  CI_SELECT="${BUILD_SELECT}"; CI_DEFER="--defer --state prod_state"
elif [[ "${NEEDS_FALLBACK:-false}" == "true" && -n "${BUILD_SELECT:-}" ]]; then
  # Macro/config change alongside model changes → union git scope with state:modified+.
  SEL="${BUILD_SELECT} state:modified+"
  echo "Strategy: git-diff + state:modified+ combined — ${SEL}"
  dbt build --target ci --select "${SEL}" --defer --state prod_state --exclude-resource-type test
  CI_SELECT="${SEL}"; CI_DEFER="--defer --state prod_state"
else
  # Macro/config/yaml-only change (no scoped node) → state comparison.
  echo "Strategy: state:modified+ fallback (macro/config/YAML-only change)"
  dbt build --target ci --select "state:modified+" --defer --state prod_state --exclude-resource-type test
  CI_SELECT="state:modified+"; CI_DEFER="--defer --state prod_state"
fi

echo ""
echo "=== Build Complete ==="

export_ci_select_defer
```

Update the header comment block (lines ~4-17) to describe the git-diff-scoped strategy (git-diff scope with defer; combined fallback for macro/config; full build only when no manifest) while keeping the `--exclude-resource-type test` / `CI_SELECT`/`CI_DEFER` note.

- [ ] **Step 4: Run to confirm GREEN**

Run: `bash tests/test_ci_build.sh`
Expected: PASS. Then run all four suites: `for t in test_get_changed_models test_pr_data_diff test_ci_build test_pr_schema_diff; do bash tests/$t.sh; done` — all green.

- [ ] **Step 5: Commit**

```bash
git add scripts/ci_build.sh tests/test_ci_build.sh
git commit -m "feat(ci): git-diff-scoped build in ci_build.sh (BUILD_SELECT + defer; state:modified+ fallback)"
```

---

## Manual Validation & Follow-ups (not code tasks)

- After merge, a weightcare-style validation confirms end-to-end behavior on real GCP (shell tests only prove command construction): a model-change PR should build+diff the same scoped set; a macro-change PR should hit the `state:modified+` fallback.
- Known limitations carried from the spec (documented, not fixed here): macro+model PRs build ⊋ diff; fallback path still manifest-dependent; no-manifest → full build.

## Self-Review

- **Spec coverage:** `BUILD_SELECT`/`NEEDS_FALLBACK` emission + seed/snapshot tracking → Task 1. Git-diff-scoped `ci_build.sh` tiers + no-manifest→full-build deviation → Task 2. Both covered.
- **Placeholder scan:** concrete bash + assertions throughout; the `RUN_OUT`/`DBT_CALL_LOG` names are explicitly flagged to be reconciled with each harness's existing helpers (read-first), not invented.
- **Type/name consistency:** `BUILD_SELECT`, `DIFF_SELECT`, `NEEDS_FALLBACK`, `CHANGED_NODES`, `HAS_STATE`, `CI_SELECT`, `CI_DEFER` used identically across Task 1's emission and Task 2's consumption. `BUILD_SELECT == DIFF_SELECT` holds in both tasks.
- **Ordering:** Task 1 produces the env vars Task 2 consumes; Task 2 depends on Task 1.
