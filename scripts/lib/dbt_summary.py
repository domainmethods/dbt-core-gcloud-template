#!/usr/bin/env python3
"""Emit a one-line JSON summary of dbt run_results.json for alerting/observability.

Exits non-zero if run_results.json is missing or contains failures.
"""
import json
import os
import sys

path = os.path.join("target", "run_results.json")
try:
    with open(path) as f:
        doc = json.load(f)
except Exception as e:
    print(json.dumps({"dbt_summary": {"status": "missing_run_results", "error": str(e)}}))
    print(f"dbt summary: missing run_results.json ({e})", file=sys.stderr)
    sys.exit(1)

results = doc.get("results", [])
status_counts = {}
for r in results:
    s = r.get("status", "unknown")
    status_counts[s] = status_counts.get(s, 0) + 1

summary = {
    "total": len(results),
    "elapsed": doc.get("elapsed_time"),
    "statuses": status_counts,
}
summary["failed"] = status_counts.get("error", 0) + status_counts.get("fail", 0)
summary["successful"] = status_counts.get("success", 0)

print(json.dumps({"dbt_summary": summary}))
failed = summary.get("failed", 0)
succ = summary.get("successful", 0)
elapsed = summary.get("elapsed")
print(f"dbt summary: {succ} succeeded, {failed} failed, total={summary['total']}, elapsed={elapsed}s")

if failed > 0:
    sys.exit(1)
