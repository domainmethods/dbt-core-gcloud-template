#!/usr/bin/env bash
set -euo pipefail

# Detects which dbt model files changed in this PR vs origin/main.
# Outputs:
#   HAS_MODEL_CHANGES=true|false  (to $GITHUB_ENV if available, else stdout)
#   CHANGED_MODELS=<space-separated model names> (to $GITHUB_OUTPUT or stdout)
#
# Requires: git history (fetch-depth: 0 in checkout)

BASE_REF="${BASE_REF:-origin/main}"

echo "=== Detecting changed files vs ${BASE_REF} ==="

# Get list of changed files
CHANGED_FILES=$(git diff --name-only "${BASE_REF}...HEAD" 2>/dev/null || git diff --name-only "${BASE_REF}" HEAD)

echo "Changed files:"
echo "$CHANGED_FILES" | sed 's/^/  /'

# Check if any dbt-relevant files changed
HAS_MODEL_CHANGES=false
CHANGED_MODELS=""

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  if [[ "$file" =~ ^models/.*\.(sql|yml|yaml)$ ]]; then
    HAS_MODEL_CHANGES=true
    # Extract model name from path (e.g., models/staging/stg_foo.sql -> stg_foo)
    if [[ "$file" == *.sql ]]; then
      model_name=$(basename "$file" .sql)
      CHANGED_MODELS="${CHANGED_MODELS} ${model_name}"
    fi
  elif [[ "$file" =~ ^(macros|seeds|snapshots)/ || "$file" == "dbt_project.yml" || "$file" == "packages.yml" ]]; then
    HAS_MODEL_CHANGES=true
  fi
done <<< "$CHANGED_FILES"

CHANGED_MODELS=$(echo "$CHANGED_MODELS" | xargs)  # trim whitespace

# Build the dbt selector: one 'name+' token per changed model (model + downstream).
# Empty when no model files changed (e.g. docs-only), so the HAS_MODEL_CHANGES=false
# skip still governs downstream.
DIFF_SELECT=""
for model_name in ${CHANGED_MODELS}; do
  DIFF_SELECT="${DIFF_SELECT} ${model_name}+"
done
DIFF_SELECT=$(echo "$DIFF_SELECT" | xargs)  # trim whitespace

echo ""
echo "HAS_MODEL_CHANGES=${HAS_MODEL_CHANGES}"
echo "CHANGED_MODELS=${CHANGED_MODELS:-<none>}"
echo "DIFF_SELECT=${DIFF_SELECT:-<none>}"

# Export to GitHub Actions env/output if available
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "HAS_MODEL_CHANGES=${HAS_MODEL_CHANGES}" >> "$GITHUB_ENV"
  echo "DIFF_SELECT=${DIFF_SELECT}" >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "has_model_changes=${HAS_MODEL_CHANGES}" >> "$GITHUB_OUTPUT"
  echo "changed_models=${CHANGED_MODELS}" >> "$GITHUB_OUTPUT"
  echo "diff_select=${DIFF_SELECT}" >> "$GITHUB_OUTPUT"
fi
