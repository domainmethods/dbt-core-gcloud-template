# Shared by bootstrap and developer dataset setup. Both callers own TMP_DIR.
update_dataset_acl() {
  local dataset="$1" filter="$2" etag
  local before="${TMP_DIR}/dataset_acl_old.json" after="${TMP_DIR}/dataset_acl_new.json"
  shift 2

  if ! bq --project_id="$PROJECT_ID" show --format=prettyjson --dataset_view=ACL "$dataset" > "$before" ||
     ! etag=$(jq -ers '
       select(length == 1) | .[0] | select((.access | type) == "array")
       | .etag | strings | select(length > 0 and . != "*")
     ' "$before"); then
    echo "[error] Could not read a versioned ACL for dataset $dataset" >&2
    return 1
  fi

  jq -e "$@" "{access: (.access | $filter)}" "$before" > "$after"
  if ! jq -es '.[0].access == .[1].access' "$before" "$after" >/dev/null; then
    bq --project_id="$PROJECT_ID" update --update_mode=UPDATE_ACL --etag="$etag" --source="$after" "$dataset" >/dev/null
    echo "[info] Updated ACL for dataset $dataset"
  fi
}

add_dataset_acl_entry() {
  update_dataset_acl "$1" '
    {role: $role, userByEmail: $email} as $entry
    | if any(.[]; . == $entry) then . else . + [$entry] end
  ' --arg role "$2" --arg email "$3"
}
