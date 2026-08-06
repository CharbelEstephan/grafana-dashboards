"""
parse.py -- CSV section-splitter, row parsers, and shared transforms for the
workout export. Pure functions, no DB access, so they can be unit-tested and
reused by the loader.

The export is many CSV tables concatenated, each wrapped in banner lines:

    ### SECTION NAME ####################################
    <blank line>
    col1,col2,col3,...            <- header row
    <data rows...>
    ######################################################   <- footer banner
"""
from __future__ import annotations

import csv
import io
import re
from datetime import datetime, date, timezone
from typing import Iterator

# Section banner: "### NAME ####..."  (header banner, not the all-# footer)
_SECTION_RE = re.compile(r"^###\s+(.+?)\s+#+\s*$")
_FOOTER_RE = re.compile(r"^#{6,}\s*$")


# ---------------------------------------------------------------------------
# Section splitting
# ---------------------------------------------------------------------------
def split_sections(text: str) -> dict[str, list[dict]]:
    """Parse the whole export into {SECTION_NAME: [rowdict, ...]}.

    Defensive: tolerates blank lines, quoted commas, empty sections, and a
    missing footer at EOF. Unknown sections are still captured (harmless).
    """
    lines = text.splitlines()
    sections: dict[str, list[str]] = {}
    current: str | None = None
    buf: list[str] = []

    def flush():
        nonlocal buf, current
        if current is not None:
            sections[current] = buf
        buf = []

    for line in lines:
        m = _SECTION_RE.match(line)
        if m:
            flush()
            current = m.group(1).strip().upper()
            continue
        if _FOOTER_RE.match(line):
            flush()
            current = None
            continue
        if current is not None:
            buf.append(line)
    flush()

    out: dict[str, list[dict]] = {}
    for name, raw in sections.items():
        out[name] = _rows_to_dicts(raw)
    return out


def _rows_to_dicts(raw: list[str]) -> list[dict]:
    """Given a section's raw lines, find the header row and parse data rows."""
    # Drop leading blank lines
    idx = 0
    while idx < len(raw) and raw[idx].strip() == "":
        idx += 1
    if idx >= len(raw):
        return []
    header = next(csv.reader([raw[idx]]))
    header = [h.strip() for h in header]
    data_lines = [ln for ln in raw[idx + 1:] if ln.strip() != ""]
    if not data_lines:
        return []
    reader = csv.reader(io.StringIO("\n".join(data_lines)))
    rows = []
    for rec in reader:
        if not rec or all(c.strip() == "" for c in rec):
            continue
        # tolerate short/long rows
        d = {}
        for i, col in enumerate(header):
            d[col] = rec[i].strip() if i < len(rec) else ""
        rows.append(d)
    return rows


# ---------------------------------------------------------------------------
# Value coercion helpers
# ---------------------------------------------------------------------------
def to_int(v) -> int | None:
    if v is None:
        return None
    s = str(v).strip()
    if s == "":
        return None
    try:
        return int(float(s))
    except ValueError:
        return None


def to_num(v) -> float | None:
    if v is None:
        return None
    s = str(v).strip()
    if s == "":
        return None
    try:
        return float(s)
    except ValueError:
        return None


def zero_to_none(v) -> float | None:
    """For bodyweight/measurements: 0 means 'not recorded' -> NULL."""
    n = to_num(v)
    if n is None or n == 0:
        return None
    return n


