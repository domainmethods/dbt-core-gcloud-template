#!/usr/bin/env bash
# Tests lifecycle read/modify/write against a stubbed shared bucket.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir "$SANDBOX/bin"
cp "$REPO_ROOT/infra/15-artifacts-lifecycle.sh" "$SANDBOX/"
for tool in bash cat dirname jq mktemp rm; do
  ln -s "$(command -v "$tool")" "$SANDBOX/bin/$tool"
done
cat > "$SANDBOX/.env" <<'ENV'
PROJECT_ID=fixture-project
DBT_DOCS_BUCKET=shared-bucket
DBT_ARTIFACTS_BUCKET=
ENV
cat > "$SANDBOX/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> calls.log
case "$*" in
  'storage buckets describe gs://shared-bucket'*) cat bucket.json ;;
  'auth print-access-token'*) echo 'inert-placeholder' ;;
  'storage buckets update gs://shared-bucket'*) jq '{lifecycle:.}' "${5#--lifecycle-file=}" > patch.json ;;
  *) echo "Unexpected cloud command: $*" >&2; exit 1 ;;
esac
STUB
cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
read -r header
[[ "$header" == 'Authorization: Bearer inert-placeholder' ]]
[[ "$*" == *'--request PATCH'* ]]
echo "PATCH ${@: -1}" >> calls.log
[[ "${STUB_CONFLICT:-0}" == 0 ]] || exit 22
while [[ "$1" != --data-binary ]]; do shift; done
jq '.' <<< "$2" > patch.json
STUB
chmod +x "$SANDBOX"/bin/{gcloud,curl}

run_script() {
  : > "$SANDBOX/calls.log"
  env -i PATH="$SANDBOX/bin" "$@" bash "$SANDBOX/15-artifacts-lifecycle.sh"
}

cat > "$SANDBOX/bucket.json" <<'JSON'
{"name":"shared-bucket","metageneration":"7","lifecycle":{"rule":[
  {"action":{"type":"SetStorageClass","storageClass":"NEARLINE"},"condition":{"age":60,"matchesPrefix":["archive/"]}},
  {"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["scratch/"]}},
  {"condition":{"age":30},"action":{"type":"Delete"}}
]}}
JSON
run_script
jq -e --slurpfile before "$SANDBOX/bucket.json" '
  .lifecycle.rule == ($before[0].lifecycle.rule[:2] +
    [{"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["ci/"]}},
     {"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["prod/runs/"]}}])
' "$SANDBOX/patch.json" > /dev/null
grep -Fqx 'PATCH https://storage.googleapis.com/storage/v1/b/shared-bucket?ifMetagenerationMatch=7' "$SANDBOX/calls.log"

if run_script STUB_CONFLICT=1; then
  echo "A stale lifecycle update should fail" >&2
  exit 1
fi

jq -n --slurpfile patch "$SANDBOX/patch.json" '$patch[0] + {name:"shared-bucket",metageneration:"8"}' > "$SANDBOX/bucket.json"
run_script STUB_CONFLICT=1
if grep -q '^PATCH ' "$SANDBOX/calls.log"; then
  echo "A current lifecycle policy should not be rewritten" >&2
  exit 1
fi

echo '{"name":"shared-bucket","metageneration":"8"}' > "$SANDBOX/bucket.json"
run_script
jq -e '.lifecycle.rule == [{"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["ci/"]}},
  {"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["prod/runs/"]}}]' "$SANDBOX/patch.json" > /dev/null

# A bucket configured before prod/runs/ diagnostics existed gains only the new rule.
cat > "$SANDBOX/bucket.json" <<'JSON'
{"name":"shared-bucket","metageneration":"9","lifecycle":{"rule":[
  {"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["ci/"]}}
]}}
JSON
run_script
jq -e '.lifecycle.rule == [{"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["ci/"]}},
  {"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["prod/runs/"]}}]' "$SANDBOX/patch.json" > /dev/null

echo '{"name":"shared-bucket"}' > "$SANDBOX/bucket.json"
if run_script > "$SANDBOX/output" 2>&1; then
  echo "The update did not require a bucket metageneration" >&2
  exit 1
fi
test "$(wc -l < "$SANDBOX/calls.log")" -eq 1

echo "Artifacts lifecycle tests passed."
