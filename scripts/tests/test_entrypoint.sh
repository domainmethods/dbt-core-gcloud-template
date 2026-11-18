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
      cat > target/static_index.html <<HTML
<script>
// fixture: ${STUB_FIXTURE:-local}
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
    echo "{\"fixture\": \"${STUB_FIXTURE:-local}\", \"sources\": [{\"status\": \"pass\"}]}" > target/sources.json
    echo '{"nodes": {"model.p.a": {"alias": "a"}}, "written_by": "freshness"}' > target/manifest.json
    exit "${STUB_FRESHNESS_EXIT:-0}" ;;
  *" build "*)
    model_alias=a
    if [[ "$args" == *' --vars {"alias":"build_alias"} '* ]]; then
      model_alias=build_alias
    fi
    if [[ "${STUB_BUILD_MODE:-}" != missing_manifest ]]; then
      cat > build-manifest.json <<JSON
{
  "fixture": "${STUB_FIXTURE:-local}",
  "nodes": {
    "model.p.a": {"resource_type": "model", "alias": "$model_alias", "config": {"enabled": true, "materialized": "view"}},
    "model.p.b": {"resource_type": "model", "config": {"enabled": true, "materialized": "table"}},
    "seed.p.lookup": {"resource_type": "seed", "config": {"enabled": true, "materialized": "seed"}},
    "snapshot.p.history": {"resource_type": "snapshot", "config": {"enabled": true, "materialized": "snapshot"}},
    "model.p.inline": {"resource_type": "model", "config": {"enabled": true, "materialized": "ephemeral"}},
    "test.p.t": {"resource_type": "test", "config": {"enabled": true}}
  },
  "disabled": {
    "model.p.disabled": [{"resource_type": "model", "config": {"enabled": false, "materialized": "table"}}]
  }
}
JSON
      cp build-manifest.json target/manifest.json
    fi
    case "${STUB_BUILD_MODE:-}" in
      crash|missing_results)
        exit "${STUB_BUILD_EXIT:-0}" ;;
      bad_manifest)
        echo '{' > target/manifest.json ;;
    esac
    results=()
    for uid in model.p.a model.p.b seed.p.lookup snapshot.p.history test.p.t; do
      name="${uid##*.}"
      [[ "$args" == *" --exclude $name "* ]] && continue
      status=success
      relation="$name"
      case "$uid" in
        model.p.a) relation="$model_alias" ;;
        test.p.t) status=pass ;;
      esac
      if [[ "${STUB_BUILD_MODE:-}" == test_fail ]]; then
        [[ "$uid" == test.p.t ]] && status=fail
      elif [[ "${STUB_BUILD_EXIT:-0}" != 0 ]]; then
        case "$uid" in
          model.p.a) status=error ;;
          model.p.b) status=skipped ;;
        esac
      fi
      results+=("$(printf '{"unique_id": "%s", "status": "%s", "relation_name": "db.analytics.%s"}' "$uid" "$status" "$relation")")
    done
    IFS=,
    printf '{"written_by": "build", "fixture": "%s", "results": [%s]}\n' "${STUB_FIXTURE:-local}" "${results[*]}" > target/run_results.json
    exit "${STUB_BUILD_EXIT:-0}" ;;
esac
exit 0
SH

read -r -d '' STUB_STORAGE <<'PY' || true
import json
import os
import time
from pathlib import Path

from google.api_core.exceptions import PreconditionFailed


