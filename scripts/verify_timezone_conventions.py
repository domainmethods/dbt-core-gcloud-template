#!/usr/bin/env python3
"""Enforce the two mechanically checkable timezone conventions (#68).

Convention: keep UTC TIMESTAMPs until the mart layer and convert once there.

1. No timezone conversion in the pre-mart layers (default: models/staging,
   models/intermediate). Any string literal naming a zone ('America/New_York',
   'Etc/GMT+5', '-05:00', '+0530', 'UTC+3') fails, and so does a Jinja
   expression in a function's zone slot (DATETIME(x, {{ var('tz') }}),
   FORMAT_TIMESTAMP(f, x, '{{ var("tz") }}'), ... AT TIME ZONE {{ ... }}),
   since the zone it renders to cannot be seen. The exception is the sole
   argument of CURRENT_DATE / CURRENT_DATETIME / CURRENT_TIME /
   CURRENT_TIMESTAMP: that boundary converts "now", not a column. Only the
   boundary call is exempt; another conversion on the same line still fails.
2. No `DATETIME(TIMESTAMP(...` or `DATETIME(CAST(... AS TIMESTAMP)` (or
   SAFE_CAST) anywhere in models/. This is the shape of the
   "double shift": when the inner value is already a local DATETIME, it is read
   as UTC and shifted again, so every row lands hours off. dbt compile, sqlfluff
   and tests all accept it, and the correct form (inner value a real TIMESTAMP)
   is textually identical, so the check is deliberately broad: a legitimate use
   carries `-- tz-ok: <reason>` on the line where `DATETIME(` opens or the line
   above. A bare `tz-ok:` with no reason does not count. The match spans line
   breaks, so sqlfluff's multi-line layout is still caught.

Comments (`--`, `/* */`, `{# #}`) are stripped first, so a note describing the
wrong expression does not trip the check. Stripping is string-literal aware
(single, double and backtick quotes, triple quotes, backslash escapes), so a
'--' or LIKE '%/*%' in a string cannot hide the code after it, and the
double-shift text inside a string literal is not mistaken for code.

Configuration (environment variables):
  TZ_LINT_ZONES   comma-separated zone names to treat as a conversion, e.g.
                  "America/New_York,Europe/London". Default: any IANA zone in a
                  real tz-database area (Africa/, America/, ..., Pacific/, Etc/,
                  and the legacy US/, Canada/, Brazil/, Chile/, Mexico/ links).
  TZ_LINT_LAYERS  comma-separated directories that must stay UTC.
                  Default: "models/staging,models/intermediate".

No dbt, no warehouse: it reads models/**/*.sql only.

Known limitations (it is a text lint, not a SQL parser; Jinja is not rendered):
  - Only literals and Jinja expressions are seen. A zone held in a column or
    SQL variable, or a macro that converts internally ({{ to_local(x) }}), is
    not caught; nor is a double shift split across CTEs (CAST to TIMESTAMP in
    one, DATETIME(that_column, tz) in the next).
  - Jinja zones are caught only as the last argument of DATETIME, TIMESTAMP,
    DATE, TIME, STRING, TIMESTAMP_TRUNC, FORMAT_TIMESTAMP, PARSE_TIMESTAMP, or
    after AT TIME ZONE.
  - The default zone pattern skips bare names ('EST', 'EST5EDT', 'Japan',
    'UTC') and bare-hour offsets ('-5', '+3'); area names are case-sensitive.
    List such zones in TZ_LINT_ZONES (which replaces the default entirely).
  - In a pre-mart layer any zone literal counts, even one that is not used to
    convert (e.g. 'America/New_York' AS tz_name); mark it `-- tz-ok: <reason>`.
  - BigQuery `#` comments are not stripped, and `-- tz-ok:` is matched on the
    raw line, so a marker inside a string literal also counts.

Usage:  python scripts/verify_timezone_conventions.py [repo_root]
Exits 0 if every check holds, 1 otherwise.
"""
import os
import re
import sys
from pathlib import Path

