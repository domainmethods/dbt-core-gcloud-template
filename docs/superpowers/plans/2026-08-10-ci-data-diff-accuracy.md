# CI Data-Diff Accuracy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the template's PR diffs trustworthy — no data *or* schema diff on docs-only PRs, and a data diff that isn't suppressed by an unrelated failing data test.

**Architecture:** Three CI-script fixes sharing one selection pattern. (1) Wire the git-diff scope (`get_changed_models.sh`) into `$GITHUB_ENV` and make `pr_data_diff.sh` honour it — exiting immediately when no models changed instead of falling back to `state:modified+`/all-models. (2) Build models without tests in the gating step and run `dbt test` as a separate non-blocking step, so a red test no longer skips every diff/comment step. (3) Apply the same selection precedence to `pr_schema_diff.sh` so docs-only PRs skip the schema diff too.

**Tech Stack:** GitHub Actions, bash, dbt-core 1.10.8 / dbt-bigquery 1.10.1, BigQuery. Dependency-free shell test harness (bash 4+, jq, coreutils) — same pattern as `tests/test_pr_schema_diff.sh`.

## Global Constraints

- dbt-core **1.10.8**, dbt-bigquery **1.10.1** — `dbt build --exclude-resource-type test` is supported at this floor (added in dbt 1.8); do not use flags newer than 1.10. Task 2 includes a verification step for the flag.
- Shell tests must be dependency-free (no bats, no pip): bash 4+, `jq`, coreutils only. Stub `dbt`/`bq`/`gsutil` on `PATH`. Do **not** use `set -e` in the harness.
- Scope is the **template repo only** (`dbt-core-gcloud-template`). Do not modify `jasonbhart/weightcare-pipeline-new`.
- Do not change the data-diff SQL macro (`macros/compare_dev_prod.sql`) or `compare_template.sql` — the set-operation bug is tracked separately.
- Commit messages: neutral, conventional-commit style. No co-author trailers.

---

## Background / Rationale (spec)

Empirical validation (test PRs in a downstream deployment) surfaced three problems. This plan fixes the CI-orchestration issues in the template; source-data drift is already mitigated here and is validated, not coded.

1. **Docs-only PRs don't cleanly produce "no diff" (FIX HERE — Tasks 1 & 3).**
   `get_changed_models.sh` computes `HAS_MODEL_CHANGES` / `DIFF_SELECT`, but the "Detect changed dbt files" step (`.github/workflows/ci.yml:53-55`) **never pipes them into `$GITHUB_ENV`**, so they are unavailable downstream. Consequences:
   - `scripts/ci_build.sh:50` reads `${HAS_MODEL_CHANGES:-true}` → always `true` → the docs-only "parse-only" tier never fires.
   - `scripts/pr_data_diff.sh:36-49` **and** `scripts/pr_schema_diff.sh:56-67` ignore the git scope and select via `state:modified+` (or all models if no manifest). A stale/version-mismatched prod manifest makes `state:modified+` flag *every* model, so a docs-only PR attempts to diff the whole project.

2. **A single red data test suppresses the entire data diff (FIX HERE — Task 2).**
   `ci_build.sh` runs `dbt build` (models **and** tests). Every diff/comment step is gated on `steps.dbt_build.outcome == 'success'` (`ci.yml:109,114,124,130,156,170`). One failing `assert_*`/generic test anywhere in the selected lineage fails the build → all diffs are `skipped`.

3. **Source-data drift (NOTE ONLY — already mitigated in the template).**
   The template builds with `state:modified+ --defer --state prod_state` (`ci_build.sh:75`), deferring unchanged ancestors to prod — the correct approach. (Drift seen downstream came from a `+model+` variant that rebuilds ancestors; the template does not use it.) See **Manual Validation & Follow-ups**.

## Risks & Trade-offs

