#!/usr/bin/env python3
"""Upload dbt artifacts (manifest, run_results, sources) to GCS for Slim CI deferral."""
import os
import sys

from google.cloud import storage

bucket_name = os.environ.get("DBT_ARTIFACTS_BUCKET")
if not bucket_name:
    print("DBT_ARTIFACTS_BUCKET not set; skipping artifact upload")
    sys.exit(0)

# CI defers against prod/manifest.json, so only a green build replaces it.
build_ok = os.environ.get("BUILD_EXIT", "0") == "0"
paths = {
    "manifest.json": os.path.join("target", "manifest.json") if build_ok else "",
    # docs generate rewrites target/run_results.json; upload the build's copy.
    "run_results.json": os.environ.get("DBT_RUN_RESULTS_PATH") or os.path.join("target", "run_results.json"),
    "sources.json": os.path.join("target", "sources.json"),
}

client = storage.Client()
bucket = client.bucket(bucket_name)
for name, p in paths.items():
    if not p:
        print(f"Skipping {name}: the build failed, so CI keeps the last good one")
    elif os.path.exists(p):
        blob = bucket.blob(f"prod/{name}")
        blob.cache_control = "no-cache"
        blob.content_type = "application/json"
        with open(p, "rb") as f:
            blob.upload_from_file(f, content_type="application/json")
        print(f"Uploaded gs://{bucket_name}/prod/{name}")
    else:
        print(f"Skipping missing {p}")
