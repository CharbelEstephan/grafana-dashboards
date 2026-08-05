# Workout Analytics — Neon Postgres + Grafana

A personal analytics pipeline for my weightlifting history. It turns the multi-section CSV
export from my workout app into a clean **Neon Postgres** schema and an importable
**Grafana** dashboard covering progression, endurance, all-time highs, bodyweight-relative
strength, volume, and consistency.

The loader is **idempotent**: drop a fresh full export in `data/`, re-run one command, and
the database reflects exactly the new file — no duplicates, no manual cleanup.

```
workout-dashboard/
  README.md                  # this file
  .env.example               # NEON_DATABASE_URL=...  (copy to .env; never committed)
  requirements.txt           # psycopg[binary], python-dotenv
  sql/
    001_schema.sql           # tables + indexes (idempotent, CREATE IF NOT EXISTS)
    002_views.sql            # analytics views the dashboard queries
    003_seed_muscle_map.sql  # editable eid -> muscle/movement lookup
  etl/
    load.py                  # idempotent loader (entrypoint)
    parse.py                 # CSV section-splitter, row parsers, classifier
  grafana/
    dashboard.json           # importable Grafana dashboard model
    datasource.md            # how to wire the Neon Postgres datasource
  data/                      # drop exports here (gitignored)
```

## Setup

1. **Create the Neon database.** In the [Neon console](https://console.neon.tech), create a
   project + database, then copy the connection string (**Connection Details**). It looks like
   `postgresql://user:pass@ep-xxxx.us-east-2.aws.neon.tech/neondb?sslmode=require`.

2. **Configure the pipeline:**
   ```bash
   pip install -r requirements.txt
   cp .env.example .env        # then paste your NEON_DATABASE_URL into .env
   ```

3. **Load the data.** Put your export in `data/` and run:
   ```bash
   python etl/load.py data/export.csv
   ```
   The first run automatically applies `sql/001_schema.sql`, `sql/003_seed_muscle_map.sql`,
   and `sql/002_views.sql`, then loads the CSV and prints a validation report.

4. **In Grafana:** add the Postgres data source (see [`grafana/datasource.md`](grafana/datasource.md)),
   then **Import** `grafana/dashboard.json` and pick that data source. Done.

## Re-importing new data

> Export a fresh **full** CSV from the app, drop it in `data/`, and run:
> ```bash
> python etl/load.py data/<newfile>.csv
> ```
> That's it. `--truncate` (the default) wipes the data tables and reloads from the file, so
> the DB always matches the latest export. Running it twice on the same file yields identical
> state.

**Incremental mode (optional):** `python etl/load.py data/<newfile>.csv --upsert` does
`INSERT ... ON CONFLICT (id) DO UPDATE` on the stable `_id`s instead of wiping — useful for
adding recent sessions without a full reload.

Your hand-edited **muscle map is preserved** across `--truncate` reloads (the loader never
truncates `workout.exercise_muscle_map`); only new exercises get auto-classified and appended.

## How the data model works

- **Units:** mass = **lbs**, length = **inches** (from the app's `SETTING`).
- **Canonical names:** ~20 exercise ids were renamed over time; each `eid` displays its
  **most recent** name, but all history stays keyed by `eid`.
- **The unified `sets` table** merges two sources without double-counting:
  - Logs with normalized `EXERCISE SET LOGS` rows (Dec 2024+) use those — richer
    (`set_type`, per-set timestamps).
  - Older logs are expanded from the compressed `logs` string (`"95x20,95x20,..."`) into
    synthetic `default` sets.
  - `sets.source` ∈ {`set_log`, `parsed_string`} tells you which. This gives set-level
    granularity across the full **2023 → present** history.
- **Working sets** = everything except `warm-up`. The dashboard's **Set type** variable
  filters to working sets by default.
- **1RM** is Epley: `weight × (1 + reps/30)`, computed per set. Validated against the app's
  reported `record` column (~99.9% within 1.0 on the current export).
- **Strength score** = best working 1RM ÷ nearest-date bodyweight (a `LATERAL` closest-date
  join in `v_strength_score`).

## Correcting the muscle map

The export only ships bodypart codes for custom exercises, so push/pull/legs and
muscle-group analytics use a lookup you own: `workout.exercise_muscle_map`. It's pre-seeded
by classifying exercise names. To fix an entry, either edit
[`sql/003_seed_muscle_map.sql`](sql/003_seed_muscle_map.sql) and reload, or update the table
directly:

```sql
UPDATE workout.exercise_muscle_map
SET muscle_group = 'back', movement = 'pull', is_compound = true
WHERE eid = 21;                       -- then it flows into workout.exercises on next load
```

Any exercise not in the map still renders under muscle group **"Other"** — data is never
dropped.

## Validation report

Every load prints row counts per table, date span, how many logs came from set-logs vs
parsed strings, orphan set-log rows skipped, renamed-eid count, and the Epley cross-check.
The loader **exits non-zero** if a core table is empty or the Epley match falls below 90%.
