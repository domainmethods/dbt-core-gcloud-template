"""Fence shared GCS artifacts by Cloud Run execution order."""
import hashlib
import os
import re
import time

import google.auth
import requests
from google.api_core.exceptions import PreconditionFailed
from google.auth.transport.requests import AuthorizedSession

ORDER_KEY = "dbt-cloud-run-execution-order"
LOOKUP_ATTEMPTS = 3


def _get(get, url, **kwargs):
    """GET with a short bounded retry on connection errors, 429 and 5xx."""
    for attempt in range(1, LOOKUP_ATTEMPTS + 1):
        try:
            response = get(url, **kwargs)
        except (requests.ConnectionError, requests.Timeout) as e:
            if attempt == LOOKUP_ATTEMPTS:
                raise
            print(f"Retrying {url} after {type(e).__name__} (attempt {attempt}/{LOOKUP_ATTEMPTS})")
        else:
            transient = response.status_code == 429 or response.status_code >= 500
            if not transient or attempt == LOOKUP_ATTEMPTS:
                response.raise_for_status()
                return response
            print(f"Retrying {url} after HTTP {response.status_code} (attempt {attempt}/{LOOKUP_ATTEMPTS})")
        time.sleep(attempt)


def cloud_run_order():
    job = os.environ.get("CLOUD_RUN_JOB")
    execution = os.environ.get("CLOUD_RUN_EXECUTION")
    if not job and not execution:
        return None
    if not job or not execution:
        raise RuntimeError("Both CLOUD_RUN_JOB and CLOUD_RUN_EXECUTION are required for publication")

    location = _get(
        requests.get, "http://metadata.google.internal/computeMetadata/v1/instance/region",
        headers={"Metadata-Flavor": "Google"}, timeout=10,
    )
    _, project, _, region = location.text.strip().split("/")
    resource = f"projects/{project}/locations/{region}/jobs/{job}/executions/{execution}"
    credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    with AuthorizedSession(credentials) as session:
        response = _get(session.get, f"https://run.googleapis.com/v2/{resource}", timeout=10)
        created = response.json()["createTime"]

    # Cloud Run returns UTC with variable fractional precision. Pad it for string ordering.
    timestamp = re.fullmatch(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?Z", created)
    if timestamp is None:
        raise ValueError(f"Unexpected Cloud Run createTime for {resource}: {created!r}")
    seconds, fraction = timestamp.groups()
    # The docs object can be public, so store a digest of the execution name, not the
    # project, region and job. It only breaks ties between equal createTimes.
    digest = hashlib.sha256(resource.encode()).hexdigest()
    return f"{seconds}.{(fraction or '').ljust(9, '0')}Z/{digest}"


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