class _Blob:
    def __init__(self, bucket, name):
        if bucket == os.environ.get("STUB_FAIL_BUCKET"):
            raise RuntimeError(f"stub: upload to {bucket} failed")
        self.name = name
        self.path = Path(os.environ["UPLOAD_ROOT"], bucket, name)
        self.state_path = self.path.with_suffix(".metadata")
        self.metadata = None

    def read_state(self):
        return json.loads(self.state_path.read_text()) if self.state_path.exists() else None

    def upload_from_file(self, handle, content_type=None, if_generation_match=None):
        self._write(handle.read(), if_generation_match)

    def upload_from_filename(self, filename, content_type=None, if_generation_match=None):
        self._write(Path(filename).read_bytes(), if_generation_match)

    def _write(self, data, if_generation_match):
        pause = os.environ.get("STUB_PAUSE_MANIFEST")
        if pause and self.path.name == "manifest.json":
            Path(pause + ".ready").touch()
            deadline = time.monotonic() + 30
            while not Path(pause + ".resume").exists():
                if time.monotonic() > deadline:
                    raise RuntimeError("stub: timed out waiting for the other publisher")
                time.sleep(0.01)
        state = self.read_state()
        generation = state["generation"] if state else 0
        if if_generation_match is not None and if_generation_match != generation:
            print("stub: generation changed")
            raise PreconditionFailed("stub: generation changed")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_bytes(data)
        self.state_path.write_text(json.dumps({"generation": generation + 1, "metadata": self.metadata}))


class _Bucket:
    def __init__(self, name):
        self.name = name

    def blob(self, name):
        return _Blob(self.name, name)

    def get_blob(self, name):
        blob = self.blob(name)
        state = blob.read_state()
        if state is None:
            return None
        blob.generation = state["generation"]
        blob.metadata = state["metadata"]
        return blob


class Client:
    def bucket(self, name):
        return _Bucket(name)
PY

# run_entrypoint <build_exit> <freshness_exit> [VAR=value ...]; sets SANDBOX, RC, OUT.
run_entrypoint(){
  SANDBOX=$(mktemp -d)
  local stubs="$SANDBOX/stubs"
  mkdir -p "$SANDBOX/bin" "$stubs/google/"{cloud,api_core,auth/transport} "$SANDBOX/profiles"
  printf '%s\n' "$STUB_DBT" > "$SANDBOX/bin/dbt"
  # -S skips site-packages, whose *-nspkg.pth files can import the real `google`
  # namespace before PYTHONPATH shadows it.
  printf '#!/usr/bin/env bash\nexec python3 -S "$@"\n' > "$SANDBOX/bin/python"
  chmod +x "$SANDBOX/bin/dbt" "$SANDBOX/bin/python"
  : > "$stubs/google/__init__.py"; : > "$stubs/google/cloud/__init__.py"
  printf '%s\n' "$STUB_STORAGE" > "$stubs/google/cloud/storage.py"
  printf 'class PreconditionFailed(Exception): pass\n' > "$stubs/google/api_core/exceptions.py"
  printf 'def default(scopes): return object(), None\n' > "$stubs/google/auth/__init__.py"
  cat > "$stubs/requests.py" <<'PY'
class ConnectionError(OSError):
    pass


class Timeout(OSError):
    pass


class MetadataResponse:
    status_code = 200
    text = "projects/123/regions/us-central1"

    def raise_for_status(self):
        pass


def get(url, *, headers, timeout):
    assert url == "http://metadata.google.internal/computeMetadata/v1/instance/region"
    assert headers == {"Metadata-Flavor": "Google"}
    return MetadataResponse()
PY
  cat > "$stubs/google/auth/transport/requests.py" <<'PY'
import os

import requests

# Comma-separated outcomes for successive execution lookups before a success:
# an HTTP status code or "conn" for a connection error.
FAILURES = [f for f in os.environ.get("STUB_EXECUTION_FAILURES", "").split(",") if f]


class AuthorizedSession:
    status_code = 200

    def __init__(self, credentials):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        pass

    def get(self, url, *, timeout):
        assert url == ("https://run.googleapis.com/v2/projects/123/locations/us-central1/"
                       "jobs/dbt-prod-run/executions/" + os.environ["CLOUD_RUN_EXECUTION"])
        print(f"stub: execution lookup {url}")
        self.status_code = 200
        if FAILURES:
            outcome = FAILURES.pop(0)
            if outcome == "conn":
                raise requests.ConnectionError("stub: connection reset")
            self.status_code = int(outcome)
        return self

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"stub: execution lookup HTTP {self.status_code}")
        if os.environ.get("STUB_EXECUTION_DENIED"):
            raise RuntimeError("stub: run.executions.get denied")

    def json(self):
        return {"createTime": os.environ["STUB_CREATED_AT"]}