# A zone literal that is the whole argument of CURRENT_DATE(...) and friends is a
# boundary ("today in New York"), not a column conversion. Matched against the
# masked code just before / after the literal, so only that call is exempt.
BOUNDARY_OPEN = re.compile(r"\bCURRENT_(DATE|DATETIME|TIME|TIMESTAMP)\s*\(\s*\Z", re.IGNORECASE)
BOUNDARY_CLOSE = re.compile(r"\s*\)")
# Double shift: DATETIME( whose first argument is TIMESTAMP(...) or
# CAST(... AS TIMESTAMP) / SAFE_CAST(... AS TIMESTAMP).
DATETIME_CALL = re.compile(r"\bDATETIME\s*\(", re.IGNORECASE)
TIMESTAMP_CALL = re.compile(r"\s*TIMESTAMP\s*\(", re.IGNORECASE)
CAST_CALL = re.compile(r"\s*(SAFE_)?CAST\s*\(", re.IGNORECASE)
AS_TIMESTAMP = re.compile(r"\bAS\s+TIMESTAMP\s*\Z", re.IGNORECASE)
# Functions whose last argument is a zone, with the argument count at which it
# is. A Jinja expression in that slot ({{ var('tz') }}) hides the zone from the
# literal check, so it is flagged as a conversion too.
ZONE_ARG_CALLS = {
    "DATETIME": 2, "TIMESTAMP": 2, "DATE": 2, "TIME": 2, "STRING": 2,
    "TIMESTAMP_TRUNC": 3, "FORMAT_TIMESTAMP": 3, "PARSE_TIMESTAMP": 3,
}
ZONE_ARG_CALL = re.compile(r"\b(" + "|".join(ZONE_ARG_CALLS) + r")\s*\(", re.IGNORECASE)
AT_TIME_ZONE = re.compile(r"\bAT\s+TIME\s+ZONE\s+", re.IGNORECASE)
JINJA_ARG = re.compile(r"""\s*(['"]?)\{\{.*\}\}\1\s*""", re.DOTALL)
JINJA_START = re.compile(r"""['"]?\{\{""")
SUPPRESS = re.compile(r"--\s*tz-ok:\s*\S")
# The contents of a string literal naming an IANA zone, e.g. America/New_York.
# Only the real tz-database areas (plus the legacy US/, Canada/, ... links) count,
# so labels such as 'Yes/No' or 'Credit/Debit' are not mistaken for zones.
IANA_AREAS = (
    "Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|Europe|Indian|Pacific|Etc"
    "|US|Canada|Brazil|Chile|Mexico"
)
# UTC offsets as BigQuery accepts them: '-05:00', '+0530', 'UTC+3', 'GMT-5:30'.
# A bare '-5' is not matched (too easily a plain value).
UTC_OFFSET = r"(?:UTC|GMT)[+-]\d{1,2}(?::?\d{2})?|[+-]\d{1,2}:\d{2}|[+-]\d{4}"
ANY_IANA_ZONE = rf"(?:{IANA_AREAS})/[A-Za-z0-9_/+-]+|{UTC_OFFSET}"


def zone_pattern() -> re.Pattern:
    zones = [z.strip() for z in os.environ.get("TZ_LINT_ZONES", "").split(",") if z.strip()]
    if not zones:
        return re.compile(ANY_IANA_ZONE)
    return re.compile("|".join(re.escape(z) for z in zones), re.IGNORECASE)