- **Loss of test-blocking (Task 2).** `dbt build` normally *skips* a model when an upstream test fails. Building with `--exclude-resource-type test` removes that gate: models build regardless of data-quality results. This is intended for a diff/CI-preview run (we want the diff even when data tests are red), but it means the ephemeral CI dataset may contain rows an upstream test would have rejected. The separate `dbt test` step keeps failures **visible** (its own red check); it just no longer suppresses the diff. Document this in the `ci_build.sh` header.
- **Line-number references are pre-Task-1.** Tasks are ordered 1→2→3; each task's line numbers describe the file *before that task's own edits*. When a task edits a file an earlier task already touched (`ci.yml`), anchor on the quoted code strings shown, not on absolute line numbers.
- **Docs-only ⇒ no comment at all.** When `pr_data_diff.sh` exits early, it never writes `diff_reports/summary.md`, so the "Post summary comment" step (`ci.yml:170`, gated on `hashFiles('diff_reports/summary.md')`) is skipped and no data-diff comment is posted. That satisfies "no diffs". If a reviewer would rather see an explicit "no data changes" note, that's a follow-up, not this plan.
- **`--defer` permissions.** If the CI service account cannot read the prod dataset, `--defer` silently rebuilds ancestors → drift. Only a live no-op PR catches this; it's in the validation checklist.

## File Structure

- `.github/workflows/ci.yml` — export detect-step output to `$GITHUB_ENV` (Task 1); add a non-blocking `dbt test` step (Task 2); run the new harnesses in the lint job (Tasks 1, 3).
- `scripts/pr_data_diff.sh` — top-of-script short-circuit + selection precedence honouring `HAS_MODEL_CHANGES`/`DIFF_SELECT` (Task 1).
- `scripts/pr_schema_diff.sh` — same short-circuit + precedence (Task 3).
- `scripts/ci_build.sh` — build with `--exclude-resource-type test`; export resolved select/defer for the test step; updated header (Task 2).
- `tests/test_pr_data_diff.sh` — new harness for data-diff selection (Task 1).
- `tests/test_ci_build.sh` — new harness for build-command construction (Task 2).
- `tests/test_pr_schema_diff.sh` — extend with docs-only/`DIFF_SELECT` scenarios (Task 3).

The selection precedence (short-circuit → `DIFF_SELECT` → `state:modified+` → all) is identical in Tasks 1 and 3. If a third consumer ever needs it, extract `scripts/select_changed_models.sh`; two copies do not yet justify the indirection (YAGNI).

---

### Task 1: Honour git-diff scope in the data diff (docs-only → no data diff)

**Files:**
- Modify: `.github/workflows/ci.yml:53-55` (detect step) and lint-job step (`:19` area)
- Modify: `scripts/pr_data_diff.sh` — add early guard after env setup (~`:14`); replace selection block (`:35-49`)
- Create: `tests/test_pr_data_diff.sh`

**Interfaces:**
- Consumes (from detect step, now exported): `HAS_MODEL_CHANGES` (`"true"`/`"false"`), `DIFF_SELECT` (space-separated `name+` selectors, possibly empty).
- Produces: `pr_data_diff.sh` prints `No models to diff.` and exits 0 when `HAS_MODEL_CHANGES=false`; else selects via `DIFF_SELECT` when non-empty, else `state:modified+`, else all models.

- [ ] **Step 1: Write the failing test**

Create `tests/test_pr_data_diff.sh`. Stub `dbt` (and `gsutil`, so the manifest branch is deterministic) on `PATH`; run the real script; assert on stdout and the recorded `dbt` calls. `dbt run-operation` is stubbed to emit one SUMMARY line so the script completes without BigQuery.

