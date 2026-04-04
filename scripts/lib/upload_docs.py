#!/usr/bin/env python3
"""Upload dbt docs (target/index.html) to GCS bucket."""
import os
import sys

from google.cloud import storage

bucket_name = os.environ.get("DBT_DOCS_BUCKET") or os.environ.get("DBT_ARTIFACTS_BUCKET")
if not bucket_name:
    print("No docs bucket configured; skipping upload")
    sys.exit(0)

path = os.path.join("target", "index.html")
if not os.path.exists(path):
    print(f"No {path} found; skipping upload")
    sys.exit(0)

client = storage.Client()
bucket = client.bucket(bucket_name)
blob = bucket.blob("index.html")
blob.cache_control = "no-cache"
blob.content_type = "text/html"
with open(path, "rb") as f:
    blob.upload_from_file(f, content_type="text/html")
print(f"Uploaded to gs://{bucket_name}/index.html")
