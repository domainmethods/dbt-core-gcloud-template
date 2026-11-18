#!/usr/bin/env bash
# Tests for entrypoint.sh — a failed `dbt build` or `dbt source freshness` must
# still emit the summary and upload run_results.json (#20), the uploaded
# run_results.json and manifest.json must come from the build, and the job
# must still exit non-zero with the first failing step's code.
#
# Dependency-free: bash, python3, coreutils. Stubs `dbt` on PATH and
# `google.cloud.storage` on PYTHONPATH (uploads land on disk). No network, no GCP.
# `set -e` is deliberately NOT used so assertions can accumulate.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PASS_COUNT=0; FAIL_COUNT=0
pass(){ echo "    ok   - $1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail(){ echo "    FAIL - $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
assert_eq(){ [[ "$1" == "$2" ]] && pass "$3" || fail "$3 (got '$1', want '$2')"; }
assert_contains(){ [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3 (missing '$2')"; }
assert_file(){ [[ -f "$1" ]] && pass "$2" || fail "$2 (no $1)"; }
assert_no_file(){ [[ ! -f "$1" ]] && pass "$2" || fail "$2 ($1 exists)"; }

# Freshness and docs reparse without the build's --vars and overwrite the manifest.
# Docs also overwrites run_results.json with its own results.
read -r -d '' STUB_DBT <<'SH' || true
#!/usr/bin/env bash
mkdir -p target
args=" $* "
case "$args" in
  *" docs generate "*)
    if [[ "${STUB_DOCS_MISSING_STATIC:-false}" != "true" ]]; then
      cat > target/static_index.html <<'HTML'
<script>
const manifest = {"nodes":{"model.p.a":{"alias":"a"}}};
const catalog = {"nodes":{"model.p.a":{"columns":{"id":{"name":"id"}}}}};
</script>
HTML
    fi
    echo '{"written_by": "docs", "results": []}' > target/run_results.json
    echo '{"nodes": {"model.p.a": {"alias": "a"}}, "written_by": "docs"}' > target/manifest.json
    echo '<html>docs</html>' > target/index.html
    exit "${STUB_DOCS_EXIT:-0}" ;;
  *" source freshness "*)
    echo '{"sources": [{"status": "pass"}]}' > target/sources.json
    echo '{"nodes": {"model.p.a": {"alias": "a"}}, "written_by": "freshness"}' > target/manifest.json
    exit "${STUB_FRESHNESS_EXIT:-0}" ;;
  *" build "*)
    model_alias=a
    if [[ "$args" == *' --vars {"alias":"build_alias"} '* ]]; then
      model_alias=build_alias
    fi
    if [[ "${STUB_BUILD_MODE:-}" != missing_manifest ]]; then
      printf '{"nodes": {"model.p.a": {"alias": "%s"}}}\n' "$model_alias" > target/manifest.json
    fi
    m=$(printf '{"unique_id": "model.p.a", "status": "success", "relation_name": "db.analytics.%s"}' "$model_alias")
    t='{"unique_id": "test.p.t", "status": "pass"}'
    case "${STUB_BUILD_MODE:-}" in
      crash)  # parse/compile error: dbt raises before writing run_results.json
        rm -f target/run_results.json
        exit "${STUB_BUILD_EXIT:-0}" ;;
      missing_results)
        exit "${STUB_BUILD_EXIT:-0}" ;;
      test_fail)  # every model built, a data test failed
        t='{"unique_id": "test.p.t", "status": "fail"}' ;;
      *)
        if [[ "${STUB_BUILD_EXIT:-0}" != "0" ]]; then  # a model errored, its child skipped
          m='{"unique_id": "model.p.a", "status": "error"}, {"unique_id": "model.p.b", "status": "skipped"}'
        fi ;;
    esac
    echo "{\"written_by\": \"build\", \"results\": [$m, $t]}" > target/run_results.json
    exit "${STUB_BUILD_EXIT:-0}" ;;
esac
exit 0
SH

read -r -d '' STUB_STORAGE <<'PY' || true
import os


class _Blob:
    def __init__(self, bucket, name):
        if bucket == os.environ.get("STUB_FAIL_BUCKET"):
            raise RuntimeError(f"stub: upload to {bucket} failed")
        self.path = os.path.join(os.environ["UPLOAD_ROOT"], bucket, name)

    def upload_from_file(self, handle, content_type=None):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "wb") as out:
            out.write(handle.read())


class _Bucket:
    def __init__(self, name):
        self.name = name

    def blob(self, name):
        return _Blob(self.name, name)


class Client:
    def bucket(self, name):
        return _Bucket(name)
PY

