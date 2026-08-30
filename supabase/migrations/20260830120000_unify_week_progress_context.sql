BEGIN;

CREATE OR REPLACE FUNCTION public.get_student_week_progress_context(
  p_student_name TEXT,
  p_week_monday  DATE DEFAULT NULL,
  p_as_of_date   DATE DEFAULT NULL
)
RETURNS TABLE (
  week_monday                         DATE,
  as_of_date                          DATE,
  is_workday                          BOOLEAN,
  elapsed_workdays                    INTEGER,
  remaining_workdays                  INTEGER,
  week_target_minutes                 NUMERIC,
  settled_week_minutes                NUMERIC,
  settled_before_today_minutes        NUMERIC,
  settled_today_minutes               NUMERIC,
  settled_session_count               INTEGER,
  expected_to_date_minutes            NUMERIC,
  today_target_minutes                NUMERIC,
  remaining_week_minutes              NUMERIC,
  shortfall_to_pace_minutes           NUMERIC,
  week_completion_ratio               NUMERIC,
  pace_completion_ratio               NUMERIC
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
WITH params AS (
  SELECT
    COALESCE(p_as_of_date, (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE) AS reference_date
),
calendar AS (
  SELECT
    COALESCE(
      p_week_monday,
      DATE_TRUNC('week', p.reference_date::TIMESTAMP)::DATE
    ) AS monday,
    p.reference_date,
    (
      p.reference_date >= COALESCE(p_week_monday, DATE_TRUNC('week', p.reference_date::TIMESTAMP)::DATE)
      AND p.reference_date < COALESCE(p_week_monday, DATE_TRUNC('week', p.reference_date::TIMESTAMP)::DATE) + 5
    ) AS workday,
    LEAST(
      5,
      GREATEST(
        0,
        p.reference_date - COALESCE(p_week_monday, DATE_TRUNC('week', p.reference_date::TIMESTAMP)::DATE) + 1
      )
    )::INTEGER AS elapsed_days,
    CASE
      WHEN p.reference_date >= COALESCE(p_week_monday, DATE_TRUNC('week', p.reference_date::TIMESTAMP)::DATE)
       AND p.reference_date < COALESCE(p_week_monday, DATE_TRUNC('week', p.reference_date::TIMESTAMP)::DATE) + 5
        THEN (
          5 - (
            p.reference_date
            - COALESCE(p_week_monday, DATE_TRUNC('week', p.reference_date::TIMESTAMP)::DATE)
          )
        )::INTEGER
      ELSE 0
    END AS remaining_days
  FROM params p
),
target AS (
  SELECT
    c.*,
    ctx.final_target_week::NUMERIC AS target_minutes
  FROM calendar c
  CROSS JOIN LATERAL public.get_rule_v2_week_target_context(
    p_student_name,
    c.monday
  ) ctx
),
usage AS (
  SELECT
    t.monday,
    t.reference_date,
    t.workday,
    t.elapsed_days,
    t.remaining_days,
    t.target_minutes,
    COALESCE(SUM(ps.cleaned_duration), 0)::NUMERIC AS week_minutes,
    COALESCE(SUM(ps.cleaned_duration) FILTER (
      WHERE ps.session_start < ((t.reference_date::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
    ), 0)::NUMERIC AS before_today_minutes,
    COALESCE(SUM(ps.cleaned_duration) FILTER (
      WHERE ps.session_start >= ((t.reference_date::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
        AND ps.session_start < (((t.reference_date + 1)::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
    ), 0)::NUMERIC AS today_minutes,
    COUNT(ps.*)::INTEGER AS session_count
  FROM target t
  LEFT JOIN public.practice_sessions ps
    ON ps.student_name = p_student_name
   AND ps.cleaned_duration > 0
   AND ps.session_start >= ((t.monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
   AND ps.session_start < ((LEAST(t.monday + 7, t.reference_date + 1)::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
   AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  GROUP BY
    t.monday,
    t.reference_date,
    t.workday,
    t.elapsed_days,
    t.remaining_days,
    t.target_minutes
),
metrics AS (
  SELECT
    u.*,
    (u.target_minutes * u.elapsed_days / 5.0)::NUMERIC AS expected_minutes
  FROM usage u
)
SELECT
  m.monday,
  m.reference_date,
  m.workday,
  m.elapsed_days,
  m.remaining_days,
  ROUND(m.target_minutes, 2),
  ROUND(m.week_minutes, 2),
  ROUND(m.before_today_minutes, 2),
  ROUND(m.today_minutes, 2),
  m.session_count,
  ROUND(m.expected_minutes, 2),
  ROUND(
    CASE
      WHEN m.workday THEN GREATEST(m.expected_minutes - m.before_today_minutes, 0)
      ELSE 0
    END,
    2
  ),
  ROUND(GREATEST(m.target_minutes - m.week_minutes, 0), 2),
  ROUND(GREATEST(m.expected_minutes - m.week_minutes, 0), 2),
  ROUND((m.week_minutes / NULLIF(m.target_minutes, 0))::NUMERIC, 4),
  ROUND((m.week_minutes / NULLIF(m.expected_minutes, 0))::NUMERIC, 4)
FROM metrics m;
$function$;

REVOKE ALL ON FUNCTION public.get_student_week_progress_context(TEXT, DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_student_week_progress_context(TEXT, DATE, DATE) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.compute_and_store_w_score(p_student_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  progress     RECORD;
  v_completion FLOAT8 := 0.0;
  v_w_score    FLOAT8 := 0.0;
BEGIN
  SELECT * INTO progress
  FROM public.get_student_week_progress_context(p_student_name, NULL, NULL);

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_completion := COALESCE(progress.pace_completion_ratio, 0.0);
  v_w_score := CASE
    WHEN v_completion <= 0.0 THEN 0.0
    WHEN v_completion < 0.50 THEN 0.20 + 0.50 * (v_completion / 0.50)
    WHEN v_completion < 1.00 THEN 0.70 + 0.20 * ((v_completion - 0.50) / 0.50)
    WHEN v_completion < 1.10 THEN 0.90 + 0.05 * ((v_completion - 1.00) / 0.10)
    ELSE 0.95
  END;
  v_w_score := GREATEST(0.0, LEAST(0.95, v_w_score));

  PERFORM set_config('app.skip_score_trigger', 'on', true);
  UPDATE public.student_baseline
  SET
    w_score = v_w_score,
    w_score_updated_at = NOW()
  WHERE student_name = p_student_name;
  PERFORM set_config('app.skip_score_trigger', 'off', true);
END;
$function$;

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
WITH current_students AS (
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
eligible AS (
  SELECT
    cs.*,
    progress.week_target_minutes AS target_minutes,
    progress.settled_week_minutes AS completed_minutes,
    progress.pace_completion_ratio AS completion_ratio,
    progress.expected_to_date_minutes AS expected_minutes,
    progress.shortfall_to_pace_minutes AS shortfall_minutes,
    progress.settled_session_count AS week_session_count
  FROM current_students cs
  CROSS JOIN LATERAL public.get_student_week_progress_context(
    cs.student_name,
    p_week_monday,
    NULL
  ) progress
  WHERE progress.settled_session_count > 0
    AND progress.elapsed_workdays > 0
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
  '缩水榜'::TEXT,
  r.rank_no,
  r.student_name,
  r.student_major,
  r.student_grade,
  ROUND((r.completion_ratio * 100)::NUMERIC, 1),
  r.alpha,
  NULL::NUMERIC,
  r.mean_duration,
  r.record_count::INTEGER,
  NULL::NUMERIC,
  NULL::NUMERIC,
  NULL::INTEGER,
  ROUND(r.target_minutes, 2),
  ROUND(r.completed_minutes, 2),
  ROUND(r.completion_ratio, 4),
  ROUND(r.shortfall_minutes, 2),
  r.week_session_count
FROM ranked r
ORDER BY r.rank_no;
$function$;

REVOKE ALL ON FUNCTION public.get_weekly_decline_leaderboard(DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_weekly_decline_leaderboard(DATE) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
