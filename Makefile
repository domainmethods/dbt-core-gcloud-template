.PHONY: init deps build test test-scripts lint lint-fix docs compare clean freshness

# One-time setup: load env vars, install deps, install pre-commit
init:
	@echo "Sourcing environment and installing dependencies..."
	@echo "Run: source ./setup-env.sh && make deps"

deps:
	pip install -r requirements.txt
	dbt deps
	pre-commit install || true

build:
	dbt build --target $${DBT_TARGET:-dev}

# Build a single model (usage: make run MODEL=my_model)
run:
	dbt run --target $${DBT_TARGET:-dev} --select $(MODEL)

test:
	dbt test --target $${DBT_TARGET:-dev}

# Shell script tests. No warehouse connection, no credentials, no cost.
test-scripts:
	bash scripts/tests/test_pr_schema_diff.sh
	bash scripts/tests/test_artifacts_lifecycle.sh
	bash scripts/tests/test_pr_data_diff.sh
	bash scripts/tests/test_get_changed_models.sh
	bash scripts/tests/test_ci_build.sh
	bash scripts/tests/test_ci_datasets.sh
	bash scripts/tests/test_bootstrap_project_grants.sh
	bash scripts/tests/test_deploy_and_schedule.sh
	bash scripts/tests/test_set_github_secrets.sh
	bash scripts/tests/test_wif_github.sh
	bash scripts/tests/test_verify_timezone_conventions.sh
	bash scripts/tests/test_upsert_pr_comment.sh
	bash scripts/tests/test_lookup_prod_manifest.sh
	bash scripts/tests/test_docs_website.sh
	bash scripts/tests/test_ci_workflow.sh
	bash scripts/tests/test_entrypoint.sh
	bash scripts/tests/test_sqlfluff_ci.sh
	bash scripts/tests/test_policy_updates.sh
	python3 scripts/tests/test_release_workflow.py

lint:
	pre-commit run --hook-stage manual --all-files
	python3 scripts/verify_timezone_conventions.py

lint-fix:
	pre-commit run --hook-stage manual sqlfluff-fix --all-files

docs:
	dbt docs generate --static
	@test -f target/static_index.html || { echo "dbt docs generate did not write target/static_index.html" >&2; exit 1; }
	@echo "Open target/static_index.html in your browser"

# Compare dev vs prod (usage: make compare MODEL=fct_example)
compare:
	dbt run-operation dev_prod_diff --args '{"table_name": "$(MODEL)"}'

freshness:
	dbt source freshness --target $${DBT_TARGET:-dev}

clean:
	dbt clean
	rm -rf target/ dbt_packages/ diff_reports/ schema_diff_reports/