```bash
#!/usr/bin/env bash
# Tests for scripts/pr_data_diff.sh model-selection logic.
# Dependency-free: bash 4+, coreutils. Stubs dbt/gsutil on PATH. No `set -e`.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO_ROOT/scripts/pr_data_diff.sh"
PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "    ok   - $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "    FAIL - $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
assert_contains() { [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 (missing '$2')"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] && pass "$3" || fail "$3 (unexpected '$2')"; }

make_sandbox() {
  SANDBOX=$(mktemp -d); DBT_CALL_LOG="$SANDBOX/dbt_calls.log"; mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/dbt" <<'STUB'
#!/usr/bin/env bash
echo "dbt $*" >> "$DBT_CALL_LOG"
case "$1" in
  ls) printf '%s\n' model_a model_b ;;
  run-operation) echo "SUMMARY|table=model_a|dev=1|prod=1|dev_not_in_prod=0|prod_not_in_dev=0" ;;
  *) : ;;
esac
STUB
  chmod +x "$SANDBOX/bin/dbt"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/bin/gsutil"; chmod +x "$SANDBOX/bin/gsutil"
  export DBT_CALL_LOG
}

run_case() {  # $1 = extra env assignments; sets RUN_OUT and DBT_CALL_LOG
  make_sandbox
  [[ "${WITH_MANIFEST:-0}" == "1" ]] && { mkdir -p "$SANDBOX/prod_state"; echo '{}' > "$SANDBOX/prod_state/manifest.json"; }
  RUN_OUT=$(cd "$SANDBOX" && env -i PATH="$SANDBOX/bin:/usr/bin:/bin" \
    DBT_CALL_LOG="$DBT_CALL_LOG" ARTIFACT_DIR="$SANDBOX/diff_reports" \
    DBT_GCP_PROJECT_CI=ciproj DBT_BQ_DATASET=ci_ds DBT_GCP_PROJECT_PROD=prodproj \
    $1 bash "$SCRIPT" 2>&1)
}

echo "scenario 1: docs-only (HAS_MODEL_CHANGES=false) diffs nothing, no dbt ls"
run_case 'HAS_MODEL_CHANGES=false'
assert_contains "$RUN_OUT" "No models to diff" "exits early with no models"
assert_not_contains "$(cat "$DBT_CALL_LOG")" "ls" "never calls dbt ls"

echo "scenario 2: DIFF_SELECT is used verbatim, not state:modified+"
run_case 'HAS_MODEL_CHANGES=true DIFF_SELECT=fct_example+'
assert_contains "$(cat "$DBT_CALL_LOG")" "ls --select fct_example+" "selects via DIFF_SELECT"
assert_not_contains "$(cat "$DBT_CALL_LOG")" "state:modified+" "does not use state fallback"

echo "scenario 3: no DIFF_SELECT, manifest present → state:modified+"
WITH_MANIFEST=1 run_case 'HAS_MODEL_CHANGES=true'
assert_contains "$(cat "$DBT_CALL_LOG")" "state:modified+" "uses state comparison when scope absent"

echo "results: passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pr_data_diff.sh`
Expected: FAIL — scenario 1 fails (current script ignores `HAS_MODEL_CHANGES` and calls `dbt ls`); scenario 2 fails (script never reads `DIFF_SELECT`).

- [ ] **Step 3: Add a top-of-script short-circuit in `scripts/pr_data_diff.sh`**

Immediately after the env setup (after `PROD_PROJECT=${DBT_GCP_PROJECT_PROD:-}` at `:14`, before the `=== Data Diff State Detection ===` manifest block), insert:

```bash
# Docs/config-only PRs change no models — skip the diff entirely (no gsutil, no dbt).
if [[ "${HAS_MODEL_CHANGES:-true}" == "false" ]]; then
  echo "No dbt model changes detected in this PR. No models to diff."
  exit 0
fi
```

- [ ] **Step 4: Replace the selection block in `scripts/pr_data_diff.sh:35-49`**