PY
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
cmp -s "$SANDBOX/build-manifest.json" "$SANDBOX/uploads/artifacts/prod/manifest.json" \
  && pass "manifest upload matches the build output" || fail "manifest upload differs from the build output"
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

for node in model.p.b seed.p.lookup snapshot.p.history; do
  echo "scenario: successful --exclude ${node##*.} → incomplete build keeps the prior manifest"
  run_entrypoint 0 0 "DBT_BUILD_ARGS=--exclude ${node##*.}"
  assert_eq "$RC" "0" "selected build still exits 0"
  assert_contains "$OUT" "not built: $node (no result)" "logs the relation without a result"
  assert_no_file "$SANDBOX/uploads/artifacts/prod/manifest.json" "incomplete build manifest was not uploaded"
  assert_contains "$(cat "$SANDBOX/uploads/artifacts/prod/run_results.json" 2>/dev/null)" '"written_by": "build"' "selected build's results still uploaded"
  assert_file "$SANDBOX/uploads/artifacts/prod/sources.json" "freshness results still uploaded"
done

echo "scenario: exclude only a test → every persisted relation still qualifies"
run_entrypoint 0 0 'DBT_BUILD_ARGS=--exclude t'
assert_eq "$RC" "0" "build still exits 0"
assert_file "$SANDBOX/uploads/artifacts/prod/manifest.json" "complete manifest uploaded"

echo "scenario: unreadable build manifest → diagnostics still uploaded"
run_entrypoint 0 0 STUB_BUILD_MODE=bad_manifest
assert_eq "$RC" "0" "build still exits 0"
assert_contains "$OUT" "the build's manifest.json is missing or unreadable" "logs why the manifest was kept"
assert_no_file "$SANDBOX/uploads/artifacts/prod/manifest.json" "unreadable manifest was not uploaded"
assert_file "$SANDBOX/uploads/artifacts/prod/run_results.json" "run results still uploaded"

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

run_cloud_entrypoint(){  # <shared uploads> <fixture> <execution createTime> <build exit> <freshness exit> [VAR=value ...]
  local uploads="$1" fixture="$2" created="$3"
  shift 3
  run_entrypoint "$@" UPLOAD_ROOT="$uploads" CLOUD_RUN_JOB=dbt-prod-run \
    CLOUD_RUN_EXECUTION="dbt-prod-run-$fixture" STUB_FIXTURE="$fixture" STUB_CREATED_AT="$created"
}

scheduled_time=2026-11-18T12:00:00Z
release_time=2026-11-18T12:00:00.000000001Z

echo "scenario: a release publishes first, then an older scheduled execution finishes (#119)"
run_entrypoint 0 0 STUB_FIXTURE=legacy
shared="$SANDBOX/uploads"
run_cloud_entrypoint "$shared" release "$release_time" 0 0
assert_eq "$RC" "0" "release adopts existing unmarked objects"
run_cloud_entrypoint "$shared" scheduled "$scheduled_time" 0 0
assert_eq "$RC" "0" "superseded execution still succeeds"
for name in manifest.json run_results.json sources.json; do
  assert_contains "$(cat "$shared/artifacts/prod/$name")" '"fixture": "release"' "keeps release $name"
done
assert_contains "$(cat "$shared/docs/index.html")" "fixture: release" "keeps release docs"
docs_order=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["metadata"]["dbt-cloud-run-execution-order"])' \
  "$shared/docs/index.metadata")