def epoch_to_ts(v) -> datetime | None:
    """Unix epoch seconds -> aware UTC datetime. 0/empty -> None."""
    n = to_int(v)
    if not n:  # None or 0
        return None
    try:
        return datetime.fromtimestamp(n, tz=timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None


def parse_dt(v) -> datetime | None:
    """'YYYY-MM-DD HH:MM:SS' -> naive datetime (stored as timestamptz)."""
    s = (v or "").strip().strip('"')
    if not s:
        return None
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d"):
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            continue
    return None


def parse_date(v) -> date | None:
    """'YYYY-MM-DD' -> date."""
    s = (v or "").strip().strip('"')
    if not s:
        return None
    try:
        return datetime.strptime(s[:10], "%Y-%m-%d").date()
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# The compressed `logs` set string:  "45x20,95x20,95x20"
# ---------------------------------------------------------------------------
def parse_logs_string(s: str) -> list[tuple[float, int]]:
    """Parse 'weightxreps,weightxreps,...' -> [(weight, reps), ...].

    Defensive against blanks, trailing commas, missing pieces, and 'x'/'X'.
    """
    out: list[tuple[float, int]] = []
    if not s:
        return out
    for chunk in s.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        parts = re.split(r"[xX]", chunk)
        if len(parts) != 2:
            continue
        w = to_num(parts[0])
        r = to_int(parts[1])
        if w is None or r is None:
            continue
        out.append((w, r))
    return out


def epley_1rm(weight: float, reps: int) -> float:
    return weight * (1 + reps / 30.0)


# ---------------------------------------------------------------------------
# set_type normalization (known set + null/unknown -> 'default')
# ---------------------------------------------------------------------------
_KNOWN_SET_TYPES = {"default", "warm-up", "failure", "drop"}


def norm_set_type(v) -> str:
    s = (v or "").strip().lower()
    s = {"warmup": "warm-up", "warm up": "warm-up"}.get(s, s)
    return s if s in _KNOWN_SET_TYPES else "default"


# ---------------------------------------------------------------------------
# Keyword muscle/movement classifier (fallback + seed generator)
# ---------------------------------------------------------------------------
# Ordered rules: first hit wins. (regex, muscle_group, movement, is_compound)
_CLASSIFY_RULES: list[tuple[str, str, str, bool]] = [
    # legs
    (r"squat",                    "quads",      "legs", True),
    (r"leg press",                "quads",      "legs", True),
    (r"leg extension",            "quads",      "legs", False),
    (r"lunge|split squat|bulgarian", "quads",   "legs", True),
    (r"leg curl|hamstring|romanian|rdl|good ?morning", "hamstrings", "legs", False),
    (r"deadlift",                 "hamstrings", "legs", True),
    (r"calf|calves",              "calves",     "legs", False),
    (r"glute|hip thrust|abduct|adduct|abductor|thigh abduction", "glutes", "legs", False),
    # push -- chest
    (r"bench press|chest press|push ?up|pushup",  "chest",    "push", True),
    (r"\bfly|flye|pec ?deck|chest fly",           "chest",    "push", False),
    (r"\bdip\b",                                  "chest",    "push", True),
    # push -- shoulders
    (r"shoulder press|overhead press|military|arnold|ohp", "shoulders", "push", True),
    (r"lateral raise|side raise",                 "shoulders", "push", False),
    (r"front raise",                              "shoulders", "push", False),
    (r"rear delt|reverse fly|face pull",          "rear delts","pull", False),
    (r"shoulder raise|shoulder extension|around the world|casket", "shoulders", "push", False),
    (r"shrug|upright row",                        "traps",     "pull", False),
    # push -- triceps
    (r"tricep|pushdown|push ?down|skull ?crusher|french press|kickback|overhead extension|close grip",
                                                  "triceps",   "push", False),
    # pull -- back
    (r"pull ?up|chin ?up|pulldown|lat pull|lat ?pulldown|archer pull", "back", "pull", True),
    (r"\brow\b|row |rack pull",                   "back",      "pull", True),
    (r"pullover",                                 "back",      "pull", False),
    (r"hyperextension|hyper ?extension|back extension", "back", "pull", False),
    # chest -- cable crossovers
    (r"cross[ -]?over",                           "chest",     "push", False),
    # pull -- biceps / forearms
    (r"curl.*(wrist|reverse)|wrist curl|reverse curl|forearm", "forearms", "pull", False),
    (r"curl|bicep",                               "biceps",    "pull", False),
    # forearms (wrist roller before generic)
    (r"wrist roller|wrist curl|forearm",          "forearms",  "pull", False),
    # core
    (r"crunch|sit ?up|plank|ab |abs|oblique|leg raise|russian twist|hanging|side bend|pallof",
                                                  "abs",       "core", False),
]


def classify_exercise(name: str) -> tuple[str, str, bool]:
    """Return (muscle_group, movement, is_compound). Unknown -> ('Other','other',False)."""
    n = (name or "").lower()
    for pat, mg, mv, comp in _CLASSIFY_RULES:
        if re.search(pat, n):
            return mg, mv, comp
    return "Other", "other", False


# Manual overrides for my most-logged exercises (by canonical name) so the big
# ones are always correct regardless of keyword edge cases.
MANUAL_MAP: dict[str, tuple[str, str, bool]] = {
    "Barbell Bench Press":                              ("chest", "push", True),
    "Barbell Wide Grip Bench Press":                    ("chest", "push", True),
    "Barbell Decline Bench Press":                      ("chest", "push", True),
    "Machine Fly":                                      ("chest", "push", False),
    "Cable Tricep Pushdown (Rope)":                     ("triceps", "push", False),
    "Cable One-Arm Tricep Pushdown (Reverse Grip)":     ("triceps", "push", False),
    "Dumbbell Tricep Extension":                        ("triceps", "push", False),
    "Dumbbell Front Raise":                             ("shoulders", "push", False),
    "Barbell Shoulder Press":                           ("shoulders", "push", True),
    "Dumbbell Lateral Raise":                           ("shoulders", "push", False),
    "Dumbbell Seated Arnold Press":                     ("shoulders", "push", True),
    "Dumbbell Hammer Curl":                             ("biceps", "pull", False),
    "Barbell Preacher Curl":                            ("biceps", "pull", False),
    "Machine Leg Press":                                ("quads", "legs", True),
    "Barbell Squat":                                    ("quads", "legs", True),
    "Calf Press On Leg Press":                          ("calves", "legs", False),
    "Machine Seated Calf Raise":                        ("calves", "legs", False),
    "Cable Seated Row":                                 ("back", "pull", True),
    "Cable Lat Pulldown (Wide Grip)":                   ("back", "pull", True),
    "Barbell Deadlift":                                 ("back", "pull", True),
    "Barbell Romanian Deadlift":                        ("back", "pull", False),
    "Dumbbell Wrist Curl (Palms Up)":                   ("forearms", "pull", False),
}


def classify(name: str) -> tuple[str, str, bool]:
    """Manual override first, else keyword classifier."""
    if name in MANUAL_MAP:
        return MANUAL_MAP[name]
    return classify_exercise(name)