```bash
echo ""
echo "=== Model Selection ==="
if [[ -n "${DIFF_SELECT:-}" ]]; then
  echo "Using git-diff scope: ${DIFF_SELECT}"
  # DIFF_SELECT is intentionally unquoted so multiple 'name+' tokens expand as separate args.
  mapfile -t MODELS < <(dbt ls --select ${DIFF_SELECT} --resource-type model --output name --quiet 2>/dev/null || true)
elif [[ -f prod_state/manifest.json ]]; then
  echo "Using state comparison to find changed models..."
  mapfile -t MODELS < <(dbt ls --select "state:modified+" --state prod_state --resource-type model --output name --quiet 2>/dev/null || true)
else
  echo "No git scope and no production manifest; selecting all models..."
  mapfile -t MODELS < <(dbt ls --resource-type model --output name --quiet 2>/dev/null || true)
fi
echo "Selected ${#MODELS[@]} model(s)."
```

Keep the existing empty-guard at `:51-54`. Note: a macro/config/YAML-only change sets `HAS_MODEL_CHANGES=true` but leaves `DIFF_SELECT` empty (no model/seed/snapshot files) → the `state:modified+` branch runs, which is correct for those changes.

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_pr_data_diff.sh`
Expected: PASS (all three scenarios green).

- [ ] **Step 6: Wire the detect step into `$GITHUB_ENV`**

In `.github/workflows/ci.yml`, change the detect step (`:53-55`):

```yaml
      - name: Detect changed dbt files
        id: changes
        run: |
          output=$(bash scripts/get_changed_models.sh)
          echo "$output"
          echo "$output" >> "$GITHUB_ENV"
```

- [ ] **Step 7: Run the harness in the lint job**

In `.github/workflows/ci.yml`, replace the existing `run: bash tests/test_pr_schema_diff.sh` (`:19`) with:

```yaml
        run: |
          bash tests/test_pr_schema_diff.sh
          bash tests/test_pr_data_diff.sh
