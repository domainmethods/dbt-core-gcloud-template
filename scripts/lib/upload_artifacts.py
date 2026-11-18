#!/usr/bin/env python3
"""Upload dbt artifacts (manifest, run_results, sources) to GCS for Slim CI deferral."""
import json
import os
import sys

from google.cloud import storage

from artifact_publication import cloud_run_order, publish

bucket_name = os.environ.get("DBT_ARTIFACTS_BUCKET")
if not bucket_name:
    print("DBT_ARTIFACTS_BUCKET not set; skipping artifact upload")
    sys.exit(0)

# docs generate rewrites target/run_results.json; read and upload the build's copy.
run_results_path = os.environ.get("DBT_RUN_RESULTS_PATH") or os.path.join("target", "run_results.json")

# Resource types whose prod relation is (re)built from the manifest.
BUILT_TYPES = ("model", "seed", "snapshot")
# Statuses meaning that relation was not (fully) rebuilt. dbt build skips the
# children of an errored node *and* of a failed test, so a skipped model means
# prod no longer matches the new manifest either way.
NOT_BUILT = ("error", "skipped", "partial success")


def manifest_decision():
    """Return (upload, reason). CI defers against prod/manifest.json and diffs
    schemas against it, so replace it only when every model/seed/snapshot was
    built. Failing tests or warnings alone (dbt exits 1) don't block it."""
    raw_exit = os.environ.get("BUILD_EXIT", "0")
    try:
        build_exit = int(raw_exit)
    except ValueError:
        return False, f"BUILD_EXIT={raw_exit!r} is not an exit code"
    if build_exit >= 2:
        return False, f"dbt build exited {build_exit} (runtime/internal error, not a node failure)"
    try:
        with open(run_results_path) as f:
            results = json.load(f)["results"]
    except Exception as e:
        return False, f"the build's run_results.json is missing or unreadable ({e})"
    not_built = [
        f"{r.get('unique_id')} ({r.get('status')})"
        for r in results
        if str(r.get("unique_id", "")).split(".")[0] in BUILT_TYPES and r.get("status") in NOT_BUILT
    ]
    if not_built:
        return False, "not built: " + ", ".join(not_built)
    if build_exit == 0:
        return True, "dbt build succeeded"
    if not any(r.get("status") in ("error", "fail") for r in results):
        return False, f"dbt build exited {build_exit} but run_results.json shows no failing node"
    return True, f"dbt build exited {build_exit} with test failures/warnings only; every model/seed/snapshot built"


upload_manifest, reason = manifest_decision()
print(f"manifest.json: {'eligible to publish' if upload_manifest else 'keeping the last uploaded one'}: {reason}")
paths = {
    "manifest.json": os.path.join("target", "manifest.json") if upload_manifest else "",
    "run_results.json": run_results_path,
    "sources.json": os.path.join("target", "sources.json"),
}

client = storage.Client()
bucket = client.bucket(bucket_name)
execution = os.environ.get("CLOUD_RUN_EXECUTION")
if execution:
    # Save the run's diagnostics even if it is stale or the execution lookup fails.
    for name in ("run_results.json", "sources.json"):
        if os.path.exists(paths[name]):
            diagnostic = bucket.blob(f"prod/runs/{execution}/{name}")
            diagnostic.upload_from_filename(paths[name], content_type="application/json")
            print(f"Uploaded gs://{bucket_name}/{diagnostic.name}")

order = cloud_run_order()
for name, p in paths.items():
    if not p:
        print(f"Skipping {name} (see reason above)")
    elif os.path.exists(p):
        publish(bucket, f"prod/{name}", p, "application/json", order)
    else:
        print(f"Skipping missing {p}")
