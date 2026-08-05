-- =====================================================================
-- 002_views.sql  --  Derived analytics views the Grafana dashboard queries.
-- All CREATE OR REPLACE -> idempotent. Run after tables are loaded.
-- Panels should query these views so their SQL stays short.
-- =====================================================================

-- ---------------------------------------------------------------------
-- v_sets : the workhorse. Every set with its log/exercise/muscle context.
-- `is_working` = TRUE for everything except warm-up sets.
-- Use `workout_date` for daily/weekly buckets, `set_time` for fine ts.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_sets AS
SELECT
    s.id                AS set_id,
    s.exercise_log_id,
    el.session_id,
    el.eid,
    e.canonical_name,
    e.muscle_group,
    e.movement,
    e.is_compound,
    el.workout_date,
    COALESCE(s.set_time, el.log_time, el.workout_date::timestamptz) AS set_time,
    s.set_index,
    s.weight_lbs,
    s.reps,
    s.set_type,
    (s.set_type IS DISTINCT FROM 'warm-up') AS is_working,
    s.volume,
    s.est_1rm,
    s.source
FROM workout.sets s
JOIN workout.exercise_logs el ON el.id = s.exercise_log_id
JOIN workout.exercises      e  ON e.eid = el.eid;

-- ---------------------------------------------------------------------
-- v_daily_exercise : per (eid, day) best working-set 1RM & heaviest set.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_daily_exercise AS
SELECT
    eid,
    canonical_name,
    muscle_group,
    movement,
    workout_date,
    MAX(set_time)                            AS day_ts,
    MAX(est_1rm)    FILTER (WHERE is_working) AS best_1rm,
    MAX(weight_lbs) FILTER (WHERE is_working) AS heaviest_weight,
    SUM(volume)     FILTER (WHERE is_working) AS working_volume,
    COUNT(*)        FILTER (WHERE is_working) AS working_sets,
    SUM(reps)       FILTER (WHERE is_working) AS working_reps
FROM workout.v_sets
GROUP BY eid, canonical_name, muscle_group, movement, workout_date;

-- ---------------------------------------------------------------------
-- v_session_stats : per-session rollups (durations + computed volume).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_session_stats AS
SELECT
    ss.id                       AS session_id,
    ss.starttime,
    ss.endtime,
    ss.workout_time_s,
    ss.rest_time_s,
    ss.workout_minutes,
    ss.total_exercise,
    COALESCE(v.total_volume, 0) AS computed_volume,
    COALESCE(v.total_sets, 0)   AS total_sets,
    COALESCE(v.total_reps, 0)   AS total_reps,
    CASE WHEN ss.workout_time_s > 0
         THEN ss.rest_time_s::numeric / ss.workout_time_s END AS rest_to_work_ratio
FROM workout.sessions ss
LEFT JOIN (
    SELECT session_id,
           SUM(volume) FILTER (WHERE is_working) AS total_volume,
           COUNT(*)    FILTER (WHERE is_working) AS total_sets,
           SUM(reps)   FILTER (WHERE is_working) AS total_reps
    FROM workout.v_sets
    WHERE session_id IS NOT NULL
    GROUP BY session_id
) v ON v.session_id = ss.id;

-- ---------------------------------------------------------------------
-- v_weekly_volume : total working volume per ISO week.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_weekly_volume AS
SELECT
    date_trunc('week', workout_date)::date AS week,
    SUM(volume)                            AS volume,
    SUM(reps)                              AS reps,
    COUNT(*)                               AS sets
FROM workout.v_sets
WHERE is_working
GROUP BY 1;

-- ---------------------------------------------------------------------
-- v_muscle_volume_week : working volume per muscle group per week.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_muscle_volume_week AS
SELECT
    date_trunc('week', workout_date)::date        AS week,
    COALESCE(muscle_group, 'Other')               AS muscle_group,
    SUM(volume)                                   AS volume
FROM workout.v_sets
WHERE is_working
GROUP BY 1, 2;

-- ---------------------------------------------------------------------
-- v_movement_volume : push / pull / legs volume split (all-time & weekly).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_movement_volume AS
SELECT
    date_trunc('week', workout_date)::date AS week,
    COALESCE(movement, 'other')            AS movement,
    SUM(volume)                            AS volume
FROM workout.v_sets
WHERE is_working
GROUP BY 1, 2;

-- ---------------------------------------------------------------------
-- v_exercise_totals : lifetime rollups per exercise (working sets).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_exercise_totals AS
SELECT
    eid,
    canonical_name,
    muscle_group,
    movement,
    SUM(volume)                    AS lifetime_volume,
    COUNT(*)                       AS total_sets,
    SUM(reps)                      AS total_reps,
    COUNT(DISTINCT workout_date)   AS days_trained,
    MAX(est_1rm)                   AS best_1rm,
    MAX(weight_lbs)                AS heaviest_weight
