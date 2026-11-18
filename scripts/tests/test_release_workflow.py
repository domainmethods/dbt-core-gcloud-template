"""Exercise release shell steps against CLI stubs, without cloud credentials."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

import yaml


WORKFLOW = yaml.safe_load(
    (Path(__file__).resolve().parents[2] / ".github/workflows/release.yml").read_text()
)
STEPS = {
    step["name"]: step
    for step in WORKFLOW["jobs"]["build-and-deploy"]["steps"]
    if "name" in step
}
APPLY = "Create/Update Cloud Run Job"
SCHEDULE = "Schedule the job (Cloud Scheduler)"
EXECUTE = "Run prod job now and ensure artifacts pushed"
OLD_SHA = "a" * 40
NEW_SHA = "b" * 40


class ReleaseWorkflowTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.calls = self.root / "calls"
        self.output = self.root / "output"
        self.secrets = {
            "GCP_PROJECT_PROD": "production-project",
            "GCP_REGION": "us-central1",
            "GCP_SCHED_REGION": "us-east1",
            "GCP_PROD_SA_EMAIL": "release@identity-project.iam.gserviceaccount.com",
            "GCP_SCHEDULER_INVOKER_SA": "scheduler@production-project.iam.gserviceaccount.com",
            "PROD_DATASET": "analytics",
            "BQ_LOCATION": "US",
            "DBT_ARTIFACTS_BUCKET": "artifacts",
            "DBT_DOCS_BUCKET": "docs",
        }
        self.stub(
            "gcloud",
            """
printf 'gcloud %s\n' "$*" >> "$CALLS"
if [[ "$* " == "run jobs describe "* ]]; then
  exit "${DESCRIBE_STATUS:-0}"
fi
""",
        )
        self.stub(
            "gh",
            """
printf 'gh %s\n' "$*" >> "$CALLS"
[[ $1 == api && $2 == repos/owner/repo/branches/main && $3 == --jq ]] || exit 2
[[ ${GH_FAIL:-0} == 0 ]] || exit 1
jq -r "$4" <<<"$MAIN_BRANCH"
""",
        )

    def stub(self, name, script):
        path = self.root / name
        path.write_text("#!/usr/bin/env bash\n" + script)
        path.chmod(0o755)

    def step(self, name, sha=NEW_SHA, main_sha=NEW_SHA, protected=True, **extra_env):
        step = STEPS[name]
        context = {
            **{f"secrets.{key}": value for key, value in self.secrets.items()},
            "github.sha": sha,
            "github.token": "fixture-token",
        }

        def expand(value):
            return re.sub(r"\$\{\{\s*(\S+)\s*\}\}", lambda m: context.get(m[1], ""), value)

        env = {key: expand(value) for key, value in WORKFLOW.get("env", {}).items()}
        context.update({f"env.{key}": value for key, value in env.items()})
        env.update({key: expand(value) for key, value in step.get("env", {}).items()})
        self.output.write_text("")
        result = subprocess.run(
            ["bash", "-eo", "pipefail", "-c", expand(step["run"])],
            env={
                **env,
                "PATH": f"{self.root}:{os.environ['PATH']}",
                "CALLS": str(self.calls),
                "GITHUB_OUTPUT": str(self.output),
                "GITHUB_REPOSITORY": "owner/repo",
                "GITHUB_SHA": sha,
                "IMAGE_URI": f"us-central1-docker.pkg.dev/production-project/dbt/runner:{sha}",
                "MAIN_BRANCH": json.dumps({"commit": {"sha": main_sha}, "protected": protected}),
                **extra_env,
            },
            text=True,
            capture_output=True,
        )
        return result

    def test_newer_release_wins_when_it_finishes_first_or_the_old_run_is_retried(self):
        for candidate in (NEW_SHA, OLD_SHA, OLD_SHA):
            with self.subTest(candidate=candidate):
                result = self.step(APPLY, sha=candidate)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.output.read_text(), "applied=true\n" if candidate == NEW_SHA else "")
        updates = [line for line in self.calls.read_text().splitlines() if "run jobs update" in line]
        self.assertEqual(len(updates), 1, updates)
        self.assertIn(f":{NEW_SHA}", updates[0])

    def test_live_head_is_checked_between_describe_and_mutation(self):
        for status, action in (("0", "update"), ("1", "create")):
            with self.subTest(action=action):
                self.calls.write_text("")
                result = self.step(APPLY, DESCRIBE_STATUS=status)
                self.assertEqual(result.returncode, 0, result.stderr)
                commands = self.calls.read_text().splitlines()
                self.assertEqual(len(commands), 3, commands)
                self.assertTrue(commands[0].startswith("gcloud run jobs describe "), commands)
                self.assertTrue(commands[1].startswith("gh api repos/owner/repo/branches/main "), commands)
                self.assertTrue(commands[2].startswith(f"gcloud run jobs {action} "), commands)

    def test_current_main_sha_is_eligible_with_any_branch_protection_setting(self):
        result = self.step(APPLY, protected=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(), "applied=true\n")

    def test_unreadable_main_blocks_mutation(self):
        unverified = ({"GH_FAIL": "1"}, {"main_sha": ""})
        for env in unverified:
            with self.subTest(env=env):
                self.calls.write_text("")
                self.assertNotEqual(self.step(APPLY, **env).returncode, 0)
                self.assertNotIn("run jobs update", self.calls.read_text())
                self.assertEqual(self.output.read_text(), "")

    def test_lock_includes_execution_and_pending_runs_keep_their_place(self):
        lock = WORKFLOW["concurrency"]
        self.assertEqual(lock["group"], "production-release")
        self.assertEqual(lock["queue"], "max")
        self.assertFalse(lock.get("cancel-in-progress", False))
        for name in (SCHEDULE, EXECUTE):
            self.assertEqual(STEPS[name]["if"], "steps.apply.outputs.applied == 'true'")
        self.assertIn("--wait", STEPS[EXECUTE]["run"])
        self.assertNotIn("paths-ignore", WORKFLOW[True]["push"])


if __name__ == "__main__":
    unittest.main()
