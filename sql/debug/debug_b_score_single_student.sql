-- ============================================================================
-- 单学生 B 进步分诊断脚本（对齐 compute_student_score 当前口径）
-- 目标：解释“为什么 B 分高/低”
-- ============================================================================

WITH params AS (
  SELECT '梁书一'::TEXT AS p_student_name
),
week_anchor AS (
  SELECT
    DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS week_monday
),
base AS (
  SELECT sb.*
  FROM public.student_baseline sb
  JOIN params p ON p.p_student_name = sb.student_name
),
major_stats AS (
  SELECT
    COUNT(*) FILTER (WHERE sb.student_major = b.student_major AND sb.mean_duration > 0) AS major_cnt,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY sb.mean_duration)
      FILTER (WHERE sb.student_major = b.student_major AND sb.mean_duration > 0) AS major_median,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY sb.mean_duration)
      FILTER (WHERE sb.mean_duration > 0) AS global_median
  FROM public.student_baseline sb
  CROSS JOIN base b
),
peer AS (
  SELECT
    CASE
      WHEN ms.major_cnt >= 5 THEN COALESCE(ms.major_median, 30.0)
      ELSE COALESCE(ms.global_median, 30.0)
    END::FLOAT8 AS median_mean
  FROM major_stats ms
),
active_weeks AS (
  SELECT
    DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE AS week_start,
    SUM(ps.cleaned_duration)::FLOAT8 AS weekly_mins
  FROM public.practice_sessions ps
  JOIN params p ON p.p_student_name = ps.student_name
  CROSS JOIN week_anchor wa
  WHERE ps.cleaned_duration > 0
    AND ps.session_start < (wa.week_monday::TIMESTAMP AT TIME ZONE 'Asia/Shanghai')
    AND ps.session_start >= (wa.week_monday::TIMESTAMP AT TIME ZONE 'Asia/Shanghai') - INTERVAL '8 weeks'
    AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  GROUP BY 1
),
ranked AS (
  SELECT
    week_start,
    weekly_mins,
    DENSE_RANK() OVER (ORDER BY week_start DESC) AS rn
  FROM active_weeks
),
w AS (
  SELECT
    MAX(CASE WHEN rn = 1 THEN weekly_mins END) AS week1_mins,
    MAX(CASE WHEN rn = 2 THEN weekly_mins END) AS week2_mins,
    MAX(CASE WHEN rn = 1 THEN week_start END) AS week1_start,
    MAX(CASE WHEN rn = 2 THEN week_start END) AS week2_start,
    COUNT(*)::INT AS active_week_cnt
  FROM ranked
),
calc AS (
  SELECT
    b.student_name,
    b.baseline_score AS baseline_b_score,
    b.record_count,
    b.mean_duration,
    p.median_mean,
    (p.median_mean * 5.0)::FLOAT8 AS peer_median_weekly,
    LEAST(1.0, COALESCE(b.record_count, 0)::FLOAT8 / 15.0)::FLOAT8 AS shrink_alpha,
    w.week1_mins,
    w.week2_mins,
    w.week1_start,
    w.week2_start,
    w.active_week_cnt
  FROM base b
  CROSS JOIN peer p
  CROSS JOIN w
),
calc2 AS (
  SELECT
    c.*,
    GREATEST(
      c.shrink_alpha * COALESCE(c.mean_duration, 0.0)
      + (1.0 - c.shrink_alpha) * COALESCE(c.median_mean, 30.0),
      15.0
    )::FLOAT8 AS effective_mean
  FROM calc c
),
calc3 AS (
  SELECT
    c2.*,
    CASE
      WHEN COALESCE(c2.week1_mins, 0) > 0 THEN
        1.0 / (1.0 + EXP(
          -3.0 * (c2.week1_mins - c2.peer_median_weekly)
          / GREATEST(c2.peer_median_weekly, 150.0)
        ))
      ELSE 0.5
    END::FLOAT8 AS b_level,
    CASE
      WHEN COALESCE(c2.week1_mins, 0) > 0 AND COALESCE(c2.week2_mins, 0) > 0 THEN
        1.0 / (1.0 + EXP(
          -3.0 * (c2.week1_mins - c2.week2_mins)
          / GREATEST(c2.effective_mean * 5.0, 150.0)
        ))
      ELSE 0.5
    END::FLOAT8 AS b_change_raw
  FROM calc2 c2
),
calc4 AS (
  SELECT
    c3.*,
    CASE
      WHEN c3.week1_start IS NOT NULL AND c3.week2_start IS NOT NULL
        AND ((c3.week1_start - c3.week2_start)::FLOAT8 / 7.0) > 3.0
      THEN LEAST(0.70, (((c3.week1_start - c3.week2_start)::FLOAT8 / 7.0) - 3.0) * 0.15)
      ELSE 0.0
    END::FLOAT8 AS neutralize_ratio
  FROM calc3 c3
)
SELECT
  student_name,
  record_count,
  mean_duration,
  active_week_cnt,
  week1_start,
  week1_mins,
  week2_start,
  week2_mins,
  median_mean,
  peer_median_weekly,
  effective_mean,
  b_level,
  b_change_raw,
  neutralize_ratio,
  (b_change_raw * (1.0 - neutralize_ratio) + 0.5 * neutralize_ratio)::FLOAT8 AS b_change_after_neutralize,
  (0.80 * (b_change_raw * (1.0 - neutralize_ratio) + 0.5 * neutralize_ratio) + 0.20 * b_level)::FLOAT8 AS recomputed_b_score,
  baseline_b_score
FROM calc4;

