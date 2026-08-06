-- =====================================================================
-- 002_views.sql  --  Derived analytics views the Grafana dashboard queries.
-- All CREATE OR REPLACE -> idempotent. Run after tables are loaded.
-- Panels should query these views so their SQL stays short.
-- =====================================================================

-- Drop views first (CASCADE) so column additions/reorders never collide with
-- CREATE OR REPLACE's append-only rule. Views are cheap and rebuilt below.
-- Dropping the roots CASCADEs to everything derived from them.
DROP VIEW IF EXISTS workout.v_muscle_area   CASCADE;
DROP VIEW IF EXISTS workout.v_sets          CASCADE;
DROP VIEW IF EXISTS workout.v_date_bodyweight CASCADE;
DROP VIEW IF EXISTS workout.v_bodyweight    CASCADE;
DROP VIEW IF EXISTS workout.v_consistency_week  CASCADE;
DROP VIEW IF EXISTS workout.v_consistency_month CASCADE;
DROP VIEW IF EXISTS workout.v_current_streak CASCADE;

-- ---------------------------------------------------------------------
-- v_muscle_area : maps the specific muscle_group to a general training
-- area (Legs / Chest / Back / Shoulders / Arms / Core). The dashboard's
-- top filter uses the area; the second filter uses the specific muscle.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_muscle_area AS
SELECT DISTINCT
    muscle_group,
    CASE
        WHEN muscle_group IN ('quads','hamstrings','calves','glutes') THEN 'Legs'
        WHEN muscle_group =  'chest'                                   THEN 'Chest'
        WHEN muscle_group IN ('back','rear delts')                     THEN 'Back'
        WHEN muscle_group IN ('shoulders','traps')                     THEN 'Shoulders'
        WHEN muscle_group IN ('biceps','triceps','forearms')          THEN 'Arms'
        WHEN muscle_group =  'abs'                                     THEN 'Core'
        ELSE 'Other'
    END AS muscle_area
FROM workout.exercises
WHERE muscle_group IS NOT NULL;

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
    COALESCE(ma.muscle_area, 'Other') AS muscle_area,
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
JOIN workout.exercises      e  ON e.eid = el.eid
LEFT JOIN workout.v_muscle_area ma ON ma.muscle_group = e.muscle_group;

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
-- v_date_bodyweight : nearest-date bodyweight for every workout date.
-- (LATERAL closest-date join, computed once over distinct workout dates.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_date_bodyweight AS
SELECT d.workout_date, bw.weight_lbs AS bodyweight_lbs
FROM (SELECT DISTINCT workout_date FROM workout.exercise_logs) d
JOIN LATERAL (
    SELECT weight_lbs FROM workout.bodyweight b
    WHERE b.weight_lbs IS NOT NULL
    ORDER BY abs(b.mydate - d.workout_date)
    LIMIT 1
) bw ON TRUE;

-- ---------------------------------------------------------------------
-- v_sets_rel : every set with its bodyweight-relative load
-- (weight lifted / nearest-date bodyweight). Basis for custom strength score.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_sets_rel AS
SELECT s.eid, s.canonical_name, s.muscle_group, s.muscle_area, s.movement,
       s.workout_date, s.set_time, s.weight_lbs, s.reps, s.set_type,
       s.is_working, s.volume, s.est_1rm,
       db.bodyweight_lbs,
       s.weight_lbs / NULLIF(db.bodyweight_lbs, 0) AS rel_weight
FROM workout.v_sets s
JOIN workout.v_date_bodyweight db ON db.workout_date = s.workout_date;

-- ---------------------------------------------------------------------
-- v_rel_strength_week : custom Strength Score over time, per exercise.
-- Two switchable bases (working sets only):
--   heaviest_score = max(weight/bodyweight)  -> raw top-end strength
--   avg_score      = avg(weight/bodyweight)  -> smoother working strength
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_rel_strength_week AS
SELECT
    date_trunc('week', workout_date)::date AS week,
    eid, canonical_name,
    COALESCE(muscle_group, 'Other') AS muscle_group,
    COALESCE(muscle_area, 'Other')  AS muscle_area,
    COALESCE(movement, 'other')     AS movement,
    ROUND(max(rel_weight) FILTER (WHERE is_working), 3) AS heaviest_score,
    ROUND(avg(rel_weight) FILTER (WHERE is_working), 3) AS avg_score
FROM workout.v_sets_rel
GROUP BY 1, 2, 3, 4, 5, 6;

-- ---------------------------------------------------------------------
-- v_muscle_rel_strength_week : same custom score aggregated per muscle
-- group (for the by-muscle-group overview section).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_muscle_rel_strength_week AS
SELECT
    date_trunc('week', workout_date)::date AS week,
    COALESCE(muscle_group, 'Other') AS muscle_group,
    ROUND(max(rel_weight) FILTER (WHERE is_working), 3) AS heaviest_score,
    ROUND(avg(rel_weight) FILTER (WHERE is_working), 3) AS avg_score
FROM workout.v_sets_rel
GROUP BY 1, 2;

-- ---------------------------------------------------------------------
-- v_strength_curve : per exercise, the heaviest working weight achieved
-- at each rep count (1..20). The load drop-off curve for planning.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_strength_curve AS
SELECT
    eid, canonical_name,
    COALESCE(muscle_group, 'Other') AS muscle_group,
    COALESCE(muscle_area, 'Other')  AS muscle_area,
    COALESCE(movement, 'other')     AS movement,
    reps,
    max(weight_lbs) AS max_weight,
    count(*)        AS times_done
FROM workout.v_sets
WHERE is_working AND reps BETWEEN 1 AND 20
GROUP BY eid, canonical_name, muscle_group, muscle_area, movement, reps;

-- ---------------------------------------------------------------------
-- v_one_rep_max : dual 1RM per exercise (working sets).
--   actual_1rm  = heaviest TRUE single (reps = 1) if any exist, else the
--                 heaviest weight lifted at any rep count.
--   est_1rm     = best Epley estimate from the data.
-- has_true_single flags whether actual_1rm came from a real 1-rep set
-- (will fill in as quarterly 1RM days get logged).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW workout.v_one_rep_max AS
SELECT
    canonical_name,
    muscle_area,
    max(weight_lbs) FILTER (WHERE reps = 1)                 AS best_single,
    max(weight_lbs)                                         AS heaviest_set,
    COALESCE(max(weight_lbs) FILTER (WHERE reps = 1),
             max(weight_lbs))                               AS actual_1rm,
    (max(weight_lbs) FILTER (WHERE reps = 1) IS NOT NULL)   AS has_true_single,
    ROUND(max(est_1rm), 1)                                  AS est_1rm
FROM workout.v_sets
WHERE is_working
GROUP BY canonical_name, muscle_area;

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
