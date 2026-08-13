# Template Build-Selection Parity — Design

**Date:** 2026-08-12
**Status:** Approved (brainstorming) → pending implementation plan
**Branch:** `fix/template-build-parity` (stacked on `fix/53-pr-schema-diff-set-u`)

## Problem

After the CI diff-accuracy work (PR #55), the template's **diff** selection is git-diff based
(`DIFF_SELECT` → `state:modified+` → all) but its **build** selection in `scripts/ci_build.sh`
is still purely `state:modified+` (manifest/state based). Two consequences:

1. **Build and diff use different selectors.** In the common case they align, but when the prod
   manifest is stale or version-mismatched, `state:modified+` over-selects (the "211-model"
   symptom observed in the downstream weightcare validation) — the build over-builds, and in
   edge cases can diverge from what the diff expects.
2. **Manifest dependence for build scoping.** The template cannot scope the build from the git
   diff alone; it always leans on the prod manifest.

The downstream weightcare repo already solved this: it emits a git-diff `BUILD_SELECT` and builds
git-diff-scoped, using `state:modified+` only as a fallback for changes that cannot be scoped by
filename (macros, project config, yaml-only). This design ports that capability to the template.

## Goal

Make the template build **git-diff-scoped** so build and diff use the same selector for
model-change PRs, removing manifest dependence for the common case. Achieve capability parity with
weightcare's build strategy (not byte-for-byte code parity).

## Non-goals (explicitly out of scope)

- Changes to `pr_data_diff.sh` / `pr_schema_diff.sh` selection (the diff scripts stay as-is).
- The data-diff sample-rows `EXCEPT DISTINCT`/`UNION ALL` set-operation bug in
  `macros/compare_dev_prod.sql` (tracked separately).
- Model non-determinism (`QUALIFY`/window ties) — a data-modeling issue in consumer repos, not the
  template's CI.
- A manifest-freshness/version-compat guard (a possible later enhancement; see Known Limitations).

## Design

### 1. `scripts/get_changed_models.sh` — emit `BUILD_SELECT` and `NEEDS_FALLBACK`

Today the script sets `HAS_MODEL_CHANGES`, `CHANGED_MODELS` (model `.sql` basenames), and derives
`DIFF_SELECT` (`name+` per changed model). Extend it:

- **Track buildable names from three file types**, not just models:
  - `models/**/*.sql` → model basename
  - `seeds/**/*.csv` → seed basename
  - `snapshots/**/*.sql` → snapshot basename
  Collect these into one ordered, de-duplicated list `CHANGED_NODES`.
- **`BUILD_SELECT`** = `name+ name+ …` over `CHANGED_NODES` (one `name+` token each; no leading `+`
  so ancestors defer to prod).
- **`DIFF_SELECT`** = the **same** value as `BUILD_SELECT`. (This widens today's model-only
  `DIFF_SELECT` to also cover seed/snapshot changes — a wanted improvement: a seed change now diffs
  its downstream models. Existing `DIFF_SELECT` tests are updated accordingly.)
- **`NEEDS_FALLBACK`** = `true` when a change cannot be scoped from filenames alone:
  - any `macros/**/*.sql` changed, OR
  - `dbt_project.yml` or `packages.yml` changed, OR
  - a `models/**/*.yml`/`*.yaml` changed with **no** accompanying model/seed/snapshot node in this PR
    (yaml-only change — tests/configs can affect any model).
  Otherwise `false`.
- **`HAS_MODEL_CHANGES`** logic is unchanged (true if any dbt-relevant file changed).
- **Self-export** `BUILD_SELECT` and `NEEDS_FALLBACK` to `$GITHUB_ENV` alongside the existing
  `HAS_MODEL_CHANGES`/`DIFF_SELECT`, and to `$GITHUB_OUTPUT` alongside the existing outputs.

Emitted keys after this change: `HAS_MODEL_CHANGES`, `CHANGED_MODELS`, `DIFF_SELECT`,
`BUILD_SELECT`, `NEEDS_FALLBACK`.

### 2. `scripts/ci_build.sh` — git-diff-scoped build tiers

Keep the existing state-detection block (downloads the prod manifest, sets `HAS_STATE`, validates
JSON) and the `--exclude-resource-type test` flag on every build, and the `CI_SELECT`/`CI_DEFER`
export at the end (consumed by the non-blocking `dbt test` step). Replace the build-strategy
selection with tiers gated first on "can we defer?" (`HAS_STATE`):

```
if HAS_MODEL_CHANGES == false:
    dbt parse --target ci ; exit 0                      # docs-only

if HAS_STATE == false:                                  # no prod manifest → can't defer
    dbt build --target ci --exclude-resource-type test  # full build
    CI_SELECT=""; CI_DEFER=""

else (HAS_STATE == true):
    if NEEDS_FALLBACK == false and BUILD_SELECT non-empty:            # git-diff scoped
        dbt build --target ci --select "$BUILD_SELECT" \
            --defer --state prod_state --exclude-resource-type test
        CI_SELECT="$BUILD_SELECT"; CI_DEFER="--defer --state prod_state"
    elif NEEDS_FALLBACK == true and BUILD_SELECT non-empty:           # combined (macro+model)
        SEL="$BUILD_SELECT state:modified+"
        dbt build --target ci --select "$SEL" \
            --defer --state prod_state --exclude-resource-type test
        CI_SELECT="$SEL"; CI_DEFER="--defer --state prod_state"
    else:                                                            # macro/config/yaml-only
        dbt build --target ci --select "state:modified+" \
            --defer --state prod_state --exclude-resource-type test
        CI_SELECT="state:modified+"; CI_DEFER="--defer --state prod_state"

# end: export CI_SELECT / CI_DEFER to $GITHUB_ENV (guarded by [[ -n "${GITHUB_ENV:-}" ]])
```

Result: for a model-change PR (`NEEDS_FALLBACK=false`), the build selects the same `BUILD_SELECT`
as the diff's `DIFF_SELECT`, deferring ancestors to prod — build and diff scopes match and neither
depends on the manifest for scoping.

### 3. Deviation from weightcare (intentional, for correctness)

weightcare, when it has a `BUILD_SELECT` but **no** prod manifest, runs a *scoped* build with no
`--defer` — which fails because unbuilt ancestors are missing. This design gates on `HAS_STATE`
first, so **no manifest → full build** (the template's current safe behavior). This is
parity-plus-one-fix, not a byte-for-byte copy.

### 4. Data flow (shape unchanged)

detect step (`get_changed_models.sh`) → `$GITHUB_ENV`
(`HAS_MODEL_CHANGES`, `DIFF_SELECT`, **`BUILD_SELECT`**, **`NEEDS_FALLBACK`**) →
`ci_build.sh` (git-diff-scoped build) → `CI_SELECT`/`CI_DEFER` → non-blocking `dbt test` + diffs.
No `.github/workflows/ci.yml` change is required: `get_changed_models.sh` self-exports and
`ci_build.sh` reads from the environment.

## Testing

Extend the two existing dependency-free harnesses (bash 4+/coreutils, real throwaway git-repo
fixtures, no `set -e`):

- **`tests/test_get_changed_models.sh`** — add/adjust scenarios asserting the new outputs:
  - one model `.sql` → `BUILD_SELECT="name+"`, `DIFF_SELECT="name+"`, `NEEDS_FALLBACK=false`
  - one seed `.csv` → `BUILD_SELECT`/`DIFF_SELECT` include `seed+`, `NEEDS_FALLBACK=false`
  - one snapshot `.sql` → include `snap+`, `NEEDS_FALLBACK=false`
  - macro-only → `NEEDS_FALLBACK=true`, `BUILD_SELECT` empty, `HAS_MODEL_CHANGES=true`
  - `dbt_project.yml`-only → `NEEDS_FALLBACK=true`, `BUILD_SELECT` empty
  - `models/**/*.yml`-only (no sql) → `NEEDS_FALLBACK=true`, `BUILD_SELECT` empty
  - macro + model together → `NEEDS_FALLBACK=true`, `BUILD_SELECT="name+"`
  - docs-only (README) → all empty, `HAS_MODEL_CHANGES=false`
- **`tests/test_ci_build.sh`** — add one scenario per tier, asserting the exact `dbt build` command
  via the stubbed-`dbt` arg log:
  - `HAS_STATE=true`, `NEEDS_FALLBACK=false`, `BUILD_SELECT` set → `build --select "<BUILD_SELECT>" --defer --state prod_state --exclude-resource-type test`
  - `HAS_STATE=true`, `NEEDS_FALLBACK=true`, `BUILD_SELECT` set → `build --select "<BUILD_SELECT> state:modified+" --defer ...`
  - `HAS_STATE=true`, `NEEDS_FALLBACK=true`, no `BUILD_SELECT` → `build --select "state:modified+" --defer ...`
  - `HAS_STATE=false` → `build --target ci --exclude-resource-type test` (full, no defer)
  - `HAS_MODEL_CHANGES=false` → `dbt parse`, no build (existing)

Shell tests validate **command construction**, not live dbt behavior; end-to-end correctness is
confirmed by a follow-up weightcare-style no-op/real PR validation (out of this spec's automated
scope).

## Known limitations (accepted, documented)

1. **Macro+model PRs: build ⊋ diff.** The build uses `"BUILD_SELECT state:modified+"` while the
   diff uses `DIFF_SELECT` (git-only) — macro-affected models are built but not diffed. Narrow
   edge; identical to weightcare; not a correctness bug (diffed models all exist). Closable later
   by also appending `state:modified+` to the diff under `NEEDS_FALLBACK` (touches the diff
   scripts — out of scope here).
2. **Manifest dependence is narrowed, not eliminated.** Model-change PRs are manifest-independent
   for build scoping; macro/config/yaml-only PRs still use `state:modified+` and can over-select if
   the manifest is stale. A manifest-freshness guard (Approach C) is a possible later enhancement.
3. **No manifest → full build** on every PR (the deviation above). Correct, but no scoping benefit
   without a prod manifest — same as today, no regression.

## Success criteria

- `get_changed_models.sh` emits correct `BUILD_SELECT`/`NEEDS_FALLBACK` for all node/change types
  (covered by the harness).
- `ci_build.sh` constructs the correct `dbt build` command for each tier (covered by the harness).
- All existing shell suites remain green after the `DIFF_SELECT`-widening change.
- Build and diff select the same models for a model-change PR.