release_digest=$(python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' \
  "projects/123/locations/us-central1/jobs/dbt-prod-run/executions/dbt-prod-run-release")
assert_eq "$docs_order" "2026-11-18T12:00:00.000000001Z/$release_digest" \
  "public docs order holds only createTime and an execution digest"
assert_file "$shared/artifacts/prod/runs/dbt-prod-run-scheduled/sources.json" "keeps stale execution's freshness diagnostics"

run_cloud_entrypoint "$shared" scheduled "$scheduled_time" 2 4
assert_eq "$RC" "2" "superseded retry still exits with its build code"
assert_contains "$(cat "$shared/artifacts/prod/runs/dbt-prod-run-scheduled/run_results.json" 2>/dev/null)" \
  '"status": "error"' "archives the stale retry's failed build diagnostics"
assert_contains "$(cat "$shared/artifacts/prod/run_results.json")" '"fixture": "release"' "retry keeps release diagnostics"

run_cloud_entrypoint "$shared" denied "$release_time" 2 0 STUB_EXECUTION_DENIED=1
assert_eq "$RC" "2" "preserves the build failure when execution lookup fails"
assert_contains "$OUT" 'run.executions.get denied' "logs execution lookup failure"
assert_file "$shared/artifacts/prod/runs/dbt-prod-run-denied/run_results.json" "archives diagnostics without an ordering key"
assert_contains "$(cat "$shared/artifacts/prod/run_results.json")" '"fixture": "release"' "lookup failure leaves canonical diagnostics intact"

echo "scenario: transient execution lookup failures are retried"
run_cloud_entrypoint "$shared" release "$release_time" 0 0 STUB_EXECUTION_FAILURES=503,conn
assert_eq "$RC" "0" "publishes after a 503 and a connection error"
assert_contains "$OUT" "after HTTP 503 (attempt 1/3)" "logs the 5xx retry"
assert_contains "$OUT" "after ConnectionError (attempt 2/3)" "logs the connection retry"

run_cloud_entrypoint "$shared" release "$release_time" 0 0 STUB_EXECUTION_FAILURES=503,503,503,503
assert_eq "$RC" "1" "fails once the lookup retries are exhausted"
assert_eq "$(grep -c '^stub: execution lookup https:' <<< "$OUT")" "6" "docs and artifact uploaders each make three lookup attempts"
assert_contains "$OUT" "stub: execution lookup HTTP 503" "surfaces the final 5xx"

run_cloud_entrypoint "$shared" release "$release_time" 0 0 STUB_EXECUTION_FAILURES=403
assert_eq "$RC" "1" "a permission error fails"
assert_eq "$(grep -c '^stub: execution lookup https:' <<< "$OUT")" "2" "does not retry a 4xx (one lookup per uploader)"

run_entrypoint 0 0 UPLOAD_ROOT="$shared"
assert_eq "$RC" "1" "a local writer cannot replace fenced objects without an execution identity"
assert_contains "$(cat "$shared/artifacts/prod/manifest.json")" '"fixture": "release"' "keeps fenced manifest"

for blocked in scheduled release; do
  echo "scenario: $blocked loses a same-object generation race (#119)"
  race=$(mktemp -d)
  if [[ "$blocked" == scheduled ]]; then
    run_entrypoint 0 0 UPLOAD_ROOT="$race/uploads"
    assert_eq "$RC" "0" "starts the race with an existing manifest generation"
    contested="$scheduled_time"; other=release; other_time="$release_time"
  else
    contested="$release_time"; other=scheduled; other_time="$scheduled_time"
  fi
  (
    run_cloud_entrypoint "$race/uploads" "$blocked" "$contested" 0 0 STUB_PAUSE_MANIFEST="$race/manifest"
    echo "$OUT"
    exit "$RC"
  ) > "$race/blocked.log" &
  blocked_pid=$!
  for ((i = 0; i < 600; i++)); do
    [[ -f "$race/manifest.ready" ]] && break
    kill -0 "$blocked_pid" 2>/dev/null || break
    sleep 0.05
  done
  assert_file "$race/manifest.ready" "first writer reaches manifest upload"
  run_cloud_entrypoint "$race/uploads" "$other" "$other_time" 0 0
  assert_eq "$RC" "0" "second writer publishes while the first is paused"
  : > "$race/manifest.resume"
  wait "$blocked_pid"
  assert_eq "$?" "0" "paused writer resolves the conflict"
  assert_contains "$(cat "$race/blocked.log")" "stub: generation changed" "GCS rejects the stale generation"
  assert_contains "$(cat "$race/uploads/artifacts/prod/manifest.json")" '"fixture": "release"' "release wins either write order"
done

echo
echo "passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
