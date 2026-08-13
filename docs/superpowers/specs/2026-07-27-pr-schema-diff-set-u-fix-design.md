# Design: Repair `pr_schema_diff.sh` (issue #53 + silent no-op)

**Date:** 2026-07-27
**Issue:** [#53](https://github.com/domainmethods/dbt-core-gcloud-template/issues/53)
**Status:** Approved for planning

## Summary

`scripts/pr_schema_diff.sh` has two independent defects. Issue #53 makes it abort
the CI job outright. A second, previously unreported defect makes the feature a
silent no-op even when it does not abort. This design fixes both, adds the
repository's first shell test harness, and defers a performance concern to a
measured follow-up.

## Problem

### Defect A — uninitialized array aborts CI (issue #53)

Line 336 declares the orphan accumulator as `declare -a orphans` with no
initializer. Line 353 then reads `${#orphans[@]}`. Under `set -u`, reading
`${#arr[@]}` on a declared-but-unassigned array is an unbound-variable error and
the script exits 1. This is *not* fixed by bash 4.4's array relaxation, which
covers `${arr[@]}` but not `${#arr[@]}`.

`orphans` is only ever assigned inside the `orphans+=(...)` branch, so the script
survives only when at least one orphan is found. The failure mode is inverted: a
clean production dataset fails CI, a messy one passes.

The schema-diff step in `.github/workflows/ci.yml` (line 115-117) has no
`continue-on-error`, unlike the docs and artifact-upload steps around it, so a
non-zero exit fails the entire PR build.

Reproduced against the current script with stubbed `bq`/`dbt`:

| Scenario | Exit | Cause |
|---|---|---|
| Zero orphans (all prod tables covered by manifest) | 1 | `orphans` never assigned |
| Prod dataset unreadable (Access Denied) | 1 | `continue` before assignment |
| At least one orphan exists | 0 | array assigned |
| `bq` emits a non-JSON banner | 1 | jq parse error before assignment |

### Defect B — the per-model diff never runs

`get_node_by_name` (lines 76-83) binds `local manifest=$1` but never passes
`"$manifest"` to `jq`. With no file argument, `jq` reads standard input, which is
empty or closed under CI, and returns nothing.

That function is the gate at the top of the per-model loop. When it returns
empty, the loop logs `[warn] Could not resolve model X in PR manifest; skipping`
and `continue`s. Every model therefore skips, the markdown summary table is
emitted with a header and no rows, and the PR comment is empty.

`get_node_by_uid`, directly below it, does pass `"$manifest"` correctly — the
omission is isolated to `get_node_by_name`.

Confirmed two ways: direct isolation of the function against a fixture manifest,
and the CI log for downstream `weightcare-pipeline-new` PR #72, where all 40
selected models emit the skip warning and no diff content is produced.

### Downstream state

`jasonbhart/weightcare-pipeline-new` already carries a fix for Defect A
(`declare -a orphans=()` plus a subshell wrapper). It does **not** have a fix for
Defect B. It has also regressed two things this design keeps: the
`--maximum_bytes_billed` cost cap on `bq_json`, and the
`[warn] Could not list tables in ...` diagnostic written to `orphans.md`.

## Non-goals

- `DIFF_SELECT` git-diff model selection (issue #29).
- `drop_bq_dataset.sh` unbound-variable defects (issue #19), though the test
  harness introduced here is intended to be reusable for it.
- Query batching (see Deferred work).
- Any change to `pr_data_diff.sh`.

## Design

### 1. Fix `get_node_by_name`

Pass the manifest path to `jq` and drop the unused `name` local, which shadows
nothing and is never read (the body uses `$2` directly).

```bash
get_node_by_name() {
  local manifest=$1
  jq -r --arg n "$2" '
    .nodes
    | to_entries[]
    | select(.value.resource_type=="model" and .value.name==$n)
    | .value' "$manifest"
}
```

This is the change that makes the feature functional. Everything downstream of it
in the loop executes for the first time.

### 2. Harden the newly reachable per-model path

Fixing Defect B activates code that has never executed. The specific hazard is
`compute_column_diff` and `compute_meta_diff`, which pass introspection results to
`jq --argjson`. `--argjson` hard-fails on input that is not valid JSON, and the
six `bq_*` helpers can return banner text or an error string rather than JSON.
Under `set -e` that aborts the script.

Add a single normalizing helper so non-JSON degrades to an empty array instead of
aborting:

```bash
as_json_array() {
  local v=${1:-}
  if [[ -n "$v" ]] && printf '%s' "$v" | jq -e 'type=="array"' >/dev/null 2>&1; then
    printf '%s' "$v"
  else
    printf '[]'
  fi
}
```

**Ordering rule — classify from raw, normalize at the jq boundary.** The
introspection results are both a *signal* and a *payload*. Line 255 classifies
status by inspecting the raw string:

```bash
if [[ -z "$prod_cols_json" || "$prod_cols_json" == *"Access Denied"* ]]; then
    status="AUTH_ERROR"
```

Normalizing before this check would rewrite `Access Denied` to `[]`, which is
non-empty and no longer matches the substring, silently downgrading a permissions
failure to a clean `OK` diff. `as_json_array` must therefore be applied **only**
where a value is handed to `jq --argjson`, never before status classification.

Status classification is extended to cover the third case, which currently has no
representation:

- empty or `Access Denied` → `AUTH_ERROR` (unchanged)
- non-empty but not parseable as a JSON array → `NON_JSON` (new)
- parseable, but no prod table type → `NEW_MODEL` (unchanged)
- otherwise → `OK` (unchanged)

`NON_JSON` rows are emitted in the summary table with zero column counts. The
requirement is that unparseable introspection output is never reported as `OK`.

### 3. Fix the orphan block (issue #53)

Port the shape downstream validated, with the two downstream regressions
corrected:

- `declare -a orphans=()` — explicitly initialized.
- Capture the `jq` table-name parse into a variable guarded with `|| true` plus an
  emptiness check, and feed the `while` loop from a `<<<` herestring rather than a
  `< <(echo ... | jq ...)` process substitution.
- Wrap the whole block in `( set +euo pipefail; ... ) || echo "[warn] ..." >&2` so
  this best-effort side feature can never abort the core diff.
- Delete the dead `tables_json=$(bq_table_type "$PROD_PROJECT" "$ds" "__all__")`
  call at line 338. Its result is never read and it issues a real BigQuery query
  on every run.
- **Keep** `--maximum_bytes_billed=1000000000` on `bq_json`.
- **Keep** the `[warn] Could not list tables in $PROD_PROJECT.$ds (no access?)`
  line written into `orphans.md`, so an unreadable dataset stays visible in the
  report rather than silently producing "Found 0 orphan(s)".

The subshell deliberately trades loud-wrong for quiet-wrong inside the orphan
block. That is acceptable because the block is a side report; it is not acceptable
for the per-model diff, which is why item 2 guards rather than suppresses.

### 4. Harden the CI step

Add `continue-on-error: true` to the "Generate schema diffs for changed models"
step in `.github/workflows/ci.yml`, matching the docs-generate and
artifact-upload steps. This is defence in depth: item 3 prevents the known
failure, this prevents the class.

### 5. Test harness

New file `tests/test_pr_schema_diff.sh` — dependency-free bash, no bats, no new CI
dependency. It builds a temp directory containing:

- executable `bq` and `dbt` stubs placed first on `PATH`, with per-scenario
  behaviour selected by an environment variable;
- fixture `target/manifest.json` and `prod_state/manifest.json`;
- an invocation counter file that the `bq` stub appends to on every call.

Scenarios and assertions, all run with stdin closed to mimic CI:

| # | Scenario | Assertion |
|---|---|---|
| 1 | Zero orphans | exit 0 |
| 2 | Prod dataset unreadable | exit 0, `orphans.md` contains the "Could not list tables" warning |
| 3 | One orphan present | exit 0, `orphans.md` lists it |
| 4 | `bq` returns a non-JSON banner | exit 0, no `jq` parse abort |
| 5 | **Regression guard for Defect B** | see below |
| 6 | Non-JSON introspection output | exit 0, and status is **not** `OK` |

**Scenario 5, stated precisely.** For every model returned by `dbt ls`, the run
must emit exactly one row in `schema-summary.md` and zero
`Could not resolve model` warnings. Models with no prod counterpart — the common
case on a template's first run — count as satisfying the row requirement with
status `NEW_MODEL`; the assertion is on row *count* and warning *absence*, not on
status value. This is the assertion that locks in the fix for Defect B and is the
one that would have caught the no-op in the first place.

**Scenario 6** asserts only that the run survives and does not misreport
unparseable output as `OK`. The exact status string is pinned during
implementation, once the behaviour is observed rather than predicted.

The harness also prints the recorded `bq` invocation count. That converts the
performance risk below into a measured number without touching real BigQuery.

Wiring: a `test-scripts` target in the `Makefile` (added to `.PHONY`) and a step in
the CI `lint` job, which is fast and has no GCP dependency.

## Deferred work

Today the per-model loop `continue`s before issuing any `bq` call, so it performs
**zero** BigQuery queries. Fixing Defect B activates six `bq` invocations per
model — columns, table type, and table options, for dev and prod each. At
downstream's 40-model selection that is roughly 240 `bq` CLI invocations, each a
fresh Python process and API round trip. Against a job already running ~17
minutes, this could add materially to CI wall-clock.

The structural answer is to batch: issue one `INFORMATION_SCHEMA.COLUMNS`, one
`.TABLES`, and one `.TABLE_OPTIONS` query per dataset, cache the results in
memory, and filter per model. That reduces the count from `6 × models` to roughly
`3 × datasets`.

Batching is **out of scope for this change**. It is a larger diff touching every
query helper, and the decision should rest on a measured number rather than an
estimate. This change ships the correctness fixes and the instrumentation; the
`bq` invocation count from the harness, plus the first real CI run, decide whether
batching is warranted as a follow-up.

## Validation and rollout

Validation runs downstream-first. This template repository has only two example
models and its own CI is red, so it cannot confirm that the Defect B fix works at
realistic scale. `weightcare-pipeline-new` has green CI and roughly 40 real
models, and already carries the item 3 fix, so it isolates Defect B cleanly.

**Tier 1 — stub fixtures, local, free.** The `tests/test_pr_schema_diff.sh`
harness described above, run against synthetic manifests.

**Tier 2 — real manifest, local, free.** Clone `weightcare-pipeline-new`, generate
its manifest offline with `dbt parse` (no warehouse connection required), and run
the fixed script against roughly 40 real models with the counting `bq` stub. This
tier is the substantive one: it proves the Defect B fix against a manifest shaped
like production, and it produces the true `bq` invocation count that decides the
batching question. No credentials, no spend, no production impact.

**Tier 3 — real CI, costs money, requires authorization.** A draft PR on
`weightcare-pipeline-new` triggering its `bigquery-ci` job end to end. This is the
only tier that exercises real BigQuery introspection and the only one that
measures true wall-clock. It runs against a production GCP project and is visible
to the repository owner. Access is push, not admin. **This tier is not initiated
without explicit approval, and nothing is merged downstream unilaterally.**

Rollout order:

1. Implement items 1-5 on a branch. Tier 1 and Tier 2 must pass.
2. Tier 3, if authorized. Record the measured query count and wall-clock.
3. Upstream template PR carrying items 1-5, closing issue #53, citing the Tier 2
   and Tier 3 results.
4. File a separate upstream issue for Defect B, cross-referencing #53, with the
   evidence recorded here.
5. Downstream PR carrying items 1 and 2 only, opened for the owner's review.

Nothing is committed to the upstream default branch before Tier 2 passes.

## Risks

- The template repository's own CI is currently red across all recent runs, so it
  cannot serve as a verification signal. This is the reason validation is
  downstream-first; without Tier 2 there would be no realistic feedback loop
  before merge.
- Tier 2 uses a manifest produced by `dbt parse` rather than the `dbt docs
  generate` manifest CI actually consumes. If the two differ in a way that
  matters to `get_node_by_name`, Tier 2 could pass while CI still fails. The
  fields in question (`name`, `alias`, `schema`, `database`, `unique_id`) are
  parse-time attributes, so divergence is unlikely, but only Tier 3 rules it out.
- Stub tests verify control flow, not SQL correctness. They prove the script does
  not crash and does produce rows; they cannot prove the diff is semantically
  right.
- Activating a never-executed code path may surface further defects in the
  `NEW_MODEL` and `AUTH_ERROR` status logic. If that happens, the follow-ups are
  filed as issues rather than absorbed into this change.
- PR comments change from an empty table to a populated one. This is the intended
  behaviour but is a visible change for existing users.
- `mapfile` requires bash 4+, so stock macOS bash 3.2 cannot run the script. CI is
  ubuntu with bash 5, and local developers use a modern bash, so this is recorded
  rather than addressed.
