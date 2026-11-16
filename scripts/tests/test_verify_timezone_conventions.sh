#!/usr/bin/env bash
# Tests for scripts/verify_timezone_conventions.py (#68).
#
# Dependency-free: requires bash and python3 (stdlib only). Each scenario writes
# a throwaway models/ tree and runs the checker against it.
#
# Usage: bash scripts/tests/test_verify_timezone_conventions.sh
#
# Note: `set -e` is deliberately NOT used. The harness inspects the script's
# exit code and output; aborting on a non-zero exit would defeat the purpose.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$REPO_ROOT/scripts/verify_timezone_conventions.py"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "    ok   - $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "    FAIL - $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

assert_contains() {
  local haystack=$1 needle=$2 msg=$3
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$msg"
  else
    fail "$msg (expected to find '$needle')"
  fi
}

assert_exit() {
  local actual=$1 expected=$2 msg=$3
  if [[ "$actual" == "$expected" ]]; then
    pass "$msg"
  else
    fail "$msg (exit $actual, expected $expected)"
  fi
}

# Writes stdin to <ROOT>/<path>, creating parent dirs.
put() {
  mkdir -p "$(dirname "$ROOT/$1")"
  cat > "$ROOT/$1"
}

# Runs the checker on $ROOT; sets OUT and RC.
run() {
  OUT=$(python3 "$SCRIPT" "$ROOT" 2>&1)
  RC=$?
}

new_root() {
  ROOT=$(mktemp -d)
  # A clean mart so the tree is never empty.
  put models/marts/fct_ok.sql <<'SQL'
select id, datetime(created_at, 'America/New_York') as created_at_local from {{ ref('stg_x') }}
SQL
}

scenario_1() {
  echo "  scenario 1: clean tree passes; mart-layer conversion is allowed"
  new_root
  run
  assert_exit "$RC" 0 "clean tree exits 0"
  assert_contains "$OUT" "Timezone conventions hold across 1 SQL files" "reports files checked"
}

scenario_2() {
  echo "  scenario 2: zone conversion in staging and intermediate fails"
  new_root
  put models/staging/stg_a.sql <<'SQL'
select datetime(created_at, 'Europe/London') as created_local from src
SQL
  put models/intermediate/int_b.sql <<'SQL'
select timestamp(local_dt, "Asia/Kolkata") as ts from x
SQL
  run
  assert_exit "$RC" 1 "exits 1"
  assert_contains "$OUT" "models/staging/stg_a.sql:1: timezone conversion before the mart layer" "staging flagged"
  assert_contains "$OUT" "models/intermediate/int_b.sql:1: timezone conversion before the mart layer" "intermediate flagged"
}

scenario_3() {
  echo "  scenario 3: CURRENT_DATE(tz) boundary in staging is exempt"
  new_root
  put models/staging/stg_a.sql <<'SQL'
select * from src where _loaded_at >= timestamp(date_sub(current_date('America/New_York'), interval 3 day))
SQL
  run
  assert_exit "$RC" 0 "exits 0"
}

scenario_4() {
  echo "  scenario 4: DATETIME(TIMESTAMP( fails anywhere, including marts, across lines"
  new_root
  put models/marts/fct_bad.sql <<'SQL'
select
  datetime(
    timestamp(order_local_dt),
    'America/New_York'
  ) as order_local
from x
SQL
  run
  assert_exit "$RC" 1 "exits 1"
  assert_contains "$OUT" "models/marts/fct_bad.sql:2: DATETIME(TIMESTAMP(...)) -- the double-shift shape" "multi-line shape flagged at the DATETIME( line"
}

scenario_5() {
  echo "  scenario 5: tz-ok with a reason suppresses; a bare tz-ok does not"
  new_root
  put models/marts/fct_ok2.sql <<'SQL'
-- tz-ok: created_at is a TIMESTAMP column in the source
select datetime(timestamp(created_at), 'America/New_York') as created_local from x
SQL
  put models/marts/fct_bare.sql <<'SQL'
select datetime(timestamp(created_at), 'America/New_York') as created_local -- tz-ok:
from x
SQL
  run
  assert_exit "$RC" 1 "exits 1 (only the bare marker fails)"
  assert_contains "$OUT" "fct_bare.sql:1: DATETIME(TIMESTAMP" "bare tz-ok still flagged"
  if [[ "$OUT" == *"fct_ok2.sql"* ]]; then fail "reasoned tz-ok suppressed"; else pass "reasoned tz-ok suppressed"; fi
}

scenario_6() {
  echo "  scenario 6: comments are ignored (--, /* */, {# #})"
  new_root
  put models/staging/stg_c.sql <<'SQL'
-- was: datetime(timestamp(x), 'America/New_York')
/* also wrong:
   datetime(timestamp(x), 'Europe/Paris') */
{# datetime(timestamp(y), 'Asia/Tokyo') #}
select x from src
SQL
  run
  assert_exit "$RC" 0 "exits 0"
}

scenario_7() {
  echo "  scenario 7: TZ_LINT_ZONES limits zones; TZ_LINT_LAYERS changes the layers"
  new_root
  put models/staging/stg_a.sql <<'SQL'
select datetime(created_at, 'Europe/London') as created_local from src
SQL
  put models/base/base_b.sql <<'SQL'
select datetime(created_at, 'America/Chicago') as c from src
SQL
  OUT=$(TZ_LINT_ZONES="America/Chicago" python3 "$SCRIPT" "$ROOT" 2>&1); RC=$?
  assert_exit "$RC" 0 "unlisted zone in staging passes; models/base not a UTC layer by default"
  OUT=$(TZ_LINT_ZONES="America/Chicago" TZ_LINT_LAYERS="models/base" python3 "$SCRIPT" "$ROOT" 2>&1); RC=$?
  assert_exit "$RC" 1 "listed zone in a configured layer fails"
  assert_contains "$OUT" "models/base/base_b.sql:1:" "configured layer flagged"
}

scenario_8() {
  echo "  scenario 8: an empty models/ tree fails instead of passing"
  ROOT=$(mktemp -d)
  mkdir -p "$ROOT/models"
  run
  assert_exit "$RC" 1 "exits 1"
  assert_contains "$OUT" "refusing to report a clean pass" "says why"
}

scenario_9() {
  echo "  scenario 9: this repo's own models pass"
  OUT=$(python3 "$SCRIPT" "$REPO_ROOT" 2>&1); RC=$?
  assert_exit "$RC" 0 "repo models pass"
}

echo "test_verify_timezone_conventions.sh"
scenario_1
scenario_2
scenario_3
scenario_4
scenario_5
scenario_6
scenario_7
scenario_8
scenario_9

echo ""
echo "passed: $PASS_COUNT  failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
