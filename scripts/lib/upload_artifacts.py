#!/usr/bin/env python3
"""Upload dbt artifacts (manifest, run_results, sources) to GCS for Slim CI deferral."""
import os
import sys

from google.cloud import storage

bucket_name = os.environ.get("DBT_ARTIFACTS_BUCKET")
if not bucket_name:
    print("DBT_ARTIFACTS_BUCKET not set; skipping artifact upload")
    sys.exit(0)

client = storage.Client()
bucket = client.bucket(bucket_name)
for name in ("manifest.json", "run_results.json", "sources.json"):
    p = os.path.join("target", name)
    if os.path.exists(p):
        blob = bucket.blob(f"prod/{name}")
        blob.cache_control = "no-cache"
        blob.content_type = "application/json"
        with open(p, "rb") as f:
            blob.upload_from_file(f, content_type="application/json")
        print(f"Uploaded gs://{bucket_name}/prod/{name}")
    else:
        print(f"Skipping missing {p}")
