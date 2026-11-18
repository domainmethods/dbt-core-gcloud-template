#!/usr/bin/env python3
"""Publish dbt's standalone docs as index.html in GCS."""
import os
import sys

from google.cloud import storage

bucket_name = os.environ.get("DBT_DOCS_BUCKET") or os.environ.get("DBT_ARTIFACTS_BUCKET")
path = os.path.join("target", "static_index.html")
if not os.path.isfile(path):
    sys.exit(f"dbt docs generate did not write {path}. Existing docs are kept.")
print(f"Docs generated at {path}")

if not bucket_name:
    print("No docs bucket configured; skipping upload")
    sys.exit(0)

client = storage.Client()
bucket = client.bucket(bucket_name)
blob = bucket.blob("index.html")
blob.cache_control = "no-cache"
blob.content_type = "text/html"
with open(path, "rb") as f:
    blob.upload_from_file(f, content_type="text/html")
print(f"Uploaded to gs://{bucket_name}/index.html")
