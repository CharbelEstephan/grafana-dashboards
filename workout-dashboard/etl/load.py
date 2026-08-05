#!/usr/bin/env python3
"""
load.py -- idempotent loader for the workout export into Neon Postgres.

Usage:
    python etl/load.py <path-to-export.csv> [--truncate | --upsert]

    --truncate  (default)  full overwrite: TRUNCATE data tables, reload from
                           the file. Running twice on the same file yields an
                           identical DB. This is the normal "fresh export" flow.
    --upsert               INSERT ... ON CONFLICT (id) DO UPDATE keyed on the
                           stable _id's; incremental add without wiping.

Applies sql/001_schema.sql, sql/003_seed_muscle_map.sql and sql/002_views.sql
automatically, then loads. Reads NEON_DATABASE_URL from .env (never hardcoded).
Prints a validation report and exits non-zero on hard failures.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

try:
    import psycopg
    from psycopg import sql as _sql  # noqa: F401  (kept for future use)
except ImportError:
    sys.exit("psycopg (v3) not installed. Run: pip install -r requirements.txt")

try:
    from dotenv import load_dotenv
except ImportError:
    sys.exit("python-dotenv not installed. Run: pip install -r requirements.txt")

# Local imports (run from repo root or etl/)
sys.path.insert(0, str(Path(__file__).resolve().parent))
import parse as P  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SQL_DIR = ROOT / "sql"

# Data tables truncated on a full refresh. NOTE: exercise_muscle_map is
# deliberately excluded so hand edits to the muscle map survive a reload.
DATA_TABLES = [
    "workout.sets",
    "workout.exercise_logs",
    "workout.exercises",
    "workout.sessions",
    "workout.records",
    "workout.bodyweight",
    "workout.notes",
    "workout.custom_exercises",
    "workout.settings",
]


# ---------------------------------------------------------------------------
# SQL file execution (statement splitter that ignores -- line comments)
# ---------------------------------------------------------------------------
def _strip_line_comments(text: str) -> str:
    out = []
    for line in text.splitlines():
        i = line.find("--")
        out.append(line if i == -1 else line[:i])
    return "\n".join(out)


def run_sql_file(cur, path: Path) -> None:
    raw = path.read_text(encoding="utf-8")
    cleaned = _strip_line_comments(raw)
    for stmt in cleaned.split(";"):
        stmt = stmt.strip()
        if stmt:
            cur.execute(stmt)


def bulk_insert(cur, table: str, columns: list[str], rows: list[tuple],
                on_conflict: str | None = None) -> int:
    """executemany-based bulk insert; optional ON CONFLICT clause for --upsert."""
    if not rows:
        return 0
    ph = ", ".join(["%s"] * len(columns))
    cols = ", ".join(columns)
    conflict = f" {on_conflict}" if on_conflict else ""
    cur.executemany(f"INSERT INTO {table} ({cols}) VALUES ({ph}){conflict}", rows)
    return len(rows)


# ---------------------------------------------------------------------------
# Section -> table builders
# ---------------------------------------------------------------------------
def build_settings(sec) -> list[tuple]:
    rows = sec.get("SETTING", [])
    out = []
    for r in rows:
        out.append((
            P.to_int(r.get("row_id")),
            P.to_int(r.get("USERID")),
            r.get("gender") or None,
            P.parse_date(r.get("DOB")),
            (r.get("mass") or "").strip() or None,
            (r.get("length") or "").strip() or None,
            P.to_int(r.get("week_start")),
            P.parse_dt(r.get("TIMESTAMP")),
        ))
    return out


def build_sessions(sec) -> tuple[list[tuple], set[int]]:
    rows = sec.get("WORKOUT SESSIONS", [])
    out, ids = [], set()
    for r in rows:
        sid = P.to_int(r.get("_id"))
        if sid is None:
            continue
        ids.add(sid)
        out.append((
            sid,
            P.to_int(r.get("USERID")),
            P.to_int(r.get("day_id")),
            P.to_int(r.get("total_time")),
            P.to_int(r.get("workout_time")),
            P.to_int(r.get("rest_time")),
            P.to_int(r.get("wasted_time")),
            P.to_int(r.get("total_exercise")),
            P.to_num(r.get("total_weight")),
            P.to_int(r.get("recordbreak")),
            P.epoch_to_ts(r.get("starttime")),
            P.epoch_to_ts(r.get("endtime")),
            P.to_int(r.get("workout_mode")),
            P.to_num(r.get("calories")),
            P.to_num(r.get("avg_heart_rate")),
            P.epoch_to_ts(r.get("edit_time")),
        ))
    return out, ids


def build_exercises(sec) -> tuple[list[tuple], dict[int, str]]:
    """Canonical (latest ename) per eid from EXERCISE LOGS, unioned with
    CUSTOM EXERCISES. Returns rows + {eid: canonical_name}."""
    logs = sec.get("EXERCISE LOGS", [])
    latest: dict[int, tuple[int, str, bool]] = {}  # eid -> (logtime, name, is_system)
    for r in logs:
        eid = P.to_int(r.get("eid"))
        if eid is None:
            continue
        lt = P.to_int(r.get("logTime")) or 0
        name = (r.get("ename") or "").strip()
        is_sys = P.to_int(r.get("belongSys")) == 1
        if eid not in latest or lt >= latest[eid][0]:
            latest[eid] = (lt, name, is_sys)

    # Fold in custom exercises (id == eid) not already seen, or to fill names.
    for r in sec.get("CUSTOM EXERCISES", []):
        eid = P.to_int(r.get("_id"))
        if eid is None:
            continue
        name = (r.get("name") or "").strip()
        if eid not in latest:
            latest[eid] = (0, name, False)

    names = {eid: v[1] for eid, v in latest.items()}
    out = []
    for eid, (lt, name, is_sys) in sorted(latest.items()):
        out.append((eid, name or f"Exercise {eid}", is_sys))
    return out, names


def build_exercise_logs(sec, session_ids: set[int]) -> tuple[list[tuple], dict[int, str], dict[int, tuple]]:
    """Returns rows, {log_id: raw_logs}, {log_id: (log_time, workout_date, reported_1rm)}."""
    logs = sec.get("EXERCISE LOGS", [])
    out = []
    raw_by_log: dict[int, str] = {}
    meta_by_log: dict[int, tuple] = {}
    for r in logs:
        lid = P.to_int(r.get("_id"))
        if lid is None:
            continue
        eid = P.to_int(r.get("eid"))
        wdate = P.parse_date(r.get("mydate"))
        if wdate is None:
            continue  # workout_date is NOT NULL; skip pathological rows
        belong = P.to_int(r.get("belongsession"))
        session_id = belong if belong in session_ids else None
        log_time = P.epoch_to_ts(r.get("logTime"))
        reported = P.to_num(r.get("record"))
        raw_logs = (r.get("logs") or "").strip()
        is_sys = P.to_int(r.get("belongSys")) == 1
        out.append((
            lid, P.to_int(r.get("USERID")), eid, session_id, wdate,
            reported, is_sys, log_time, raw_logs,
        ))
        raw_by_log[lid] = raw_logs
        meta_by_log[lid] = (log_time, wdate, reported)
    return out, raw_by_log, meta_by_log


def build_sets(sec, log_ids: set[int], raw_by_log, meta_by_log) -> tuple[list[tuple], dict]:
    """THE unified set table. Per exercise_log: use real set-logs if any exist,
    else expand the parsed `logs` string. Returns rows + stats dict."""
    setlogs = sec.get("EXERCISE SET LOGS", [])
    grouped: dict[int, list[dict]] = {}
    orphans = 0
    for r in setlogs:
        parent = P.to_int(r.get("exercise_log_id"))
        if parent is None:
            continue
        if parent not in log_ids:
            orphans += 1
            continue
        grouped.setdefault(parent, []).append(r)

    rows: list[tuple] = []
    logs_from_setlogs = 0
    logs_from_string = 0
    parsed_set_count = 0

    for lid in log_ids:
        if lid in grouped:  # real set logs win
            logs_from_setlogs += 1
            for r in sorted(grouped[lid], key=lambda x: P.to_int(x.get("set_index")) or 0):
                rows.append((
                    lid,
                    P.to_int(r.get("set_index")),
                    P.to_num(r.get("weight_lbs")),
                    P.to_int(r.get("reps")),
                    P.norm_set_type(r.get("set_type")),
                    P.epoch_to_ts(r.get("log_time")),
                    "set_log",
                ))
        else:  # expand the compressed string
            parsed = P.parse_logs_string(raw_by_log.get(lid, ""))
            if not parsed:
                continue
            logs_from_string += 1
            log_time = meta_by_log[lid][0]
            for idx, (w, reps) in enumerate(parsed):
                parsed_set_count += 1
                rows.append((lid, idx, w, reps, "default", log_time, "parsed_string"))

    stats = {
        "logs_from_setlogs": logs_from_setlogs,
        "logs_from_string": logs_from_string,
        "parsed_sets": parsed_set_count,
        "orphan_setlog_rows": orphans,
    }
    return rows, stats


def build_records(sec) -> list[tuple]:
    out = []
    for r in sec.get("EXERCISE RECORDS", []):
        rid = P.to_int(r.get("_id"))
        if rid is None:
            continue
        out.append((
            rid, P.to_int(r.get("USERID")), P.to_int(r.get("eid")),
            P.to_int(r.get("belongSys")) == 1,
            P.to_num(r.get("record")), P.to_num(r.get("target1RM")),
            P.parse_date(r.get("mydate")), P.epoch_to_ts(r.get("recordReachTime")),
            P.to_int(r.get("sort_order")),
        ))
    return out


def build_bodyweight(sec) -> list[tuple]:
    out = []
    for r in sec.get("PROFILE", []):
        bid = P.to_int(r.get("_id"))
        if bid is None:
            continue
        out.append((
            bid, P.to_int(r.get("USERID")), P.parse_date(r.get("mydate")),
            P.zero_to_none(r.get("weight")), P.zero_to_none(r.get("fatpercent")),
            P.zero_to_none(r.get("chest")), P.zero_to_none(r.get("arms")),
            P.zero_to_none(r.get("waist")), P.zero_to_none(r.get("calves")),
            P.zero_to_none(r.get("height")), P.zero_to_none(r.get("hips")),
            P.zero_to_none(r.get("thighs")), P.zero_to_none(r.get("shoulders")),
            P.zero_to_none(r.get("neck")), P.zero_to_none(r.get("forearms")),
            P.epoch_to_ts(r.get("logTime")),
        ))
    return out


def build_notes(sec) -> list[tuple]:
    out = []
    for r in sec.get("NOTES", []):
        nid = P.to_int(r.get("_id"))
        if nid is None:
            continue
        out.append((
            nid, P.to_int(r.get("USERID")), P.to_int(r.get("eid")),
            P.to_int(r.get("belongSys")) == 1,
            (r.get("mynote") or "").strip() or None,
            (r.get("title") or "").strip() or None,
            P.parse_date(r.get("mydate")), P.epoch_to_ts(r.get("logTime")),
            P.to_int(r.get("label")), P.to_int(r.get("type")),
        ))
    return out


def build_custom(sec) -> list[tuple]:
    out = []
    for r in sec.get("CUSTOM EXERCISES", []):
        cid = P.to_int(r.get("_id"))
        if cid is None:
            continue
        out.append((
            cid, P.to_int(r.get("USERID")), (r.get("name") or "").strip() or None,
            (r.get("description") or "").strip() or None,
            P.to_int(r.get("bodypart")), P.to_int(r.get("bodypart2")),
            P.to_int(r.get("bodypart3")), P.to_int(r.get("equip1")),
            P.to_int(r.get("equip2")), P.to_int(r.get("recordtype")),
            P.to_int(r.get("unilateral")),
        ))
    return out


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def get_conn_str() -> str:
    load_dotenv(ROOT / ".env")
    url = os.getenv("NEON_DATABASE_URL")
    if not url:
        sys.exit("NEON_DATABASE_URL not set. Copy .env.example to .env and fill it in.")
    if "sslmode=" not in url:
        url += ("&" if "?" in url else "?") + "sslmode=require"
    return url


def main() -> int:
    ap = argparse.ArgumentParser(description="Load workout export into Neon Postgres.")
    ap.add_argument("csv", help="path to the export CSV")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--truncate", action="store_true", help="full overwrite (default)")
    mode.add_argument("--upsert", action="store_true", help="incremental ON CONFLICT upsert")
    args = ap.parse_args()

    csv_path = Path(args.csv)
    if not csv_path.exists():
        sys.exit(f"File not found: {csv_path}")
    upsert = args.upsert
    mode_label = "upsert" if upsert else "truncate"

    print(f"Reading {csv_path} ...")
    text = csv_path.read_text(encoding="utf-8", errors="replace")
    sec = P.split_sections(text)

    # Build everything in memory first
    settings = build_settings(sec)
    sessions, session_ids = build_sessions(sec)
    exercises, names = build_exercises(sec)
    ex_logs, raw_by_log, meta_by_log = build_exercise_logs(sec, session_ids)
    log_ids = {r[0] for r in ex_logs}
    sets, set_stats = build_sets(sec, log_ids, raw_by_log, meta_by_log)
    records = build_records(sec)
    bodyweight = build_bodyweight(sec)
    notes = build_notes(sec)
    custom = build_custom(sec)

    # Count exercises with renamed history (for the report)
    rename_count = _count_renames(sec)

    conn_str = get_conn_str()
    print(f"Connecting to Neon ... (mode: {mode_label})")
    with psycopg.connect(conn_str, autocommit=False) as conn:
        with conn.cursor() as cur:
            # 1. schema + muscle-map seed (idempotent)
            run_sql_file(cur, SQL_DIR / "001_schema.sql")
            run_sql_file(cur, SQL_DIR / "003_seed_muscle_map.sql")

            oc = None
            if upsert:
                # per-table conflict targets keyed on the stable PKs
                pass
            else:
                cur.execute(
                    "TRUNCATE " + ", ".join(DATA_TABLES) + " RESTART IDENTITY CASCADE"
                )

            def ins(table, cols, rows, pk="id"):
                conflict = f"ON CONFLICT ({pk}) DO UPDATE SET " + \
                    ", ".join(f"{c}=EXCLUDED.{c}" for c in cols if c != pk) \
                    if upsert else None
                return bulk_insert(cur, table, cols, rows, conflict)

            # 2. exercises FIRST (FK target for exercise_logs)
            ins("workout.exercises", ["eid", "canonical_name", "is_system"],
                exercises, pk="eid")

            ins("workout.settings",
                ["row_id", "userid", "gender", "dob", "mass_unit", "length_unit",
                 "week_start", "raw_timestamp"], settings, pk="row_id")

            ins("workout.sessions",
                ["id", "userid", "day_id", "total_time_s", "workout_time_s",
                 "rest_time_s", "wasted_time_s", "total_exercise", "total_weight",
                 "recordbreak", "starttime", "endtime", "workout_mode", "calories",
                 "avg_heart_rate", "edit_time"], sessions)

            ins("workout.exercise_logs",
                ["id", "userid", "eid", "session_id", "workout_date",
                 "est_1rm_reported", "is_system", "log_time", "raw_logs"], ex_logs)

            # sets: on upsert we can't key on a stable natural id (bigserial),
            # so upsert mode rebuilds sets for touched logs by deleting first.
            if upsert and sets:
                touched = tuple({r[0] for r in sets})
                cur.execute(
                    "DELETE FROM workout.sets WHERE exercise_log_id = ANY(%s)",
                    (list(touched),),
                )
            bulk_insert(cur, "workout.sets",
                        ["exercise_log_id", "set_index", "weight_lbs", "reps",
                         "set_type", "set_time", "source"], sets)

            ins("workout.records",
                ["id", "userid", "eid", "is_system", "record", "target_1rm",
                 "mydate", "record_reach_time", "sort_order"], records)

            ins("workout.bodyweight",
                ["id", "userid", "mydate", "weight_lbs", "fat_pct", "chest",
                 "arms", "waist", "calves", "height", "hips", "thighs",
                 "shoulders", "neck", "forearms", "log_time"], bodyweight)

            ins("workout.notes",
                ["id", "userid", "eid", "is_system", "mynote", "title", "mydate",
                 "log_time", "label", "type"], notes)

            ins("workout.custom_exercises",
                ["id", "userid", "name", "description", "bodypart", "bodypart2",
                 "bodypart3", "equip1", "equip2", "recordtype", "unilateral"],
                custom, pk="id")

            # 3. Classify any NEW eids into the (persistent) muscle map, then
            #    project the map onto exercises. Existing map rows are untouched.
            new_map_rows = []
            for eid, nm in names.items():
                mg, mv, comp = P.classify(nm)
                new_map_rows.append((eid, mg, mv, comp))
            bulk_insert(cur, "workout.exercise_muscle_map",
                        ["eid", "muscle_group", "movement", "is_compound"],
                        new_map_rows, "ON CONFLICT (eid) DO NOTHING")

            cur.execute("""
                UPDATE workout.exercises e
                SET muscle_group = m.muscle_group,
                    movement     = m.movement,
                    is_compound  = m.is_compound
                FROM workout.exercise_muscle_map m
                WHERE m.eid = e.eid
            """)

            # 4. views last (depend on loaded tables)
            run_sql_file(cur, SQL_DIR / "002_views.sql")

            # 5. validation report (reads back from DB)
            report = _validate(cur, set_stats, rename_count)

        conn.commit()

    ok = _print_report(report, set_stats, rename_count)
    return 0 if ok else 1


def _count_renames(sec) -> int:
    from collections import defaultdict
    names = defaultdict(set)
    for r in sec.get("EXERCISE LOGS", []):
        eid = P.to_int(r.get("eid"))
        if eid is None:
            continue
        names[eid].add((r.get("ename") or "").strip())
    return sum(1 for e in names if len(names[e]) > 1)


def _validate(cur, set_stats, rename_count) -> dict:
    def scalar(q):
        cur.execute(q)
        return cur.fetchone()[0]

    counts = {}
    for t in ["sessions", "exercise_logs", "sets", "exercises", "records",
              "bodyweight", "notes", "custom_exercises"]:
        counts[t] = scalar(f"SELECT COUNT(*) FROM workout.{t}")

    cur.execute("SELECT MIN(workout_date), MAX(workout_date) FROM workout.exercise_logs")
    dmin, dmax = cur.fetchone()

    # Epley spot-check: best computed 1RM per log vs reported, tolerance 1.0
    cur.execute("""
        WITH best AS (
            SELECT s.exercise_log_id, MAX(s.est_1rm) AS computed
            FROM workout.sets s GROUP BY s.exercise_log_id
        )
        SELECT
            COUNT(*) FILTER (WHERE el.est_1rm_reported IS NOT NULL),
            COUNT(*) FILTER (WHERE el.est_1rm_reported IS NOT NULL
                             AND abs(b.computed - el.est_1rm_reported) <= 1.0)
        FROM best b JOIN workout.exercise_logs el ON el.id = b.exercise_log_id
    """)
    checked, within = cur.fetchone()

    return {
        "counts": counts,
        "date_span": (dmin, dmax),
        "epley_checked": checked or 0,
        "epley_within_tol": within or 0,
        "rename_count": rename_count,
    }


def _print_report(report, set_stats, rename_count) -> bool:
    c = report["counts"]
    dmin, dmax = report["date_span"]
    print("\n" + "=" * 58)
    print(" VALIDATION REPORT")
    print("=" * 58)
    for t, n in c.items():
        print(f"  {t:<18} {n:>7}")
    print(f"  date span          {dmin} -> {dmax}")
    print("-" * 58)
    print(f"  logs from set-logs {set_stats['logs_from_setlogs']:>7}")
    print(f"  logs from string   {set_stats['logs_from_string']:>7}")
    print(f"  parsed sets        {set_stats['parsed_sets']:>7}")
    print(f"  orphan set-logs    {set_stats['orphan_setlog_rows']:>7}  (skipped)")
    print(f"  renamed eids       {rename_count:>7}")
    checked = report["epley_checked"]
    within = report["epley_within_tol"]
    pct = (100.0 * within / checked) if checked else 0.0
    print(f"  epley match        {within}/{checked}  ({pct:.1f}% within 1.0)")
    print("=" * 58)

    # Hard-failure gates
    problems = []
    if c["sessions"] == 0 or c["exercise_logs"] == 0 or c["sets"] == 0:
        problems.append("a core table is empty")
    if checked and pct < 90.0:
        problems.append(f"Epley cross-check only {pct:.1f}% within tolerance")
    if problems:
        print("FAILED: " + "; ".join(problems))
        return False
    print("OK: load complete.")
    return True


if __name__ == "__main__":
    sys.exit(main())
