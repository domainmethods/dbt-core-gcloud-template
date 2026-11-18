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
            "AR_REPO": "dbt",
            "IMAGE_NAME": "runner",
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
if [[ -n "${JOB_ENV_STATE:-}" && "$1 $2" == "run jobs" && ( "$3" == create || "$3" == update ) ]]; then
  while (($#)); do
    case "$1" in
      --set-env-vars|--update-env-vars)
        jq --arg verb "$1" --arg raw "$2" '
          ($raw | split(",") | map(capture("^(?<key>[^=]+)=(?<value>.*)$")) | from_entries) as $changes
          | if $verb == "--set-env-vars" then $changes else . + $changes end
        ' "$JOB_ENV_STATE" > "$JOB_ENV_STATE.tmp"
        mv "$JOB_ENV_STATE.tmp" "$JOB_ENV_STATE"
        shift
        ;;
      --env-vars-file)
        cp "$2" "$JOB_ENV_STATE"
        shift
        ;;
    esac
    shift
  done
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
        self.stub("docker", """printf 'docker %s\n' "$*" >> "$CALLS" """)

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
                "GITHUB_ENV": str(self.root / "github-env"),
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

    def test_update_preserves_operator_settings_and_advances_workflow_owned_values(self):
        operator_env = {
            "DBT_MAX_BYTES_BILLED": "50000000000",
            "DBT_BQ_PRIORITY": "batch",
            "DBT_JOB_EXECUTION_TIMEOUT_SEC": "600",
            "RUN_FRESHNESS": "false",
            "FRESHNESS_SELECT": "source:source_data",
            "GENERATE_DOCS": "false",
            "RUN_PRE_HOOK": "true",
            "RUN_POST_HOOK": "true",
            "API_KEY": {"valueSource": {"secretKeyRef": {"secret": "api-key", "version": "1"}}},
        }
        state = self.root / "existing.json"
        state.write_text(json.dumps({"DBT_BQ_DATASET_PROD": "old_dataset", **operator_env}))
        self.secrets.update(GENERATE_DOCS="true", RUN_FRESHNESS="true", DBT_MAX_BYTES_BILLED="90000000000")

        result = self.step(APPLY, JOB_ENV_STATE=str(state))

        self.assertEqual(result.returncode, 0, result.stderr)
        updated = json.loads(state.read_text())
        self.assertEqual({key: updated.get(key) for key in operator_env}, operator_env)
        self.assertEqual(updated["DBT_BQ_DATASET_PROD"], "analytics")
        update = self.calls.read_text().splitlines()[-1]
        for flag in ("--service-account", "--task-timeout", "--set-secrets", "--clear-secrets"):
            self.assertNotIn(flag, update)

    def test_create_uses_first_release_configuration_and_defaults(self):
        state = self.root / "created.yaml"
        for config in (
            {},
            {
                "GENERATE_DOCS": "false",
                "RUN_FRESHNESS": "false",
                "FRESHNESS_SELECT": "source:raw,tag:fresh",
                "DBT_MAX_BYTES_BILLED": "5000000000000",
                "DBT_BQ_PRIORITY": "batch",
                "DBT_JOB_EXECUTION_TIMEOUT_SEC": "600",
            },
        ):
            with self.subTest(config=config):
                state.write_text("{}")
                self.secrets.update(config)
                result = self.step(APPLY, DESCRIBE_STATUS="1", JOB_ENV_STATE=str(state))

                self.assertEqual(result.returncode, 0, result.stderr)
                created = yaml.safe_load(state.read_text())
                expected = {"GENERATE_DOCS": "true", "RUN_FRESHNESS": "true", "DBT_BQ_PRIORITY": "interactive"}
                expected.update(config)
                self.assertEqual({key: created.get(key) for key in expected}, expected)
                self.assertEqual(created["DBT_BQ_DATASET_PROD"], "analytics")

    def test_release_uses_production_project_even_with_an_identity_project_default(self):
        for name in ("Build container", APPLY, SCHEDULE, EXECUTE):
            with self.subTest(step=name):
                result = self.step(name, CLOUDSDK_CORE_PROJECT="identity-project")
                self.assertEqual(result.returncode, 0, result.stderr)

        calls = self.calls.read_text().splitlines()
        self.assertIn(f"docker build -t us-central1-docker.pkg.dev/production-project/dbt/runner:{NEW_SHA} .", calls)
        job_calls = [line for line in calls if line.startswith(("gcloud run jobs ", "gcloud scheduler jobs "))]
        for operation in ("run jobs describe", "run jobs update", "scheduler jobs describe", "scheduler jobs update", "run jobs execute"):
            self.assertTrue(any(f"gcloud {operation} " in line for line in job_calls), job_calls)
        for line in job_calls:
            self.assertIn("--project production-project", line)
        schedule = next(line for line in job_calls if line.startswith("gcloud scheduler jobs update "))
        self.assertIn("projects/production-project/locations/us-central1/jobs/dbt-prod-run:run", schedule)
        self.assertIn("--oauth-service-account-email scheduler@production-project.iam.gserviceaccount.com", schedule)


if __name__ == "__main__":
    unittest.main()
