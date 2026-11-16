#!/usr/bin/env bash
# Tests for scripts/lookup_prod_manifest.sh exit codes (#74):
# 0 = found, 2 = missing, 1 = lookup failed after one retry.
# Dependency-free: bash 3.2+, coreutils. Stubs `gsutil` on PATH. No `set -e`.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/lookup_prod_manifest.sh"
PASS_COUNT=0; FAIL_COUNT=0
pass(){ echo "    ok   - $1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail(){ echo "    FAIL - $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }

# run_case NAME WANT_EXIT WANT_CALLS WANT_TEXT "code|stderr" ["code|stderr" ...]
# Each "code|stderr" pair is one gsutil response; the last one repeats.
run_case() {
  local name="$1" want_exit="$2" want_calls="$3" want_text="$4"; shift 4
  local sandbox; sandbox=$(mktemp -d); mkdir -p "$sandbox/bin"
  local i=0 resp
  for resp in "$@"; do
    printf '%s\n%s\n' "${resp%%|*}" "${resp#*|}" > "$sandbox/resp$i"; i=$((i+1))
  done
  cat > "$sandbox/bin/gsutil" <<STUB
#!/usr/bin/env bash
n=\$(cat "$sandbox/calls" 2>/dev/null || echo 0); echo \$((n+1)) > "$sandbox/calls"
f="$sandbox/resp\$n"; [[ -f "\$f" ]] || f="$sandbox/resp$((i-1))"
sed -n 2p "\$f" >&2; exit "\$(sed -n 1p "\$f")"
STUB
  chmod +x "$sandbox/bin/gsutil"
  local out rc calls
  out=$(env -i PATH="$sandbox/bin:/usr/bin:/bin" PROD_MANIFEST_RETRY_DELAY=0 \
    bash "$SCRIPT" gs://bucket/prod/manifest.json 2>&1); rc=$?
  calls=$(cat "$sandbox/calls" 2>/dev/null || echo 0)
  if [[ $rc -eq $want_exit && $calls -eq $want_calls && "$out" == *"$want_text"* ]]; then
    pass "$name (exit $rc, $calls call(s))"
  else
    fail "$name: want exit $want_exit, $want_calls call(s), output with '$want_text'; got exit $rc, $calls call(s): $out"
  fi
}

echo "scenario: lookup_prod_manifest.sh exit codes"
run_case "found" 0 1 "" "0|"
run_case "missing" 2 1 "not found" "1|CommandException: One or more URLs matched no objects."
run_case "transient then found" 0 2 "Retrying" "1|ServiceException: 503" "0|"
run_case "auth failure twice" 1 2 "AccessDeniedException" "1|AccessDeniedException: 401 Anonymous caller"

echo "results: passed: $PASS_COUNT, failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
