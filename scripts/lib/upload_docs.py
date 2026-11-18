#!/usr/bin/env python3
"""Publish dbt's standalone docs as index.html in GCS."""
import os
import sys

from google.cloud import storage

from artifact_publication import cloud_run_order, publish

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
publish(bucket, "index.html", path, "text/html", cloud_run_order())
