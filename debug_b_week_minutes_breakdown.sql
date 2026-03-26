-- ============================================================================
-- 核对 B 维度周分钟构成：确认是否误把周末算入
-- 默认学生：梁书一
-- ============================================================================

WITH params AS (
  SELECT
    '梁书一'::TEXT AS p_student_name,
    DATE '2026-03-16' AS p_week_start -- 需要核对的周一（北京时间）
),
rows_in_week AS (
  SELECT
    ps.student_name,
    ps.session_start,
    ps.cleaned_duration,
    (ps.session_start AT TIME ZONE 'Asia/Shanghai') AS session_start_bjt,
    DATE(ps.session_start AT TIME ZONE 'Asia/Shanghai') AS local_date,
    EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai')::INT AS local_dow,
    CASE
      WHEN EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') IN (0, 6) THEN 'weekend'
      ELSE 'workday'
    END AS day_type
  FROM public.practice_sessions ps
  JOIN params p ON p.p_student_name = ps.student_name
  WHERE ps.cleaned_duration > 0
    AND ps.session_start >= (p.p_week_start::TIMESTAMP AT TIME ZONE 'Asia/Shanghai')
    AND ps.session_start <  ((p.p_week_start + INTERVAL '7 day')::TIMESTAMP AT TIME ZONE 'Asia/Shanghai')
)
SELECT
  student_name,
  session_start,
  session_start_bjt,
  local_date,
  local_dow,
  day_type,
  cleaned_duration
FROM rows_in_week
ORDER BY session_start_bjt;

-- 汇总核对（同一周）
WITH params AS (
  SELECT
    '梁书一'::TEXT AS p_student_name,
    DATE '2026-03-16' AS p_week_start
),
rows_in_week AS (
  SELECT
    ps.cleaned_duration AS dur,
    EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai')::INT AS local_dow
  FROM public.practice_sessions ps
  JOIN params p ON p.p_student_name = ps.student_name
  WHERE ps.cleaned_duration > 0
    AND ps.session_start >= (p.p_week_start::TIMESTAMP AT TIME ZONE 'Asia/Shanghai')
    AND ps.session_start <  ((p.p_week_start + INTERVAL '7 day')::TIMESTAMP AT TIME ZONE 'Asia/Shanghai')
)
SELECT
  COALESCE(SUM(dur), 0)::FLOAT8 AS mins_all_days,
  COALESCE(SUM(dur) FILTER (WHERE local_dow NOT IN (0, 6)), 0)::FLOAT8 AS mins_workdays_only,
  COALESCE(SUM(dur) FILTER (WHERE local_dow IN (0, 6)), 0)::FLOAT8 AS mins_weekend_only
FROM rows_in_week;

