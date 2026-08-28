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
    COALESCE(p_week_monday, DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE) AS monday
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
    COALESCE(wu.week_session_count, 0)::INTEGER AS week_session_count
  FROM current_students cs
  CROSS JOIN week_context wc
  CROSS JOIN LATERAL public.get_rule_v2_week_target_context(
    cs.student_name,
    wc.monday
  ) ctx
  LEFT JOIN week_usage wu
    ON wu.student_name = cs.student_name
  WHERE COALESCE(ctx.final_target_week, 0) > 0
),
eligible AS (
  SELECT
    ts.*,
    ROUND((ts.completed_minutes / NULLIF(ts.target_minutes, 0))::NUMERIC, 4) AS completion_ratio,
    ROUND(GREATEST(ts.target_minutes - ts.completed_minutes, 0)::NUMERIC, 2) AS shortfall_minutes
  FROM targeted_students ts
),
ranked AS (
  SELECT
    ROW_NUMBER() OVER (
      ORDER BY completion_ratio ASC,
               shortfall_minutes DESC,
               completed_minutes ASC,
               student_name ASC
    )::INTEGER AS rank_no,
    e.*
  FROM eligible e
  WHERE e.completion_ratio < 0.70
)
SELECT
  '退步榜'::TEXT AS board,
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
  r.shortfall_minutes,
  r.week_session_count
FROM ranked r
ORDER BY r.rank_no;
$function$;

REVOKE ALL ON FUNCTION public.get_weekly_decline_leaderboard(DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_weekly_decline_leaderboard(DATE) TO anon, authenticated;

CREATE TABLE IF NOT EXISTS public.weekly_leaderboard_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  backup_date DATE NOT NULL DEFAULT CURRENT_DATE,
  week_monday DATE NOT NULL,
  board TEXT NOT NULL,
  rank_no INTEGER NOT NULL,
  student_name TEXT NOT NULL,
  student_major TEXT,
  student_grade TEXT,
  display_score NUMERIC,
  alpha NUMERIC,
  trend_score NUMERIC,
  mean_duration NUMERIC,
  record_count INTEGER,
  recent10_outlier_rate NUMERIC,
  recent10_mean_dur NUMERIC,
  recent10_count INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.weekly_leaderboard_history
  ADD COLUMN IF NOT EXISTS target_minutes NUMERIC,
  ADD COLUMN IF NOT EXISTS completed_minutes NUMERIC,
  ADD COLUMN IF NOT EXISTS completion_ratio NUMERIC,
  ADD COLUMN IF NOT EXISTS shortfall_minutes NUMERIC,
  ADD COLUMN IF NOT EXISTS week_session_count INTEGER;

CREATE OR REPLACE FUNCTION public.backup_weekly_leaderboards()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_monday DATE := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
BEGIN
  DELETE FROM public.weekly_leaderboard_history
  WHERE week_monday = v_monday;

  INSERT INTO public.weekly_leaderboard_history (
    week_monday,
    backup_date,
    board,
    rank_no,
    student_name,
    student_major,
    student_grade,
    display_score,
    alpha,
    trend_score,
    mean_duration,
    record_count,
    recent10_outlier_rate,
    recent10_mean_dur,
    recent10_count,
    target_minutes,
    completed_minutes,
    completion_ratio,
    shortfall_minutes,
    week_session_count
  )
  SELECT
    v_monday,
    (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE,
    lb.board,
    lb.rank_no,
    lb.student_name,
    lb.student_major,
    lb.student_grade,
    lb.display_score,
    lb.alpha,
    lb.trend_score,
    lb.mean_duration,
    lb.record_count,
    lb.recent10_outlier_rate,
    lb.recent10_mean_dur,
    lb.recent10_count,
    NULL::NUMERIC,
    NULL::NUMERIC,
    NULL::NUMERIC,
    NULL::NUMERIC,
    NULL::INTEGER
  FROM public.get_weekly_leaderboards() lb

  UNION ALL

  SELECT
    v_monday,
    (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE,
    decline.board,
    decline.rank_no,
    decline.student_name,
    decline.student_major,
    decline.student_grade,
    decline.display_score,
    decline.alpha,
    decline.trend_score,
    decline.mean_duration,
    decline.record_count,
    decline.recent10_outlier_rate,
    decline.recent10_mean_dur,
    decline.recent10_count,
    decline.target_minutes,
    decline.completed_minutes,
    decline.completion_ratio,
    decline.shortfall_minutes,
    decline.week_session_count
  FROM public.get_weekly_decline_leaderboard(v_monday) decline;
END;
$function$;

NOTIFY pgrst, 'reload schema';

COMMIT;