# run_entrypoint <build_exit> <freshness_exit> [VAR=value ...]; sets SANDBOX, RC, OUT.
run_entrypoint(){
  SANDBOX=$(mktemp -d)
  mkdir -p "$SANDBOX/bin" "$SANDBOX/stubs/google/cloud" "$SANDBOX/profiles"
  printf '%s\n' "$STUB_DBT" > "$SANDBOX/bin/dbt"
  # -S skips site-packages, whose *-nspkg.pth files can import the real `google`
  # namespace before PYTHONPATH shadows it.
  printf '#!/usr/bin/env bash\nexec python3 -S "$@"\n' > "$SANDBOX/bin/python"
  chmod +x "$SANDBOX/bin/dbt" "$SANDBOX/bin/python"
  : > "$SANDBOX/stubs/google/__init__.py"; : > "$SANDBOX/stubs/google/cloud/__init__.py"
  printf '%s\n' "$STUB_STORAGE" > "$SANDBOX/stubs/google/cloud/storage.py"
  : > "$SANDBOX/profiles/profiles.yml"
  cp "$REPO_ROOT/entrypoint.sh" "$SANDBOX/"
  mkdir -p "$SANDBOX/scripts"; cp -R "$REPO_ROOT/scripts/lib" "$SANDBOX/scripts/"
  OUT=$(cd "$SANDBOX" && env -i PATH="$SANDBOX/bin:/usr/bin:/bin" HOME="$SANDBOX" \
      PYTHONPATH="$SANDBOX/stubs" UPLOAD_ROOT="$SANDBOX/uploads" \
      DBT_TARGET=prod DBT_PROFILES_DIR="$SANDBOX/profiles" RUN_FRESHNESS=true \
      RUN_DBT_DEBUG=false GENERATE_DOCS=true \
      DBT_ARTIFACTS_BUCKET=artifacts DBT_DOCS_BUCKET=docs \
      STUB_BUILD_EXIT="$1" STUB_FRESHNESS_EXIT="$2" "${@:3}" bash entrypoint.sh 2>&1)
  RC=$?
}

echo "scenario: full build with alias override → upload the manifest and results from that build"
run_entrypoint 0 0 'DBT_BUILD_ARGS=--vars {"alias":"build_alias"}'
assert_eq "$RC" "0" "exits 0"
assert_contains "$(cat "$SANDBOX/uploads/artifacts/prod/run_results.json" 2>/dev/null)" '"written_by": "build"' "uploaded run_results.json is the build's"
assert_contains "$(cat "$SANDBOX/uploads/artifacts/prod/run_results.json" 2>/dev/null)" '"relation_name": "db.analytics.build_alias"' "build results record the overridden alias"
assert_eq "$(cat "$SANDBOX/uploads/artifacts/prod/manifest.json" 2>/dev/null)" '{"nodes": {"model.p.a": {"alias": "build_alias"}}}' "manifest upload matches the build output"
assert_contains "$(cat "$SANDBOX/target/manifest.json")" '"alias": "a"' "docs regenerated the working manifest with the default alias"
assert_file "$SANDBOX/uploads/docs/index.html" "docs uploaded"

echo "scenario: the build writes no manifest → later manifests cannot replace prod state"
run_entrypoint 0 0 STUB_BUILD_MODE=missing_manifest
assert_eq "$RC" "0" "a successful build still exits 0"
assert_contains "$OUT" "the build's manifest.json is missing" "logs why the manifest was kept"
assert_file "$SANDBOX/target/manifest.json" "a later step wrote a manifest"
assert_no_file "$SANDBOX/uploads/artifacts/prod/manifest.json" "the later manifest was not uploaded"
assert_contains "$(cat "$SANDBOX/uploads/artifacts/prod/run_results.json" 2>/dev/null)" '"written_by": "build"' "the build's results were still uploaded"
assert_file "$SANDBOX/uploads/artifacts/prod/sources.json" "freshness results were still uploaded"

echo "scenario: the build writes no run results → docs results cannot qualify a manifest"
run_entrypoint 0 0 STUB_BUILD_MODE=missing_results
assert_eq "$RC" "1" "summary exits 1 for missing build results"
assert_file "$SANDBOX/target/run_results.json" "docs wrote run results"
assert_no_file "$SANDBOX/uploads/artifacts/prod/run_results.json" "the docs results were not uploaded"
assert_no_file "$SANDBOX/uploads/artifacts/prod/manifest.json" "manifest stayed unpublished"

echo "scenario: a model errored → summary and run_results still published, manifest kept, job still fails"
run_entrypoint 1 0
assert_eq "$RC" "1" "exits with dbt build's code"
assert_contains "$OUT" '"dbt_summary"' "dbt_summary line emitted"
assert_contains "$OUT" '"failed": 1' "summary counts the failed node"
assert_contains "$OUT" "not built: model.p.a (error), model.p.b (skipped)" "logs why the manifest was kept"
assert_contains "$(cat "$SANDBOX/uploads/artifacts/prod/run_results.json" 2>/dev/null)" '"status": "error"' "failed build's run_results.json uploaded"
assert_file "$SANDBOX/uploads/artifacts/prod/sources.json" "sources.json uploaded (freshness still ran)"
assert_no_file "$SANDBOX/uploads/artifacts/prod/manifest.json" "manifest.json not uploaded (CI keeps deferring to the last good one)"
assert_no_file "$SANDBOX/uploads/docs/index.html" "docs not regenerated"