def call_args(mask: str, open_paren: int) -> list[tuple[int, int]]:
    """(start, end) of each top-level argument of the call opened at mask[open_paren]."""
    args, depth, start = [], 0, open_paren + 1
    for i in range(open_paren + 1, len(mask)):
        ch = mask[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                return args + [(start, i)]
            depth -= 1
        elif ch == "," and depth == 0:
            args.append((start, i))
            start = i + 1
    return args + [(start, len(mask))]


def is_double_shift(mask: str, open_paren: int) -> bool:
    """True if DATETIME('s first argument is TIMESTAMP(...) or CAST(... AS TIMESTAMP)."""
    start, end = call_args(mask, open_paren)[0]
    if TIMESTAMP_CALL.match(mask, start, end):
        return True
    cast = CAST_CALL.match(mask, start, end)
    if not cast:
        return False
    cast_start, cast_end = call_args(mask, cast.end() - 1)[-1]
    return bool(AS_TIMESTAMP.search(mask, cast_start, cast_end))


def jinja_zone_args(code: str, mask: str) -> list[int]:
    """Offsets of zone conversions whose zone is a Jinja expression."""
    found = []
    for m in ZONE_ARG_CALL.finditer(mask):
        args = call_args(mask, m.end() - 1)
        if len(args) == ZONE_ARG_CALLS[m.group(1).upper()] and JINJA_ARG.fullmatch(code, *args[-1]):
            found.append(m.start())
    for m in AT_TIME_ZONE.finditer(mask):
        if JINJA_START.match(code, m.end()):
            found.append(m.start())
    return found


def is_boundary(mask: str, start: int, end: int) -> bool:
    """True if the literal at mask[start:end] is the sole argument of CURRENT_*()."""
    return bool(BOUNDARY_OPEN.search(mask, 0, start) and BOUNDARY_CLOSE.match(mask, end))


def utc_layers() -> tuple[str, ...]:
    raw = os.environ.get("TZ_LINT_LAYERS", "models/staging,models/intermediate")
    return tuple(p.strip().rstrip("/") + "/" for p in raw.split(",") if p.strip())


def blank(segment: str) -> str:
    """Replace every character except newlines with a space, keeping offsets."""
    return "".join(ch if ch == "\n" else " " for ch in segment)


def scan(text: str) -> tuple[str, str, list[tuple[int, int, str]]]:
    """Separate code, comments and string literals, keeping every offset.

    Returns (code, mask, strings):
      code     the text with comments blanked; string literals kept verbatim.
      mask     code with string literals blanked too, for structural matching
               (so 'DATETIME(TIMESTAMP(' inside a string is not code).
      strings  (start, end, contents) of each string literal; start/end
               include the quotes.

    String-literal aware, so '--' or '%/*%' inside a string never starts a
    comment. Handles BigQuery single, double and backtick quotes, triple-quoted
    strings and backslash escapes. A single-quoted string ends at a newline
    (BigQuery does not let one span lines), so a stray quote cannot swallow the
    rest of the file.
    """
    code, mask, strings = [], [], []
    i, n = 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "--":
            j = text.find("\n", i)
            j = n if j < 0 else j
            code.append(blank(text[i:j]))
        elif two in ("/*", "{#"):
            j = text.find("*/" if two == "/*" else "#}", i + 2)
            j = n if j < 0 else j + 2
            code.append(blank(text[i:j]))
        elif text[i] in "'\"`":
            quote = text[i:i + 3] if text[i:i + 3] in ("'''", '"""') else text[i]
            j = i + len(quote)
            while j < n and not text.startswith(quote, j):
                if text[j] == "\\":
                    j += 2  # an escaped character never closes the string
                elif text[j] == "\n" and len(quote) == 1:
                    break
                else:
                    j += 1
            j = min(j, n)
            contents = text[i + len(quote):j]
            if text.startswith(quote, j):
                j += len(quote)
            strings.append((i, j, contents))
            code.append(text[i:j])
            mask.append(blank(text[i:j]))
            i = j
            continue
        else:
            j = i + 1
            code.append(text[i])
        mask.append(code[-1])
        i = j
    return "".join(code), "".join(mask), strings


def check_file(path: Path, rel: str, zone: re.Pattern, layers: tuple[str, ...]) -> list[str]:
    text = path.read_text(encoding="utf-8")
    raw = text.splitlines()
    code, mask, strings = scan(text)
    in_utc_layer = rel.startswith(layers)
    errors = []

    def suppressed(n: int) -> bool:
        return bool(SUPPRESS.search(raw[n]) or (n > 0 and SUPPRESS.search(raw[n - 1])))

    def line_of(offset: int) -> int:
        return mask.count("\n", 0, offset)

    conversions = set()
    if in_utc_layer:
        for start, end, contents in strings:
            if zone.fullmatch(contents) and not is_boundary(mask, start, end):
                conversions.add(line_of(start))
        conversions.update(line_of(offset) for offset in jinja_zone_args(code, mask))
    for n in sorted(conversions):
        if not suppressed(n):
            errors.append(
                f"{rel}:{n + 1}: timezone conversion before the mart layer -- keep UTC "
                f"TIMESTAMPs here and convert once in marts"
            )
    # Match the whole file: sqlfluff splits DATETIME(\n TIMESTAMP(x),\n tz) across
    # lines, which a per-line regex never sees.
    for m in DATETIME_CALL.finditer(mask):
        n = line_of(m.start())
        if is_double_shift(mask, m.end() - 1) and not suppressed(n):
            errors.append(
                f"{rel}:{n + 1}: DATETIME(TIMESTAMP(...)) -- the double-shift shape. If the "
                f"inner value is a real TIMESTAMP, add `-- tz-ok: <reason>`"
            )
    return errors


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    files = [f for f in sorted((root / "models").rglob("*.sql")) if not f.name.startswith("._")]
    if not files:
        print(f"No models found under {root / 'models'} -- refusing to report a clean pass")
        return 1
    zone, layers = zone_pattern(), utc_layers()
    errors = []
    for path in files:
        errors += check_file(path, path.relative_to(root).as_posix(), zone, layers)
    for e in errors:
        print(f"  FAIL  {e}")
    if errors:
        print(f"\n{len(errors)} timezone convention violation(s) in {len(files)} SQL files")
        return 1
    print(f"Timezone conventions hold across {len(files)} SQL files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
