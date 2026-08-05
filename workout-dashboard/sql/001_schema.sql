-- =====================================================================
-- 001_schema.sql  --  Workout analytics schema (Neon Postgres)
-- Idempotent: safe to run on every loader invocation.
-- All object creation uses IF NOT EXISTS / OR REPLACE so re-runs are no-ops.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS workout;

-- ---------------------------------------------------------------------
-- settings : the single SETTING row (units, DOB) for reference / age calc
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS workout.settings (
    row_id        bigint PRIMARY KEY,
    userid        bigint,
    gender        text,
    dob           date,
    mass_unit     text,        -- e.g. "lbs"
    length_unit   text,        -- e.g. "inches"
    week_start    int,
    raw_timestamp timestamptz
);

-- ---------------------------------------------------------------------
-- exercises : one row per eid, canonical (latest) name + enrichment.
-- Populated from distinct eids in EXERCISE LOGS + CUSTOM EXERCISES.
-- muscle_group / movement / is_compound are filled from the (editable)
-- exercise_muscle_map after load, so hand edits survive a full refresh.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS workout.exercises (
    eid            int PRIMARY KEY,
    canonical_name text NOT NULL,
    is_system      boolean,
    muscle_group   text,
    movement       text,       -- push / pull / legs / core / other
    is_compound    boolean,
    equipment      text
);

-- ---------------------------------------------------------------------
-- exercise_muscle_map : editable enrichment lookup. NOT truncated by the
-- loader; seeded via 003_seed_muscle_map.sql (ON CONFLICT DO NOTHING) and
-- topped up by the loader's keyword classifier for newly seen eids.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS workout.exercise_muscle_map (
    eid          int PRIMARY KEY,
    muscle_group text,
    movement     text,
    is_compound  boolean
);

-- ---------------------------------------------------------------------
-- sessions : one row per training session (WORKOUT SESSIONS)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS workout.sessions (
    id              bigint PRIMARY KEY,          -- _id (unique per user)
    userid          bigint,
    day_id          bigint,
    total_time_s    int,
    workout_time_s  int,
    rest_time_s     int,
    wasted_time_s   int,
    total_exercise  int,
    total_weight    numeric,                     -- app-computed volume proxy
    recordbreak     int,
    starttime       timestamptz,
    endtime         timestamptz,
    workout_mode    int,
    calories        numeric,
    avg_heart_rate  numeric,
    edit_time       timestamptz,
    workout_minutes numeric GENERATED ALWAYS AS (workout_time_s / 60.0) STORED
);

-- ---------------------------------------------------------------------
-- exercise_logs : one row per (exercise, session) (EXERCISE LOGS)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS workout.exercise_logs (
    id                bigint PRIMARY KEY,        -- _id (unique per user)
    userid            bigint,
    eid               int  REFERENCES workout.exercises(eid),
    session_id        bigint,                    -- -> sessions.id (soft ref; orphans nulled)
    workout_date      date NOT NULL,
    est_1rm_reported  numeric,                   -- app's `record` col, kept for cross-check
    is_system         boolean,
    log_time          timestamptz,
    raw_logs          text                       -- original "wxr,wxr,..." string
);

-- ---------------------------------------------------------------------
-- sets : THE unified set table. Merges normalized EXERCISE SET LOGS
-- (recent) with sets parsed from the older `logs` strings, without
-- double-counting. `source` distinguishes the two.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS workout.sets (
    id              bigserial PRIMARY KEY,
    exercise_log_id bigint NOT NULL REFERENCES workout.exercise_logs(id) ON DELETE CASCADE,
    set_index       int,
    weight_lbs      numeric,
    reps            int,
    set_type        text NOT NULL DEFAULT 'default'
                        CHECK (set_type IN ('default','warm-up','failure','drop')),
    set_time        timestamptz,                 -- per-set epoch (set_log) or log time (parsed)
    source          text NOT NULL CHECK (source IN ('set_log','parsed_string')),
    volume          numeric GENERATED ALWAYS AS (weight_lbs * reps) STORED,
    est_1rm         numeric GENERATED ALWAYS AS (weight_lbs * (1 + reps / 30.0)) STORED
);

-- ---------------------------------------------------------------------
-- records : per-eid PR (best est 1RM) + when reached (EXERCISE RECORDS)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS workout.records (
    id                bigint PRIMARY KEY,        -- _id
    userid            bigint,
    eid               int,
    is_system         boolean,
    record            numeric,                   -- best reported est 1RM
    target_1rm        numeric,
    mydate            date,
    record_reach_time timestamptz,
    sort_order        int
);

-- ---------------------------------------------------------------------
-- bodyweight : bodyweight + body measurements over time (PROFILE)
-- 0 -> NULL applied by the loader for weight/measurements.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS workout.bodyweight (
    id         bigint PRIMARY KEY,               -- _id
    userid     bigint,
    mydate     date,
    weight_lbs numeric,
    fat_pct    numeric,
    chest      numeric,
    arms       numeric,
    waist      numeric,
    calves     numeric,
    height     numeric,
    hips       numeric,
    thighs     numeric,
    shoulders  numeric,
    neck       numeric,
    forearms   numeric,
    log_time   timestamptz
);

-- ---------------------------------------------------------------------
-- notes : freeform notes tied to a date (NOTES) -> Grafana annotations
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS workout.notes (
    id        bigint PRIMARY KEY,                -- _id
    userid    bigint,
    eid       int,
    is_system boolean,
    mynote    text,
    title     text,
    mydate    date,
    log_time  timestamptz,
    label     int,
    type      int
);

-- ---------------------------------------------------------------------
-- custom_exercises : raw user-defined exercise metadata (CUSTOM EXERCISES)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS workout.custom_exercises (
    id          int PRIMARY KEY,                 -- _id
    userid      bigint,
    name        text,
    description text,
    bodypart    int,
    bodypart2   int,
    bodypart3   int,
    equip1      int,
    equip2      int,
    recordtype  int,
    unilateral  int
);

-- ---------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_sets_exercise_log   ON workout.sets(exercise_log_id);
CREATE INDEX IF NOT EXISTS idx_sets_set_time       ON workout.sets(set_time);
CREATE INDEX IF NOT EXISTS idx_sets_set_type       ON workout.sets(set_type);
CREATE INDEX IF NOT EXISTS idx_logs_eid            ON workout.exercise_logs(eid);
CREATE INDEX IF NOT EXISTS idx_logs_session        ON workout.exercise_logs(session_id);
CREATE INDEX IF NOT EXISTS idx_logs_date           ON workout.exercise_logs(workout_date);
CREATE INDEX IF NOT EXISTS idx_bodyweight_mydate   ON workout.bodyweight(mydate);
CREATE INDEX IF NOT EXISTS idx_records_eid         ON workout.records(eid);
