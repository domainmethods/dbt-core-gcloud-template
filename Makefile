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
	bash tests/test_pr_schema_diff.sh

lint:
	pre-commit run --hook-stage manual --all-files

lint-fix:
	pre-commit run --hook-stage manual sqlfluff-fix --all-files

docs:
	dbt docs generate --static
	@echo "Open target/index.html in your browser"

# Compare dev vs prod (usage: make compare MODEL=fct_example)
compare:
	dbt run-operation dev_prod_diff --args '{"table_name": "$(MODEL)"}'

freshness:
	dbt source freshness --target $${DBT_TARGET:-dev}

clean:
	dbt clean
	rm -rf target/ dbt_packages/ diff_reports/ schema_diff_reports/
