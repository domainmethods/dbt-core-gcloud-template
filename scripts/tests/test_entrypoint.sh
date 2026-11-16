#!/usr/bin/env bash
# Tests for entrypoint.sh — a failed `dbt build` or `dbt source freshness` must
# still emit the summary and upload run_results.json (#20), the uploaded
# run_results.json must be the build's and not `docs generate`'s, and the job
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

# Each dbt subcommand writes a run_results.json that names it, so the test can
# tell which step's file was uploaded. STUB_BUILD_EXIT / STUB_FRESHNESS_EXIT
# make a step fail after writing its artifacts, as real dbt does.
read -r -d '' STUB_DBT <<'SH' || true
#!/usr/bin/env bash
mkdir -p target
args=" $* "
case "$args" in
  *" docs generate "*)
    echo '{"written_by": "docs", "results": []}' > target/run_results.json
    echo '<html>docs</html>' > target/index.html ;;
  *" source freshness "*)
    echo '{"sources": [{"status": "pass"}]}' > target/sources.json
    exit "${STUB_FRESHNESS_EXIT:-0}" ;;
  *" build "*)
    if [[ "${STUB_BUILD_EXIT:-0}" != "0" ]]; then
      echo '{"written_by": "build", "results": [{"status": "success"}, {"status": "error"}]}' > target/run_results.json
    else
      echo '{"written_by": "build", "results": [{"status": "success"}, {"status": "success"}]}' > target/run_results.json
    fi
    echo '{"written_by": "build"}' > target/manifest.json
    exit "${STUB_BUILD_EXIT:-0}" ;;
esac
exit 0
SH

read -r -d '' STUB_STORAGE <<'PY' || true
import os


class _Blob:
    def __init__(self, bucket, name):
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

# run_entrypoint <build_exit> <freshness_exit>; sets SANDBOX, RC, OUT.
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
      STUB_BUILD_EXIT="$1" STUB_FRESHNESS_EXIT="$2" bash entrypoint.sh 2>&1)
  RC=$?
}

echo "scenario: green build → uploads are the build's, not docs generate's"
run_entrypoint 0 0
assert_eq "$RC" "0" "exits 0"
assert_contains "$(cat "$SANDBOX/uploads/artifacts/prod/run_results.json" 2>/dev/null)" '"written_by": "build"' "uploaded run_results.json is the build's"
assert_file "$SANDBOX/uploads/artifacts/prod/manifest.json" "manifest.json uploaded"
assert_file "$SANDBOX/uploads/docs/index.html" "docs uploaded"

echo "scenario: failed build → summary and run_results still published, job still fails"
run_entrypoint 2 0
assert_eq "$RC" "2" "exits with dbt build's code"
assert_contains "$OUT" '"dbt_summary"' "dbt_summary line emitted"
assert_contains "$OUT" '"failed": 1' "summary counts the failed node"
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
assert_file "$SANDBOX/uploads/docs/index.html" "docs uploaded"

echo
echo "passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