echo "scenario: green build, freshness breach → everything published, job still fails"
run_entrypoint 0 1
assert_eq "$RC" "1" "exits with dbt source freshness's code"
assert_contains "$OUT" '"dbt_summary"' "dbt_summary line emitted"
assert_contains "$(cat "$SANDBOX/uploads/artifacts/prod/run_results.json" 2>/dev/null)" '"written_by": "build"' "build's run_results.json uploaded"
assert_file "$SANDBOX/uploads/artifacts/prod/manifest.json" "manifest.json uploaded (the build was green)"
uploaded_docs=$(cat "$SANDBOX/uploads/docs/index.html" 2>/dev/null)
assert_contains "$uploaded_docs" 'const manifest = {"nodes":{"model.p.a":{"alias":"a"}}};' "index.html contains the embedded manifest"
assert_contains "$uploaded_docs" 'const catalog = {"nodes":{"model.p.a":{"columns":{"id":{"name":"id"}}}}};' "index.html contains the embedded catalog"

echo "scenario: every model built, a data test failed → new manifest published, job still fails"
run_entrypoint 1 0 STUB_BUILD_MODE=test_fail
assert_eq "$RC" "1" "exits with dbt build's code"
assert_contains "$OUT" '"fail": 1' "summary counts the failed test"
assert_file "$SANDBOX/uploads/artifacts/prod/manifest.json" "manifest.json uploaded (every model built)"
assert_contains "$OUT" "test failures/warnings only" "logs why the manifest was uploaded"
assert_contains "$(cat "$SANDBOX/uploads/artifacts/prod/run_results.json" 2>/dev/null)" '"status": "fail"' "build's run_results.json uploaded"

echo "scenario: build dies before writing run_results.json → manifest kept, job still fails"
run_entrypoint 2 0 STUB_BUILD_MODE=crash
assert_eq "$RC" "2" "exits with dbt build's code"
assert_contains "$OUT" '"missing_run_results"' "summary reports missing_run_results"
assert_no_file "$SANDBOX/uploads/artifacts/prod/manifest.json" "manifest.json not uploaded"
assert_no_file "$SANDBOX/uploads/artifacts/prod/run_results.json" "no run_results.json uploaded"
assert_file "$SANDBOX/uploads/artifacts/prod/sources.json" "sources.json uploaded (freshness still ran)"

echo "scenario: exit 1 but run_results.json is missing → manifest kept"
run_entrypoint 1 0 STUB_BUILD_MODE=crash
assert_eq "$RC" "1" "exits with dbt build's code"
assert_no_file "$SANDBOX/uploads/artifacts/prod/manifest.json" "manifest.json not uploaded"
assert_contains "$OUT" "run_results.json is missing or unreadable" "logs why the manifest was kept"

echo "scenario: green build, docs generate fails → artifacts still published, job still fails"
run_entrypoint 0 0 STUB_DOCS_EXIT=3
assert_eq "$RC" "3" "exits with dbt docs generate's code"
assert_file "$SANDBOX/uploads/artifacts/prod/manifest.json" "manifest.json uploaded"
assert_contains "$(cat "$SANDBOX/uploads/artifacts/prod/run_results.json" 2>/dev/null)" '"written_by": "build"' "build's run_results.json uploaded"
assert_no_file "$SANDBOX/uploads/docs/index.html" "docs not uploaded"

echo "scenario: green build, docs upload fails → artifacts still published, job still fails"
run_entrypoint 0 0 STUB_FAIL_BUCKET=docs
assert_eq "$RC" "1" "exits with upload_docs.py's code"
assert_file "$SANDBOX/uploads/artifacts/prod/manifest.json" "manifest.json uploaded"
assert_file "$SANDBOX/uploads/artifacts/prod/run_results.json" "run_results.json uploaded"

echo "scenario: docs generation returns zero without a standalone page → docs step fails"
run_entrypoint 0 0 STUB_DOCS_MISSING_STATIC=true
assert_eq "$RC" "1" "missing standalone docs give the job a non-zero exit"
assert_contains "$OUT" "dbt docs generate did not write target/static_index.html" "logs the missing standalone page"
assert_no_file "$SANDBOX/uploads/docs/index.html" "the docs shell was not published"
assert_file "$SANDBOX/uploads/artifacts/prod/manifest.json" "manifest.json still uploaded"
assert_file "$SANDBOX/uploads/artifacts/prod/run_results.json" "run_results.json still uploaded"
assert_file "$SANDBOX/uploads/artifacts/prod/sources.json" "sources.json still uploaded"

echo "scenario: failed build and failed freshness → build's code wins"
run_entrypoint 1 4
assert_eq "$RC" "1" "exits with dbt build's code"

echo
echo "passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
