"""Fence shared GCS artifacts by Cloud Run execution order."""
import os
import re

import google.auth
import requests
from google.api_core.exceptions import PreconditionFailed
from google.auth.transport.requests import AuthorizedSession

ORDER_KEY = "dbt-cloud-run-execution-order"


def cloud_run_order():
    job = os.environ.get("CLOUD_RUN_JOB")
    execution = os.environ.get("CLOUD_RUN_EXECUTION")
    if not job and not execution:
        return None
    if not job or not execution:
        raise RuntimeError("Both CLOUD_RUN_JOB and CLOUD_RUN_EXECUTION are required for publication")

    location = requests.get(
        "http://metadata.google.internal/computeMetadata/v1/instance/region",
        headers={"Metadata-Flavor": "Google"}, timeout=10,
    )
    location.raise_for_status()
    _, project, _, region = location.text.strip().split("/")
    resource = f"projects/{project}/locations/{region}/jobs/{job}/executions/{execution}"
    credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    with AuthorizedSession(credentials) as session:
        response = session.get(f"https://run.googleapis.com/v2/{resource}", timeout=10)
        response.raise_for_status()
        created = response.json()["createTime"]

    # Cloud Run returns UTC with variable fractional precision. Pad it for string ordering.
    timestamp = re.fullmatch(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?Z", created)
    if timestamp is None:
        raise ValueError(f"Unexpected Cloud Run createTime for {resource}: {created!r}")
    seconds, fraction = timestamp.groups()
    return f"{seconds}.{(fraction or '').ljust(9, '0')}Z/{resource}"


def publish(bucket, name, path, content_type, order):
    uri = f"gs://{bucket.name}/{name}"
    for _ in range(5):
        current = bucket.get_blob(name)
        previous_order = (current.metadata or {}).get(ORDER_KEY) if current is not None else None
        if previous_order is not None:
            if order is None:
                raise RuntimeError(f"Cloud Run execution identity required to replace {uri}")
            if order < previous_order:
                print(f"Skipping stale publication of {uri} ({order} < {previous_order})")
                return

        blob = bucket.blob(name)
        blob.cache_control = "no-cache"
        if order is not None:
            blob.metadata = {ORDER_KEY: order}
        try:
            blob.upload_from_filename(
                path, content_type=content_type,
                if_generation_match=0 if current is None else int(current.generation),
            )
        except PreconditionFailed:
            # Re-read both generation and execution order after a concurrent write.
            continue
        print(f"Uploaded {uri}")
        return
    raise RuntimeError(f"Could not publish {uri} after 5 generation conflicts")
