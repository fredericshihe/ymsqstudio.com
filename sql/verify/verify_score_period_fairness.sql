-- 评分周期公平性验证（只读）
-- 预期：所有 *_violations 均为 0；于小荷 8/10、8/17、8/24 均为 0 分。

WITH active_snapshot_weeks AS (
  SELECT DISTINCT
    ps.student_name,
    DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE AS snapshot_date
  FROM public.practice_sessions ps
  WHERE ps.cleaned_duration > 0
    AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
)
SELECT COUNT(*) AS phantom_nonzero_snapshot_violations
FROM public.student_score_history history
LEFT JOIN active_snapshot_weeks active_week
  ON active_week.student_name = history.student_name
 AND active_week.snapshot_date = history.snapshot_date
WHERE history.composite_score > 0
  AND active_week.student_name IS NULL;

SELECT
  expected.snapshot_date,
  COALESCE(history.composite_score, 0) AS composite_score,
  COALESCE(history.raw_score, 0) AS raw_score,
  CASE
    WHEN COALESCE(history.composite_score, 0) = 0
     AND COALESCE(history.raw_score, 0) = 0
      THEN 'PASS'
    ELSE 'FAIL'
  END AS result
FROM (
  VALUES (DATE '2026-08-10'), (DATE '2026-08-17'), (DATE '2026-08-24')
) expected(snapshot_date)
LEFT JOIN public.student_score_history history
  ON history.student_name = '于小荷'
 AND history.snapshot_date = expected.snapshot_date
ORDER BY expected.snapshot_date;

WITH context AS (
  SELECT
    DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS monday,
    NOW() AS cutoff_at
),
leaderboard_students AS (
  SELECT DISTINCT leaderboard.student_name
  FROM public.get_weekly_leaderboards() leaderboard
),
invalid AS (
  SELECT leaderboard_student.student_name
  FROM leaderboard_students leaderboard_student
  CROSS JOIN context current_week
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.practice_sessions ps
    WHERE ps.student_name = leaderboard_student.student_name
      AND ps.cleaned_duration > 0
      AND ps.session_start >= GREATEST(
        (current_week.monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai',
        COALESCE(
          public.get_student_score_period_start_at(
            leaderboard_student.student_name,
            current_week.cutoff_at
          ),
          (current_week.monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai'
        )
      )
      AND ps.session_start < current_week.cutoff_at
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  )
)
SELECT COUNT(*) AS leaderboard_without_current_period_session_violations
FROM invalid;

WITH context AS (
  SELECT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS monday
),
current_restart AS (
  SELECT
    sb.student_name,
    public.get_student_score_period_start(sb.student_name, context.monday) AS period_start
  FROM public.student_baseline sb
  CROSS JOIN context
),
invalid AS (
  SELECT restart.student_name
  FROM current_restart restart
  CROSS JOIN context
  WHERE restart.period_start >= ((context.monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
    AND EXISTS (
      SELECT 1
      FROM public.student_score_history history
      WHERE history.student_name = restart.student_name
        AND history.snapshot_date < context.monday
        AND history.snapshot_date >= DATE_TRUNC(
          'week',
          restart.period_start AT TIME ZONE 'Asia/Shanghai'
        )::DATE
        AND history.composite_score > 0
    )
)
SELECT COUNT(*) AS restart_inherited_prior_score_violations
FROM invalid;

SELECT
  CASE
    WHEN POSITION(
      'v_days_inactive > 30'
      IN pg_get_functiondef('public.compute_student_score(text)'::REGPROCEDURE)
    ) = 0
      THEN 'PASS'
    ELSE 'FAIL'
  END AS realtime_freeze_branch_removed,
  CASE
    WHEN POSITION(
      'v_days_inactive > 30'
      IN pg_get_functiondef('public.compute_student_score_as_of(text,date)'::REGPROCEDURE)
    ) = 0
      THEN 'PASS'
    ELSE 'FAIL'
  END AS historical_freeze_branch_removed,
  CASE
    WHEN pg_get_functiondef(
      'public.compute_student_score_rule_v2_core(text,date)'::REGPROCEDURE
    ) ILIKE '%v_period_start%'
      THEN 'PASS'
    ELSE 'FAIL'
  END AS score_period_filter_present;
