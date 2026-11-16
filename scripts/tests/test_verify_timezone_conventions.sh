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

assert_not_contains() {
  local haystack=$1 needle=$2 msg=$3
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$msg"
  else
    fail "$msg (unexpectedly found '$needle')"
  fi
}

STG="timezone conversion before the mart layer"
SHIFT="the double-shift shape"

scenario_10() {
  echo "  scenario 10: comment markers inside string literals do not hide code"
  new_root
  put models/staging/stg_dash.sql <<'SQL'
select replace(a, '--', '') as a, datetime(created_at, 'America/New_York') as b from src
SQL
  put models/staging/stg_block.sql <<'SQL'
select a from src where b like '%/*%'
select datetime(created_at, 'America/New_York') as b from src
SQL
  put models/marts/fct_block.sql <<'SQL'
select a from src where b like '%/*%'
select datetime(timestamp(x), 'America/New_York') from src
SQL
  put models/staging/stg_escape.sql <<'SQL'
select 'it\'s -- fine' as a, "say \"/*\"" as b, `proj.ds.t--x` as c, datetime(created_at, 'America/New_York') as d from src
SQL
  put models/staging/stg_triple.sql <<'SQL'
select '''multi-line
string with /* and -- inside''' as a,
  datetime(created_at, 'America/New_York') as b
from src
SQL
  put models/marts/fct_apostrophe_comment.sql <<'SQL'
/* don't */ select datetime(timestamp(x), 'America/New_York') from src
SQL
  put models/marts/fct_note.sql <<'SQL'
select 'DATETIME(TIMESTAMP(x))' as note, "-- 'America/New_York'" as note2 from src
SQL
  run
  assert_exit "$RC" 1 "exits 1"
  assert_contains "$OUT" "stg_dash.sql:1: $STG" "'--' in a string does not start a comment"
  assert_contains "$OUT" "stg_block.sql:2: $STG" "'/*' in a string does not blank the rest of the file"
  assert_contains "$OUT" "fct_block.sql:2: DATETIME(TIMESTAMP" "'/*' in a string does not disable the double-shift rule"
  assert_contains "$OUT" "stg_escape.sql:1: $STG" "escaped quotes and backtick identifiers handled"
  assert_contains "$OUT" "stg_triple.sql:3: $STG" "triple-quoted multi-line string handled"
  assert_contains "$OUT" "fct_apostrophe_comment.sql:1: DATETIME(TIMESTAMP" "apostrophe in a comment does not open a string"
  assert_not_contains "$OUT" "fct_note.sql" "double-shift text inside a string literal is not code"
}

scenario_11() {
  echo "  scenario 11: the boundary exemption covers only the boundary call"
  new_root
  put models/staging/stg_mixed.sql <<'SQL'
select * from src where datetime(created_at, 'America/New_York') >= current_date('America/New_York')
SQL
  put models/staging/stg_boundaries.sql <<'SQL'
select * from src
where _loaded_at >= timestamp(current_datetime('America/New_York'))
  and _loaded_at < current_timestamp()
  and d < current_date(
    'Europe/London'
  )
  and d > current_date({{ var('local_tz') }})
SQL
  run
  assert_exit "$RC" 1 "exits 1"
  assert_contains "$OUT" "stg_mixed.sql:1: $STG" "conversion beside a boundary on the same line flagged"
  assert_not_contains "$OUT" "stg_boundaries.sql" "boundary calls (incl. multi-line and jinja zone) exempt"
}

scenario_12() {
  echo "  scenario 12: slash-separated strings that are not zones are not flagged"
  new_root
  put models/staging/stg_labels.sql <<'SQL'
select
  case when is_active then 'Yes/No' else 'Credit/Debit' end as a,
  'N/A' as b, 'Mobile/Tablet' as c, "Sales/Marketing" as d,
  '-1' as e, '10-20' as f, 'Pacific' as g
from src
SQL
  run
  assert_exit "$RC" 0 "exits 0"
  assert_not_contains "$OUT" "stg_labels.sql" "'Yes/No' and friends not flagged"
}

