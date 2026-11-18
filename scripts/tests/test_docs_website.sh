#!/usr/bin/env bash
# Stubbed tests for infra/70-configure-docs-website.sh.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"
cp "$REPO_ROOT/infra/70-configure-docs-website.sh" "$SANDBOX/"
for tool in bash cat dirname jq mv; do
  ln -s "$(command -v "$tool")" "$SANDBOX/bin/$tool"
done
cat > "$SANDBOX/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> calls.log
case "$3" in
  get-iam-policy)
    [[ "${STUB_READ_FAIL:-0}" == 0 ]] || exit 1
    cat policy.json ;;
  add-iam-policy-binding)
    jq '.bindings += [{"role":"roles/storage.objectViewer","members":["allUsers"]}]' policy.json > updated.json
    mv updated.json policy.json ;;
  remove-iam-policy-binding)
    [[ "$*" == *'--condition=None'* ]] || exit 1
    [[ "${STUB_REMOVE_FAIL:-0}" == 0 ]] || exit 1
    [[ "${STUB_REMOVE_NOOP:-0}" == 0 ]] || exit 0
    jq '.bindings |= map(if .role == "roles/storage.objectViewer" and .condition == null
                         then .members -= ["allUsers"] else . end | select(.members != []))' policy.json > updated.json
    mv updated.json policy.json ;;
esac
STUB
chmod +x "$SANDBOX/bin/gcloud"
echo '{"bindings":[]}' > "$SANDBOX/policy.json"

run_script() {
  printf 'PROJECT_ID=test-proj\nDBT_DOCS_BUCKET=docs-bucket\n%s\n' "$1" > "$SANDBOX/.env"
  shift
  : > "$SANDBOX/calls.log"
  env -i PATH="$SANDBOX/bin" "$@" bash "$SANDBOX/70-configure-docs-website.sh"
}

for bucket in '' 'DBT_ARTIFACTS_BUCKET=' 'DBT_ARTIFACTS_BUCKET=docs-bucket'; do
  if run_script "PUBLIC=true"$'\n'"$bucket" > "$SANDBOX/output" 2>&1; then
    echo "Public mode accepted a shared artifact bucket (${bucket:-unset})" >&2
    exit 1
  fi
  grep -q 'docs-only bucket' "$SANDBOX/output"
  test ! -s "$SANDBOX/calls.log"
done

run_script $'PUBLIC=false\nDBT_ARTIFACTS_BUCKET=artifacts-bucket' DOCS_PUBLIC=true
grep -q 'add-iam-policy-binding gs://docs-bucket .*--member=allUsers' "$SANDBOX/calls.log"
jq -e '.bindings[] | select(.role == "roles/storage.objectViewer") | .members == ["allUsers"]' "$SANDBOX/policy.json"

if run_script 'PUBLIC=false' DOCS_PUBLIC=true > "$SANDBOX/output" 2>&1; then
  echo "The shell override bypassed the shared bucket guard" >&2
  exit 1
fi
test ! -s "$SANDBOX/calls.log"

cat > "$SANDBOX/policy.json" <<'POLICY'
{"bindings":[{"role":"roles/storage.objectViewer","members":["allUsers","user:reader@example.org"]}]}
POLICY
run_script 'PUBLIC=true' DOCS_PUBLIC=false > "$SANDBOX/output"
grep -q 'remove-iam-policy-binding gs://docs-bucket .*--condition=None' "$SANDBOX/calls.log"
test "$(grep -c 'get-iam-policy' "$SANDBOX/calls.log")" = 2
jq -e '.bindings[0].members == ["user:reader@example.org"]' "$SANDBOX/policy.json"
grep -q 'Bucket IAM has no public grants' "$SANDBOX/output"

run_script 'PUBLIC=false'
test "$(grep -c 'iam-policy' "$SANDBOX/calls.log")" = 1

# A PUBLIC exported earlier by setup-env.sh is stale: infra/.env decides, in both directions.
run_script $'PUBLIC=false\nDBT_ARTIFACTS_BUCKET=artifacts-bucket' PUBLIC=true > "$SANDBOX/output"
if grep -q 'add-iam-policy-binding' "$SANDBOX/calls.log"; then
  echo "A stale exported PUBLIC=true overrode PUBLIC=false in infra/.env" >&2
  exit 1
fi
grep -q 'Bucket IAM has no public grants' "$SANDBOX/output"
echo '{"bindings":[{"role":"roles/storage.objectViewer","members":["allUsers"]}]}' > "$SANDBOX/policy.json"
run_script $'PUBLIC=true\nDBT_ARTIFACTS_BUCKET=artifacts-bucket' PUBLIC=false > "$SANDBOX/output"
if grep -q 'remove-iam-policy-binding' "$SANDBOX/calls.log"; then
  echo "A stale exported PUBLIC=false overrode PUBLIC=true in infra/.env" >&2
  exit 1
fi
jq -e '.bindings[0].members == ["allUsers"]' "$SANDBOX/policy.json"
echo '{"bindings":[]}' > "$SANDBOX/policy.json"

echo '{"bindings":[{"role":"roles/storage.legacyObjectReader","members":["allAuthenticatedUsers"]}]}' > "$SANDBOX/policy.json"
if run_script 'PUBLIC=false' > "$SANDBOX/output" 2>&1; then
  echo "Private mode reported success with other public grants still in place" >&2
  exit 1
fi
grep -q 'Public grants remain in bucket IAM' "$SANDBOX/output"
test "$(grep -c 'iam-policy' "$SANDBOX/calls.log")" = 1

echo '{"bindings":[{"role":"roles/storage.objectViewer","members":["allUsers"]}]}' > "$SANDBOX/policy.json"
if run_script 'PUBLIC=false' STUB_REMOVE_NOOP=1 > "$SANDBOX/output" 2>&1; then
  echo "Private mode reported success without confirming revocation" >&2
  exit 1
fi
grep -q 'Public grants remain in bucket IAM' "$SANDBOX/output"

if run_script 'PUBLIC=false' STUB_READ_FAIL=1 > "$SANDBOX/output" 2>&1; then
  echo "Private mode reported success without reading the IAM policy" >&2
  exit 1
fi
grep -q 'Failed to read bucket IAM policy' "$SANDBOX/output"

if run_script 'PUBLIC=false' STUB_REMOVE_FAIL=1 > "$SANDBOX/output" 2>&1; then
  echo "Private mode reported success after the revocation failed" >&2
  exit 1
fi
grep -q 'Failed to remove the allUsers reader grant' "$SANDBOX/output"

echo "Docs bucket isolation and visibility tests passed."
