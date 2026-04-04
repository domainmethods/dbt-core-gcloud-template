#!/usr/bin/env python3
"""Summarize dbt source freshness results from target/sources.json."""
import json
import os

sp = os.path.join("target", "sources.json")
if os.path.exists(sp):
    try:
        with open(sp) as f:
            doc = json.load(f)
        statuses = {}
        for src in doc.get("sources", []):
            st = (src.get("freshness") or {}).get("status") or src.get("status") or "unknown"
            statuses[st] = statuses.get(st, 0) + 1
        print(json.dumps({"dbt_freshness": {"statuses": statuses}}))
        parts = ", ".join(f"{k}={v}" for k, v in sorted(statuses.items())) or "no entries"
        print(f"dbt freshness: {parts}")
    except Exception as e:
        print(json.dumps({"dbt_freshness": {"status": "error_reading_sources", "error": str(e)}}))
        print(f"dbt freshness: failed to read sources.json ({e})")
else:
    print(json.dumps({"dbt_freshness": {"status": "missing_sources_json"}}))
    print("dbt freshness: missing target/sources.json")
