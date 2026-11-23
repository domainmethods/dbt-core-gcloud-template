#!/usr/bin/env bash
set -euo pipefail

# Detects which dbt files (models, seeds, snapshots, macros, tests, analyses, config,
# dependencies, profiles)
# changed in this PR vs origin/main.
# Outputs (to $GITHUB_ENV/$GITHUB_OUTPUT if available, else stdout):
#   HAS_MODEL_CHANGES=true|false
#   CHANGED_MODELS=<space-separated changed node names (models/seeds/snapshots)>
#   DIFF_SELECT=<space-separated downstream selector tokens>
#   BUILD_SELECT=<same value as DIFF_SELECT>
#   NEEDS_FALLBACK=true|false  (a change couldn't be scoped by filename; caller
#                               should fall back to state:modified+)
#   FULL_BUILD=true|false      (dbt/adapter, profile or project-vars change: state:modified
#                               can't see it, so the caller should build everything)
#
# Requires: git history (fetch-depth: 0 in checkout)

BASE_REF="${BASE_REF:-origin/main}"

echo "=== Detecting changed files vs ${BASE_REF} ==="

# Get list of changed files
CHANGED_FILES=$(git diff --name-only "${BASE_REF}...HEAD" 2>/dev/null || git diff --name-only "${BASE_REF}" HEAD)

echo "Changed files:"
echo "$CHANGED_FILES" | sed 's/^/  /'

# Prints the top-level `vars:` block of dbt_project.yml at a git revision (empty if absent).
project_vars_at() {
  git show "$1:dbt_project.yml" 2>/dev/null \
    | awk '/^vars:/ {in_vars = 1; print; next} in_vars && /^[^[:space:]#]/ {in_vars = 0} in_vars {print}'
}

# Categorize changed files; collect buildable node names (models, seeds, snapshots).
HAS_MODEL_CHANGES=false
CHANGED_NODES=""
NEEDS_FALLBACK=false
FULL_BUILD=false
BUILD_SELECT=""

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  case "$file" in
    models/*.sql|models/*.py|seeds/*.csv|snapshots/*.sql)
      HAS_MODEL_CHANGES=true
      filename=${file##*/}
      node=${filename%.*}
      selector=$node
      # Versioned Python nodes can have a different name from the defining file.
      if [[ "$file" == *.py ]]; then selector="path:$file"; fi
      CHANGED_NODES+=" $node"
      BUILD_SELECT+=" ${selector}+" ;;
    models/*.yml|models/*.yaml|seeds/*.yml|seeds/*.yaml|snapshots/*.yml|snapshots/*.yaml)
      # YAML can configure nodes outside any filename-derived selector.
      HAS_MODEL_CHANGES=true
      NEEDS_FALLBACK=true ;;
    # Singular/generic tests and analyses can't be scoped by filename either.
    # package-lock.yml / dependencies.yml move package versions (and their macros),
    # which state:modified+ picks up through the nodes that use them.
    macros/*.sql|tests/*|analyses/*|dbt_project.yml|packages.yml|package-lock.yml|dependencies.yml)
      HAS_MODEL_CHANGES=true
      NEEDS_FALLBACK=true
      # state:modified compares each node's SQL and config, not the vars it renders with, so a
      # changed var (e.g. a package's ga4.conversion_events) leaves the models that read it
      # deferred to prod, where they still have the old columns. Build everything instead.
      if [[ "$file" == "dbt_project.yml" ]] \
        && [[ "$(project_vars_at "$(git merge-base "$BASE_REF" HEAD 2>/dev/null || echo "$BASE_REF")")" \
          != "$(project_vars_at HEAD)" ]]; then
        echo "dbt_project.yml vars changed: state:modified can't see var changes, forcing a full build"
        FULL_BUILD=true
      fi ;;
    # A dbt-core/adapter bump or profile change alters how every node builds, but the
    # manifest doesn't change, so state:modified+ selects nothing. Only a full build tests it.
    requirements.txt|profiles/*)
      HAS_MODEL_CHANGES=true
      FULL_BUILD=true ;;
  esac
done <<< "$CHANGED_FILES"

CHANGED_NODES=$(echo "$CHANGED_NODES" | xargs)  # trim/normalize whitespace

# BUILD_SELECT == DIFF_SELECT: one selector per changed node (model + downstream;
# no leading '+' so unchanged ancestors defer to prod). Empty for docs/macro/config-only.
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
