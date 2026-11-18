#!/usr/bin/env bash
set -euo pipefail

# Detects which dbt files (models, seeds, snapshots, macros, tests, analyses, config,
# dependencies, profiles)
# changed in this PR vs origin/main.
# Outputs (to $GITHUB_ENV/$GITHUB_OUTPUT if available, else stdout):
#   HAS_MODEL_CHANGES=true|false
#   CHANGED_MODELS=<space-separated changed node names (models/seeds/snapshots)>
#   DIFF_SELECT=<space-separated 'name+' selector tokens>
#   BUILD_SELECT=<same value as DIFF_SELECT>
#   NEEDS_FALLBACK=true|false  (a change couldn't be scoped by filename; caller
#                               should fall back to state:modified+)
#   FULL_BUILD=true|false      (dbt/adapter or profile change: state:modified can't
#                               see it, so the caller should build everything)
#
# Requires: git history (fetch-depth: 0 in checkout)

BASE_REF="${BASE_REF:-origin/main}"

echo "=== Detecting changed files vs ${BASE_REF} ==="

# Get list of changed files
CHANGED_FILES=$(git diff --name-only "${BASE_REF}...HEAD" 2>/dev/null || git diff --name-only "${BASE_REF}" HEAD)

echo "Changed files:"
echo "$CHANGED_FILES" | sed 's/^/  /'

# Categorize changed files; collect buildable node names (models, seeds, snapshots).
HAS_MODEL_CHANGES=false
CHANGED_NODES=""
NEEDS_FALLBACK=false
FULL_BUILD=false

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  case "$file" in
    models/*.sql)
      HAS_MODEL_CHANGES=true
      CHANGED_NODES="${CHANGED_NODES} $(basename "$file" .sql)" ;;
    seeds/*.csv)
      HAS_MODEL_CHANGES=true
      CHANGED_NODES="${CHANGED_NODES} $(basename "$file" .csv)" ;;
    snapshots/*.sql)
      HAS_MODEL_CHANGES=true
      CHANGED_NODES="${CHANGED_NODES} $(basename "$file" .sql)" ;;
    models/*.yml|models/*.yaml|seeds/*.yml|seeds/*.yaml|snapshots/*.yml|snapshots/*.yaml)
      # YAML can configure nodes outside any filename-derived selector.
      HAS_MODEL_CHANGES=true
      NEEDS_FALLBACK=true ;;
    # Singular/generic tests and analyses can't be scoped by filename either.
    # package-lock.yml / dependencies.yml move package versions (and their macros),
    # which state:modified+ picks up through the nodes that use them.
    macros/*.sql|tests/*|analyses/*|dbt_project.yml|packages.yml|package-lock.yml|dependencies.yml)
      HAS_MODEL_CHANGES=true
      NEEDS_FALLBACK=true ;;
    # A dbt-core/adapter bump or profile change alters how every node builds, but the
    # manifest doesn't change, so state:modified+ selects nothing. Only a full build tests it.
    requirements.txt|profiles/*)
      HAS_MODEL_CHANGES=true
      FULL_BUILD=true ;;
  esac
done <<< "$CHANGED_FILES"

CHANGED_NODES=$(echo "$CHANGED_NODES" | xargs)  # trim/normalize whitespace

# BUILD_SELECT == DIFF_SELECT: one 'name+' token per changed node (model + downstream;
# no leading '+' so unchanged ancestors defer to prod). Empty for docs/macro/config-only.
BUILD_SELECT=""
for node in ${CHANGED_NODES}; do
  BUILD_SELECT="${BUILD_SELECT} ${node}+"
done
BUILD_SELECT=$(echo "$BUILD_SELECT" | xargs)
DIFF_SELECT="$BUILD_SELECT"

echo ""
echo "HAS_MODEL_CHANGES=${HAS_MODEL_CHANGES}"
echo "CHANGED_MODELS=${CHANGED_NODES:-<none>}"
echo "DIFF_SELECT=${DIFF_SELECT:-<none>}"
echo "BUILD_SELECT=${BUILD_SELECT:-<none>}"
echo "NEEDS_FALLBACK=${NEEDS_FALLBACK}"
echo "FULL_BUILD=${FULL_BUILD}"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "HAS_MODEL_CHANGES=${HAS_MODEL_CHANGES}" >> "$GITHUB_ENV"
  echo "DIFF_SELECT=${DIFF_SELECT}" >> "$GITHUB_ENV"
  echo "BUILD_SELECT=${BUILD_SELECT}" >> "$GITHUB_ENV"
  echo "NEEDS_FALLBACK=${NEEDS_FALLBACK}" >> "$GITHUB_ENV"
  echo "FULL_BUILD=${FULL_BUILD}" >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "has_model_changes=${HAS_MODEL_CHANGES}" >> "$GITHUB_OUTPUT"
  echo "changed_models=${CHANGED_NODES}" >> "$GITHUB_OUTPUT"
  echo "diff_select=${DIFF_SELECT}" >> "$GITHUB_OUTPUT"
  echo "build_select=${BUILD_SELECT}" >> "$GITHUB_OUTPUT"
  echo "needs_fallback=${NEEDS_FALLBACK}" >> "$GITHUB_OUTPUT"
  echo "full_build=${FULL_BUILD}" >> "$GITHUB_OUTPUT"
fi