FROM workout.v_sets
WHERE is_working
GROUP BY eid, canonical_name, muscle_group, movement;

-- ---------------------------------------------------------------------
-- v_consistency_week / _month : workout counts per period.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_consistency_week AS
SELECT date_trunc('week',  starttime)::date AS period, COUNT(*) AS workouts
FROM workout.sessions WHERE starttime IS NOT NULL GROUP BY 1;

CREATE OR REPLACE VIEW workout.v_consistency_month AS
SELECT date_trunc('month', starttime)::date AS period, COUNT(*) AS workouts
FROM workout.sessions WHERE starttime IS NOT NULL GROUP BY 1;

-- ---------------------------------------------------------------------
-- v_bodyweight : cleaned bodyweight/measurements (already 0->NULL on load).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_bodyweight AS
SELECT mydate, weight_lbs, fat_pct,
       chest, arms, waist, calves, hips, thighs, shoulders, neck, forearms
FROM workout.bodyweight
WHERE weight_lbs IS NOT NULL
ORDER BY mydate;

-- ---------------------------------------------------------------------
-- v_strength_score : daily best working 1RM per exercise divided by the
-- nearest-date bodyweight (LATERAL closest-date join).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_strength_score AS
SELECT
    d.eid,
    d.canonical_name,
    d.workout_date,
    d.best_1rm,
    bw.weight_lbs                          AS bodyweight_lbs,
    ROUND(d.best_1rm / bw.weight_lbs, 3)   AS strength_score
FROM workout.v_daily_exercise d
JOIN LATERAL (
    SELECT weight_lbs
    FROM workout.bodyweight b
    WHERE b.weight_lbs IS NOT NULL
    ORDER BY abs(b.mydate - d.workout_date)
    LIMIT 1
) bw ON TRUE
WHERE d.best_1rm IS NOT NULL;

-- ---------------------------------------------------------------------
-- v_prs : computed PR per exercise, cross-checked vs the app's records.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_prs AS
WITH computed AS (
    SELECT
        eid, canonical_name,
        MAX(est_1rm)                                       AS computed_best_1rm,
        MAX(weight_lbs)                                    AS heaviest_set,
        (ARRAY_AGG(workout_date ORDER BY est_1rm DESC))[1] AS best_1rm_date
    FROM workout.v_sets
    WHERE is_working
    GROUP BY eid, canonical_name
)
SELECT
    c.eid,
    c.canonical_name,
    ROUND(c.computed_best_1rm, 2) AS computed_best_1rm,
    c.heaviest_set,
    c.best_1rm_date,
    r.record                      AS reported_best_1rm,
    r.record_reach_time::date     AS reported_reach_date,
    ROUND(c.computed_best_1rm - r.record, 2) AS delta_vs_reported
FROM computed c
LEFT JOIN (
    -- an eid can have multiple EXERCISE RECORDS rows; keep its best (max) 1RM
    SELECT DISTINCT ON (eid) eid, record, record_reach_time
    FROM workout.records
    ORDER BY eid, record DESC NULLS LAST
) r ON r.eid = c.eid;

-- ---------------------------------------------------------------------
-- v_overview : single-row headline stats for the Overview stat panels.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_overview AS
SELECT
    (SELECT COUNT(*) FROM workout.sessions)                              AS total_workouts,
    (SELECT COUNT(*) FROM workout.v_sets WHERE is_working)              AS total_sets,
    (SELECT COALESCE(SUM(reps),0) FROM workout.v_sets WHERE is_working) AS total_reps,
    (SELECT COALESCE(SUM(volume),0) FROM workout.v_sets WHERE is_working) AS lifetime_volume,
    (SELECT COALESCE(SUM(workout_time_s),0)/3600.0 FROM workout.sessions) AS total_hours,
    (SELECT weight_lbs FROM workout.bodyweight
       WHERE weight_lbs IS NOT NULL ORDER BY mydate DESC LIMIT 1)        AS current_bodyweight,
    (SELECT COUNT(DISTINCT eid) FROM workout.exercise_logs)             AS distinct_exercises;

-- ---------------------------------------------------------------------
-- v_current_streak : consecutive-weeks-with-a-workout streak ending now.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_current_streak AS
WITH weeks AS (
    SELECT DISTINCT date_trunc('week', starttime)::date AS wk
    FROM workout.sessions WHERE starttime IS NOT NULL
),
seq AS (
    SELECT wk,
           (wk - (ROW_NUMBER() OVER (ORDER BY wk) * INTERVAL '7 day'))::date AS grp
    FROM weeks
),
runs AS (
    SELECT grp, COUNT(*) AS len, MAX(wk) AS last_wk
    FROM seq GROUP BY grp
)
SELECT COALESCE(MAX(len), 0) AS streak_weeks
FROM runs
WHERE last_wk >= date_trunc('week', now())::date - INTERVAL '7 day';
