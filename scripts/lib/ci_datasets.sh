# Shared ownership checks for BigQuery CI dataset provisioning and cleanup.
CI_RUN_DATASET_PATTERN='^ci_pr_[1-9][0-9]*_[1-9][0-9]*_[1-9][0-9]*$'

require_ci_repository() {
  if [[ ! "${GITHUB_REPOSITORY_ID:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo "[error] GITHUB_REPOSITORY_ID must be a numeric GitHub repository ID" >&2
    return 1
  fi
}

require_ci_run_dataset() {
  local pr expected
  require_ci_repository || return 1
  if [[ "${GITHUB_ACTIONS:-}" == true && "${GITHUB_EVENT_NAME:-}" == pull_request && "${DBT_TARGET:-}" == ci ]] &&
    pr=$(jq -er '.number | numbers' "${GITHUB_EVENT_PATH:-}" 2>/dev/null); then
    expected="ci_pr_${pr}_${GITHUB_RUN_ID:-}_${GITHUB_RUN_ATTEMPT:-}"
    if [[ "$expected" =~ $CI_RUN_DATASET_PATTERN && "${DBT_BQ_DATASET:-}" == "$expected" ]]; then
      return 0
    fi
  fi
  echo "[error] DBT_BQ_DATASET must match the current GitHub pull request, run and attempt" >&2
  return 1
}

owned_ci_dataset() {
  local dataset=$1 run=${2:-}
  # Some bq environments emit warnings before the JSON.
  bq --project_id="$DBT_GCP_PROJECT_CI" show --format=json "${DBT_GCP_PROJECT_CI}:$dataset" \
    | sed -n '/^[[:space:]]*{/,$p' \
    | jq -ce --arg project "$DBT_GCP_PROJECT_CI" --arg dataset "$dataset" --arg repo "$GITHUB_REPOSITORY_ID" \
      --arg run "$run" --arg pattern "$CI_RUN_DATASET_PATTERN" '
        select(.datasetReference.projectId == $project and .datasetReference.datasetId == $dataset)
        | select(.labels.dbt_ci_repository == $repo)
        | .labels.dbt_ci_run as $base
        | select($base | strings | test($pattern))
        | select($run == "" or $base == $run)
        | select($dataset == $base or ($dataset | startswith($base + "_")))
      '
}
