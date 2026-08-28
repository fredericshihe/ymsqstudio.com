BEGIN;

CREATE OR REPLACE FUNCTION public.get_weekly_decline_leaderboard(
  p_week_monday DATE DEFAULT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
)
RETURNS TABLE (
  board                  TEXT,
  rank_no                INTEGER,
  student_name           TEXT,
  student_major          TEXT,
  student_grade          TEXT,
  display_score          NUMERIC,
  alpha                  NUMERIC,
  trend_score            NUMERIC,
  mean_duration          NUMERIC,
  record_count           INTEGER,
  recent10_outlier_rate  NUMERIC,
  recent10_mean_dur      NUMERIC,
  recent10_count         INTEGER,
  target_minutes         NUMERIC,
  completed_minutes      NUMERIC,
  completion_ratio       NUMERIC,
  shortfall_minutes      NUMERIC,
  week_session_count     INTEGER
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
WITH week_context AS (
  SELECT
    COALESCE(p_week_monday, DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE) AS monday,
    (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS today,
    CASE
      WHEN (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE < COALESCE(p_week_monday, DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE)
        THEN 0
      WHEN (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE >= COALESCE(p_week_monday, DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE) + 5
        THEN 5
      ELSE EXTRACT(DOW FROM (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE)::INTEGER
    END AS elapsed_workdays
),
current_students AS (
  SELECT DISTINCT ON (sd.name)
    sb.student_name,
    COALESCE(NULLIF(BTRIM(sd.major), ''), sb.student_major) AS student_major,
    COALESCE(NULLIF(BTRIM(sd.grade), ''), sb.student_grade) AS student_grade,
    sb.alpha,
    sb.mean_duration,
    sb.record_count
  FROM public.student_database sd
  JOIN public.student_baseline sb
    ON sb.student_name = sd.name
  WHERE COALESCE(sd.archived, FALSE) IS FALSE
    AND NULLIF(BTRIM(sd.name), '') IS NOT NULL
  ORDER BY sd.name, sd.updated_at DESC NULLS LAST, sd.id DESC
),
week_usage AS (
  SELECT
    ps.student_name,
    ROUND(SUM(ps.cleaned_duration)::NUMERIC, 2) AS completed_minutes,
    COUNT(*)::INTEGER AS week_session_count
  FROM public.practice_sessions ps
  CROSS JOIN week_context wc
  WHERE ps.cleaned_duration > 0
    AND ps.session_start >= ((wc.monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
    AND ps.session_start < (((wc.monday + 7)::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
    AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  GROUP BY ps.student_name
),
targeted_students AS (
  SELECT
    cs.student_name,
    cs.student_major,
    cs.student_grade,
    cs.alpha,
    cs.mean_duration,
    cs.record_count,
    ROUND(ctx.final_target_week::NUMERIC, 2) AS target_minutes,
    COALESCE(wu.completed_minutes, 0)::NUMERIC AS completed_minutes,
    COALESCE(wu.week_session_count, 0)::INTEGER AS week_session_count,
    wc.elapsed_workdays
  FROM current_students cs
  CROSS JOIN week_context wc
  CROSS JOIN LATERAL public.get_rule_v2_week_target_context(
    cs.student_name,
    wc.monday
  ) ctx
  LEFT JOIN week_usage wu
    ON wu.student_name = cs.student_name
),
eligible AS (
  SELECT
    ts.*,
    ROUND((ts.target_minutes * ts.elapsed_workdays / 5.0)::NUMERIC, 2) AS expected_minutes,
    ROUND((
      ts.completed_minutes
      / NULLIF(ts.target_minutes * ts.elapsed_workdays / 5.0, 0)
    )::NUMERIC, 4) AS completion_ratio
  FROM targeted_students ts
  WHERE ts.week_session_count > 0
    AND ts.elapsed_workdays > 0
),
ranked AS (
  SELECT
    ROW_NUMBER() OVER (
      ORDER BY completion_ratio ASC,
               GREATEST(expected_minutes - completed_minutes, 0) DESC,
               completed_minutes ASC,
               student_name ASC
    )::INTEGER AS rank_no,
    e.*
  FROM eligible e
  WHERE e.completion_ratio < 0.70
)
SELECT
  '缩水榜'::TEXT AS board,
  r.rank_no,
  r.student_name,
  r.student_major,
  r.student_grade,
  ROUND((r.completion_ratio * 100)::NUMERIC, 1) AS display_score,
  r.alpha,
  NULL::NUMERIC AS trend_score,
  r.mean_duration,
  r.record_count::INTEGER,
  NULL::NUMERIC AS recent10_outlier_rate,
  NULL::NUMERIC AS recent10_mean_dur,
  NULL::INTEGER AS recent10_count,
  r.target_minutes,
  r.completed_minutes,
  r.completion_ratio,
  ROUND(GREATEST(r.expected_minutes - r.completed_minutes, 0)::NUMERIC, 2) AS shortfall_minutes,
  r.week_session_count
FROM ranked r
ORDER BY r.rank_no;
$function$;

CREATE OR REPLACE FUNCTION public.get_weekly_shrink_summary()
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
WITH context AS (
  SELECT
    DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS monday,
    CASE EXTRACT(DOW FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INTEGER
      WHEN 0 THEN 5
      WHEN 6 THEN 5
      ELSE EXTRACT(DOW FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INTEGER
    END AS elapsed_workdays
),
active_students AS (
  SELECT COUNT(DISTINCT sd.name)::INTEGER AS total_students
  FROM public.student_database sd
  WHERE COALESCE(sd.archived, FALSE) IS FALSE
    AND NULLIF(BTRIM(sd.name), '') IS NOT NULL
),
started_students AS (
  SELECT COUNT(DISTINCT ps.student_name)::INTEGER AS started_students
  FROM public.practice_sessions ps
  JOIN public.student_database sd
    ON sd.name = ps.student_name
  CROSS JOIN context c
  WHERE COALESCE(sd.archived, FALSE) IS FALSE
    AND ps.cleaned_duration > 0
    AND ps.session_start >= ((c.monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
    AND ps.session_start < (((c.monday + 7)::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
    AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
)
SELECT jsonb_build_object(
  'week_monday', c.monday,
  'elapsed_workdays', c.elapsed_workdays,
  'total_students', COALESCE(a.total_students, 0),
  'started_students', COALESCE(s.started_students, 0),
  'not_started_students', GREATEST(COALESCE(a.total_students, 0) - COALESCE(s.started_students, 0), 0),
  'shrink_students', (
    SELECT COUNT(*)::INTEGER
    FROM public.get_weekly_decline_leaderboard(c.monday)
  )
)
FROM context c
CROSS JOIN active_students a
CROSS JOIN started_students s;
$function$;

REVOKE ALL ON FUNCTION public.get_weekly_decline_leaderboard(DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_weekly_decline_leaderboard(DATE) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.get_weekly_shrink_summary() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_weekly_shrink_summary() TO anon, authenticated;

UPDATE public.weekly_leaderboard_history
SET board = '缩水榜'
WHERE board = '退步榜';

NOTIFY pgrst, 'reload schema';

COMMIT;