```

- [ ] **Step 8: Commit**

```bash
git add scripts/pr_data_diff.sh tests/test_pr_data_diff.sh .github/workflows/ci.yml
git commit -m "fix(ci): data diff honours git-diff scope; docs-only PRs diff nothing"
```

---

### Task 2: Decouple tests from the diff gate (a red test no longer suppresses the diff)

**Files:**
- Modify: `scripts/ci_build.sh` (build invocations at the `dbt build ...` lines; header `:4-8`; add export block before end)
- Modify: `.github/workflows/ci.yml` — add a non-blocking test step immediately after the `dbt_build` step (`Slim CI build`)
- Create: `tests/test_ci_build.sh`

**Interfaces:**
- Consumes: `HAS_MODEL_CHANGES`, internal `HAS_STATE`, prod_state manifest.
- Produces: `ci_build.sh` runs models with `--exclude-resource-type test` and exports `CI_SELECT` / `CI_DEFER` to `$GITHUB_ENV`; the new `dbt test` step consumes them with `continue-on-error: true`.

- [ ] **Step 1: Verify the flag exists at the version floor**

Run: `dbt build --help | grep -- --exclude-resource-type`
Expected: the option is listed (dbt 1.10). If absent, stop — fall back to `dbt run` + `dbt seed` + `dbt snapshot` for the build instead, and adjust the assertions below.

- [ ] **Step 2: Write the failing test**

Create `tests/test_ci_build.sh`; stub `dbt` (log args), `gsutil` (no manifest), `python3` unused here.

```bash
#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO_ROOT/scripts/ci_build.sh"
PASS_COUNT=0; FAIL_COUNT=0
pass(){ echo "    ok   - $1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail(){ echo "    FAIL - $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
assert_contains(){ [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 (missing '$2')"; }

SANDBOX=$(mktemp -d); mkdir -p "$SANDBOX/bin"
printf '#!/usr/bin/env bash\necho "dbt $*" >> "$DBT_CALL_LOG"\n' > "$SANDBOX/bin/dbt"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gsutil"   # no manifest → full build
chmod +x "$SANDBOX/bin/dbt" "$SANDBOX/bin/gsutil"
export DBT_CALL_LOG="$SANDBOX/calls.log"

echo "scenario: model changes, no state → build excludes tests"
( cd "$SANDBOX" && env -i PATH="$SANDBOX/bin:/usr/bin:/bin" DBT_CALL_LOG="$DBT_CALL_LOG" \
    HAS_MODEL_CHANGES=true bash "$SCRIPT" >/dev/null 2>&1 )
assert_contains "$(cat "$DBT_CALL_LOG")" "build --target ci --exclude-resource-type test" "build skips tests"

echo "results: passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash tests/test_ci_build.sh`
Expected: FAIL — current `ci_build.sh` runs `dbt build --target ci` without `--exclude-resource-type test`.

- [ ] **Step 4: Add `--exclude-resource-type test` and export the resolved select**

In `scripts/ci_build.sh`, append `--exclude-resource-type test` to each `dbt build` invocation. Slim build (`:75`):

```bash
  echo "Starting Slim CI build with defer (models only; tests run separately)..."
  dbt build --target ci --select "state:modified+" --defer --state prod_state --exclude-resource-type test
  CI_SELECT="state:modified+"; CI_DEFER="--defer --state prod_state"
```

Full-build fallbacks (the `dbt build --target ci` at `:67` and `:79`): change each to `dbt build --target ci --exclude-resource-type test` and set `CI_SELECT=""; CI_DEFER=""` next to them. At the end of the script (before the final `echo "=== Build Complete ==="`), export for later steps:

```bash
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "CI_SELECT=${CI_SELECT:-}" >> "$GITHUB_ENV"
  echo "CI_DEFER=${CI_DEFER:-}" >> "$GITHUB_ENV"
fi
```

Update the header comment (`:4-8`) to note: models are built without tests; `dbt test` runs as a separate non-blocking CI step; this removes dbt's upstream test-blocking (see Risks & Trade-offs).

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_ci_build.sh`
Expected: PASS.

- [ ] **Step 6: Add the non-blocking test step in `ci.yml`**

Immediately after the `dbt_build` step (the `Slim CI build ...` step), add:

```yaml
      - name: Run dbt tests (non-blocking; does not gate diffs)
        id: dbt_test
        if: ${{ steps.dbt_build.outcome == 'success' && env.HAS_MODEL_CHANGES != 'false' }}
        continue-on-error: true
        run: |
          dbt test --target ci ${CI_SELECT:+--select "$CI_SELECT"} ${CI_DEFER}
```

Leave every diff/comment step gated on `steps.dbt_build.outcome == 'success'` — that outcome now reflects model-build success only.

- [ ] **Step 7: Run all harnesses**

Run: `bash tests/test_pr_data_diff.sh && bash tests/test_ci_build.sh`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add scripts/ci_build.sh tests/test_ci_build.sh .github/workflows/ci.yml
git commit -m "fix(ci): build models without tests; run dbt test as a non-blocking step so diffs aren't suppressed"
```

---

### Task 3: Apply the same scope to the schema diff (docs-only → no schema diff)

**Files:**
- Modify: `scripts/pr_schema_diff.sh` — add top-of-script short-circuit; replace selection block (`:56-67`)
- Modify: `tests/test_pr_schema_diff.sh` — add docs-only and `DIFF_SELECT` scenarios

**Interfaces:**
- Consumes: `HAS_MODEL_CHANGES`, `DIFF_SELECT` (same as Task 1).
- Produces: `pr_schema_diff.sh` exits 0 with no schema diff when `HAS_MODEL_CHANGES=false`; else uses `DIFF_SELECT` → `state:modified+` → all.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_pr_schema_diff.sh` (reuse its existing sandbox/stub helpers):

```bash
echo "scenario: docs-only (HAS_MODEL_CHANGES=false) produces no schema diff"
# Run the script with HAS_MODEL_CHANGES=false; assert early exit and no dbt ls.
OUT=$(HAS_MODEL_CHANGES=false run_script)   # use the file's existing runner helper
assert_contains "$OUT" "No models" "schema diff exits early on docs-only"

echo "scenario: DIFF_SELECT is honoured over state:modified+"
OUT=$(HAS_MODEL_CHANGES=true DIFF_SELECT=fct_example+ run_script)
assert_contains "$SCHEMA_DBT_CALL_LOG_CONTENTS" "ls --select fct_example+" "schema diff uses DIFF_SELECT"
```

Match the exact helper names already used in `tests/test_pr_schema_diff.sh` (e.g. the existing dbt-call-log variable and run helper). Read that file first and reuse its fixtures rather than inventing new ones.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pr_schema_diff.sh`
Expected: FAIL on the two new scenarios (script currently ignores both env vars).

- [ ] **Step 3: Add the short-circuit + selection precedence to `scripts/pr_schema_diff.sh`**

After the script's env setup, before its model-selection block, insert:

```bash
if [[ "${HAS_MODEL_CHANGES:-true}" == "false" ]]; then
  echo "No dbt model changes detected in this PR. No models for schema diff."
  exit 0
fi
```

Replace its selection block (`:56-67`) with the same precedence as Task 1 Step 4 (`DIFF_SELECT` → `state:modified+` → all), preserving whatever downstream variable name the schema script already uses for the model list.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_pr_schema_diff.sh`
Expected: PASS (existing scenarios still green — this is why the full suite is re-run).

- [ ] **Step 5: Commit**

```bash
git add scripts/pr_schema_diff.sh tests/test_pr_schema_diff.sh
git commit -m "fix(ci): schema diff honours git-diff scope; docs-only PRs skip the schema diff"
```

---

## Manual Validation & Follow-ups (not code tasks)

Requires a configured GCP deployment (prod dataset + artifacts bucket) — validate on real PRs.

- **Docs-only PR** → no data-diff and no schema-diff comment; CI fast. Confirms Tasks 1 & 3.
- **Model PR whose lineage has a (temporarily) failing test** → the data-diff comment still posts; the `dbt test` check is red but separate. Confirms Task 2.
- **No-op refactor PR** (rename a CTE) → expect ~0 diff rows. If non-zero, investigate:
  - **Drift (A):** confirm the build used `state:modified+ --defer` and that `--defer` to the prod dataset succeeds from the CI project (permissions). Silent defer failure ⇒ ancestors rebuilt from live sources ⇒ drift.
  - **Nondeterminism (D):** `QUALIFY ROW_NUMBER()/DENSE_RANK()` with tie-prone `ORDER BY` can emit different rows each build. Add deterministic tiebreakers where found.
- **Follow-up:** guard against stale-manifest over-selection — validate the downloaded prod manifest's dbt version/`metadata` against the CI dbt version in `ci_build.sh`; if incompatible, treat as no-state rather than letting `state:modified+` flag everything.

## Self-Review

- **Spec coverage:** Problem 1 (docs-only) → Task 1 (data diff) + Task 3 (schema diff) + env wiring. Problem 2 (test gate) → Task 2. Problem 3 (drift) → Manual Validation (already mitigated). Covered.
- **Placeholder scan:** all steps contain concrete bash/YAML. Task 3's test intentionally defers to the *existing* helper names in `test_pr_schema_diff.sh` (read-first instruction) rather than duplicating fixtures — a deliberate DRY choice, not a placeholder.
- **Type/name consistency:** `HAS_MODEL_CHANGES`, `DIFF_SELECT`, `CI_SELECT`, `CI_DEFER` used identically across `get_changed_models.sh` output, `ci.yml` env, and the three scripts. Harness filenames (`tests/test_pr_data_diff.sh`, `tests/test_ci_build.sh`, `tests/test_pr_schema_diff.sh`) are consistent between creation and lint-job wiring.
- **Ordering:** Task 1 wires `$GITHUB_ENV` (prerequisite for Tasks 2 & 3's env reads). Task 3 depends only on that wiring, not on Task 2 — the two can be reviewed in either order after Task 1.
