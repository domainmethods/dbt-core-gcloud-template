#!/usr/bin/env python3
"""Enforce the two mechanically checkable timezone conventions (#68).

Convention: keep UTC TIMESTAMPs until the mart layer and convert once there.

1. No timezone conversion in the pre-mart layers (default: models/staging,
   models/intermediate). Any string literal naming a zone fails, except as the
   sole argument of a CURRENT_DATE / CURRENT_DATETIME / CURRENT_TIME /
   CURRENT_TIMESTAMP call: that boundary converts "now", not a column. Only the
   boundary call is exempt; another conversion on the same line still fails.
2. No `DATETIME(TIMESTAMP(...` anywhere in models/. This is the shape of the
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
                  "America/New_York,Europe/London". Default: any quoted IANA
                  zone ('Area/City').
  TZ_LINT_LAYERS  comma-separated directories that must stay UTC.
                  Default: "models/staging,models/intermediate".

No dbt, no warehouse: it reads models/**/*.sql only.

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
DOUBLE_SHIFT = re.compile(r"DATETIME\s*\(\s*TIMESTAMP\s*\(", re.IGNORECASE)
SUPPRESS = re.compile(r"--\s*tz-ok:\s*\S")
# The contents of a string literal naming an IANA zone, e.g. America/New_York.
ANY_IANA_ZONE = r"[A-Z][A-Za-z_]+/[A-Za-z_/+-]+"


def zone_pattern() -> re.Pattern:
    zones = [z.strip() for z in os.environ.get("TZ_LINT_ZONES", "").split(",") if z.strip()]
    if not zones:
        return re.compile(ANY_IANA_ZONE)
    return re.compile("|".join(re.escape(z) for z in zones), re.IGNORECASE)


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
    _, mask, strings = scan(text)
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
    for n in sorted(conversions):
        if not suppressed(n):
            errors.append(
                f"{rel}:{n + 1}: timezone conversion before the mart layer -- keep UTC "
                f"TIMESTAMPs here and convert once in marts"
            )
    # Match the whole file: sqlfluff splits DATETIME(\n TIMESTAMP(x),\n tz) across
    # lines, which a per-line regex never sees.
    for m in DOUBLE_SHIFT.finditer(mask):
        n = line_of(m.start())
        if not suppressed(n):
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
