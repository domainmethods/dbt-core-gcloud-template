#!/usr/bin/env bash
# Universal development environment setup script
# Usage: source ./setup-env.sh (local) or bash ./setup-env.sh (container)

# Detect environment
if [[ -f /.dockerenv ]] || [[ -n "${CODESPACES}" ]] || [[ -n "${DEVCONTAINER}" ]]; then
  ENV_TYPE="container"
  PREFIX="[dev-container]"
else
  ENV_TYPE="local"
  PREFIX="[setup]"
fi

echo "${PREFIX} Loading development environment..."

# Set a safe default DBT_USER if undefined. Lowercase, only [a-z0-9_],
# and ensure it doesn't start with a digit (BigQuery dataset rules).
if [[ -z "${DBT_USER:-}" ]]; then
  # Try to get active gcloud account first (more reliable for team consistency)
  _u=$(gcloud auth list --format='value(account)' --filter='status:ACTIVE' 2>/dev/null | head -n1)
  if [[ -n "$_u" ]]; then
    # Use email local part (before @)
    _u="${_u%@*}"
    echo "${PREFIX} Using gcloud authenticated email for DBT_USER"
  else
    # Fallback to local username if gcloud not authenticated
    _u=$(id -un 2>/dev/null || whoami)
    echo "${PREFIX} Warning: gcloud not authenticated, falling back to local username for DBT_USER"
    echo "${PREFIX} For consistent team datasets, run 'gcloud auth login' first"
  fi

  # Apply BigQuery dataset naming rules
  _u=$(printf '%s' "$_u" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g')
  case "$_u" in
    [0-9]*) _u="_${_u}" ;;
  esac
  export DBT_USER="${_u}"
  echo "${PREFIX} Set DBT_USER=${DBT_USER}"
fi

# Point dbt at the repo's profiles directory
export DBT_PROFILES_DIR=profiles

# Load variables from infra/.env if it exists
if [[ -f "infra/.env" ]]; then
  echo "${PREFIX} Loading variables from infra/.env"
  set -a  # automatically export all variables
  source infra/.env
  set +a  # stop auto-export

  # Container-specific: Add to ~/.bashrc for persistent terminal sessions
  if [[ "$ENV_TYPE" == "container" ]]; then
    {
      echo "# Dev container environment (auto-generated)"
      echo "export DBT_USER=\"${DBT_USER}\""
      echo "export DBT_PROFILES_DIR=\"${DBT_PROFILES_DIR}\""
      echo ""
      echo "# Load infra/.env variables"
      echo "if [[ -f \"infra/.env\" ]]; then"
      echo "  set -a"
      echo "  source infra/.env"
      echo "  set +a"
      echo "fi"
    } >> ~/.bashrc
    echo "${PREFIX} Environment persisted to ~/.bashrc"
  fi
else
  echo ""
  echo "${PREFIX} ERROR: infra/.env not found."
  echo "${PREFIX}   1. cp infra/.env.example infra/.env"
  echo "${PREFIX}   2. Edit infra/.env with your GCP project details"
  echo "${PREFIX}   3. Re-run: source ./setup-env.sh"
  echo ""
  # Return 1 (not exit) so 'source ./setup-env.sh' doesn't kill the shell
  return 1 2>/dev/null || exit 1
fi

echo "${PREFIX} Environment ready! DBT_USER=${DBT_USER}, DBT_PROFILES_DIR=${DBT_PROFILES_DIR}"

# Ensure pre-commit hooks are installed for local devs and containers
if command -v pre-commit >/dev/null 2>&1; then
  echo "${PREFIX} Installing pre-commit hooks"
  pre-commit install || true
else
  # Try to install pre-commit if Python/pip is available
  if command -v python >/dev/null 2>&1; then
    echo "${PREFIX} Installing pre-commit (pip user install)"
    python -m pip install --user pre-commit >/dev/null 2>&1 || true
    if command -v pre-commit >/dev/null 2>&1; then
      echo "${PREFIX} Installing pre-commit hooks"
      pre-commit install || true
    else
      echo "${PREFIX} pre-commit not found after install; you can install it manually with 'pip install pre-commit' and run 'pre-commit install'"
    fi
  else
    echo "${PREFIX} Python not found; skipping pre-commit setup. Install Python and run 'pip install pre-commit && pre-commit install'"
  fi
fi
