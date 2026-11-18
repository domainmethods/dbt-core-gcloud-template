#!/usr/bin/env bash
# Stubbed tests for infra/70-configure-docs-website.sh.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"
cp "$REPO_ROOT/infra/70-configure-docs-website.sh" "$SANDBOX/"
for tool in bash dirname; do
  ln -s "$(command -v "$tool")" "$SANDBOX/bin/$tool"
done
cat > "$SANDBOX/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> calls.log
STUB
chmod +x "$SANDBOX/bin/gcloud"

run_script() {
  printf 'PROJECT_ID=test-proj\nDBT_DOCS_BUCKET=docs-bucket\n%s\n' "$1" > "$SANDBOX/.env"
  : > "$SANDBOX/calls.log"
  env -i PATH="$SANDBOX/bin" bash "$SANDBOX/70-configure-docs-website.sh"
}

for bucket in '' 'DBT_ARTIFACTS_BUCKET=' 'DBT_ARTIFACTS_BUCKET=docs-bucket'; do
  if run_script "PUBLIC=true"$'\n'"$bucket" > "$SANDBOX/output" 2>&1; then
    echo "Public mode accepted a shared artifact bucket (${bucket:-unset})" >&2
    exit 1
  fi
  grep -q 'docs-only bucket' "$SANDBOX/output"
  test ! -s "$SANDBOX/calls.log"
done

run_script $'PUBLIC=true\nDBT_ARTIFACTS_BUCKET=artifacts-bucket'
grep -q 'add-iam-policy-binding gs://docs-bucket .*--member=allUsers' "$SANDBOX/calls.log"

run_script 'PUBLIC=false'
test "$(cat "$SANDBOX/calls.log")" = 'storage buckets update gs://docs-bucket --web-main-page-suffix=index.html --project test-proj'
echo "Docs bucket isolation tests passed."
