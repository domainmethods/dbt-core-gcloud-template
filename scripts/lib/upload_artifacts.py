#!/usr/bin/env python3
"""Upload dbt artifacts (manifest, run_results, sources) to GCS for Slim CI deferral."""
import json
import os
import sys

from google.cloud import storage

bucket_name = os.environ.get("DBT_ARTIFACTS_BUCKET")
if not bucket_name:
    print("DBT_ARTIFACTS_BUCKET not set; skipping artifact upload")
    sys.exit(0)

# The entrypoint saves these before freshness and docs can replace them.
run_results_path = os.environ.get("DBT_RUN_RESULTS_PATH") or os.path.join("target", "run_results.json")
build_manifest_path = os.environ.get("DBT_BUILD_MANIFEST_PATH", "")

# Resource types whose prod relation is (re)built from the manifest.
BUILT_TYPES = ("model", "seed", "snapshot")


def manifest_decision():
    """Return (upload, reason). CI defers against prod/manifest.json and diffs
    schemas against it, so replace it only after every enabled persisted
    model, seed and snapshot in the build manifest succeeds."""
    raw_exit = os.environ.get("BUILD_EXIT", "0")
    try:
        build_exit = int(raw_exit)
    except ValueError:
        return False, f"BUILD_EXIT={raw_exit!r} is not an exit code"
    if build_exit >= 2:
        return False, f"dbt build exited {build_exit} (runtime/internal error, not a node failure)"
    try:
        with open(run_results_path) as f:
            statuses = {r["unique_id"]: r["status"] for r in json.load(f)["results"]}
    except (KeyError, OSError, TypeError, ValueError) as e:
        return False, f"the build's run_results.json is missing or unreadable ({e})"
    try:
        with open(build_manifest_path) as f:
            nodes = json.load(f)["nodes"]
        expected = [
            uid
            for uid, node in nodes.items()
            if node["resource_type"] in BUILT_TYPES
            and node["config"]["enabled"]
            and node["config"]["materialized"] != "ephemeral"
        ]
    except (AttributeError, KeyError, OSError, TypeError, ValueError) as e:
        return False, f"the build's manifest.json is missing or unreadable ({e})"
    not_built = [
        f"{uid} ({statuses.get(uid, 'no result')})"
        for uid in sorted(expected)
        if statuses.get(uid) != "success"
    ]
    if not_built:
        return False, "not built: " + ", ".join(not_built)
    if build_exit == 0:
        return True, "dbt build succeeded"
    if not any(status in ("error", "fail") for status in statuses.values()):
        return False, f"dbt build exited {build_exit} but run_results.json shows no failing node"
    return True, f"dbt build exited {build_exit} with test failures/warnings only; every model/seed/snapshot built"


upload_manifest, reason = manifest_decision()
print(f"manifest.json: {'uploading' if upload_manifest else 'keeping the last uploaded one'}: {reason}")
paths = {
    "manifest.json": build_manifest_path if upload_manifest else "",
    "run_results.json": run_results_path,
    "sources.json": os.path.join("target", "sources.json"),
}

client = storage.Client()
bucket = client.bucket(bucket_name)
for name, p in paths.items():
    if not p:
        print(f"Skipping {name} (see reason above)")
    elif os.path.exists(p):
        blob = bucket.blob(f"prod/{name}")
        blob.cache_control = "no-cache"
        blob.content_type = "application/json"
        with open(p, "rb") as f:
            blob.upload_from_file(f, content_type="application/json")
        print(f"Uploaded gs://{bucket_name}/prod/{name}")
    else:
        print(f"Skipping missing {p}")