scenario_13() {
  echo "  scenario 13: zones with digits/signs, offsets, legacy names and jinja zones are caught"
  new_root
  put models/staging/stg_etc.sql <<'SQL'
select datetime(created_at, 'Etc/GMT+5') as x from src
SQL
  put models/staging/stg_ba.sql <<'SQL'
select datetime(created_at, 'America/Argentina/Buenos_Aires') as x from src
SQL
  put models/staging/stg_off1.sql <<'SQL'
select datetime(created_at, '-05:00') as x from src
SQL
  put models/staging/stg_off2.sql <<'SQL'
select datetime(created_at, '+0530') as x from src
SQL
  put models/staging/stg_off3.sql <<'SQL'
select datetime(created_at, 'UTC+3') as x from src
SQL
  put models/staging/stg_legacy.sql <<'SQL'
select datetime(created_at, 'US/Eastern') as x from src
SQL
  put models/staging/stg_jinja_quoted.sql <<'SQL'
select datetime(created_at, '{{ var("local_tz") }}') as x from src
SQL
  put models/staging/stg_jinja_bare.sql <<'SQL'
select date(created_at, {{ var('tz') }}) as x from src
SQL
  put models/intermediate/int_jinja_multi.sql <<'SQL'
select
  format_timestamp(
    '%F',
    created_at,
    {{ var('tz') }}
  ) as x,
  extract(hour from created_at at time zone {{ var('tz') }}) as h
from src
SQL
  put models/staging/stg_jinja_ok.sql <<'SQL'
select
  coalesce(x, {{ var('default_x') }}) as x,
  date_add(d, interval {{ var('lookback') }} day) as d,
  datetime(d, {{ var('t') }}, 1) as weird
from {{ ref('src') }}
SQL
  run
  assert_exit "$RC" 1 "exits 1"
  assert_contains "$OUT" "stg_etc.sql:1: $STG" "'Etc/GMT+5' flagged"
  assert_contains "$OUT" "stg_ba.sql:1: $STG" "'America/Argentina/Buenos_Aires' flagged"
  assert_contains "$OUT" "stg_off1.sql:1: $STG" "'-05:00' flagged"
  assert_contains "$OUT" "stg_off2.sql:1: $STG" "'+0530' flagged"
  assert_contains "$OUT" "stg_off3.sql:1: $STG" "'UTC+3' flagged"
  assert_contains "$OUT" "stg_legacy.sql:1: $STG" "legacy 'US/Eastern' flagged"
  assert_contains "$OUT" "stg_jinja_quoted.sql:1: $STG" "quoted jinja zone flagged"
  assert_contains "$OUT" "stg_jinja_bare.sql:1: $STG" "bare jinja zone flagged"
  assert_contains "$OUT" "int_jinja_multi.sql:2: $STG" "multi-line FORMAT_TIMESTAMP jinja zone flagged at the call"
  assert_contains "$OUT" "int_jinja_multi.sql:7: $STG" "AT TIME ZONE jinja flagged"
  assert_not_contains "$OUT" "stg_jinja_ok.sql" "jinja outside a zone argument not flagged"
}

scenario_14() {
  echo "  scenario 14: DATETIME(CAST(x AS TIMESTAMP), tz) is the same double shift"
  new_root
  put models/marts/fct_cast.sql <<'SQL'
select datetime(cast(order_local_dt as timestamp), 'America/New_York') as a from x
SQL
  put models/marts/fct_safe_cast.sql <<'SQL'
select
  datetime(
    safe_cast(coalesce(a, b) as timestamp),
    'America/New_York'
  ) as a
from x
SQL
  put models/marts/fct_cast_ok.sql <<'SQL'
select
  datetime(cast(d as date), cast(t as time)) as a,
  format_datetime('%F', datetime(timestamp_seconds(s), 'America/New_York')) as b,
  -- tz-ok: created_at is a TIMESTAMP column
  datetime(cast(created_at as timestamp), 'America/New_York') as c
from x
SQL
  run
  assert_exit "$RC" 1 "exits 1"
  assert_contains "$OUT" "fct_cast.sql:1: DATETIME(TIMESTAMP" "CAST(x AS TIMESTAMP) flagged"
  assert_contains "$OUT" "fct_safe_cast.sql:2: DATETIME(TIMESTAMP" "multi-line SAFE_CAST flagged at the DATETIME( line"
  assert_not_contains "$OUT" "fct_cast_ok.sql" "other casts, TIMESTAMP_SECONDS and tz-ok not flagged"
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
scenario_10
scenario_11
scenario_12
scenario_13
scenario_14

echo ""
echo "passed: $PASS_COUNT  failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
