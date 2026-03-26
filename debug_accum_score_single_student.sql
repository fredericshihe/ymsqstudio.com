-- ============================================================================
-- 单学生 A 底盘分（accum_score）诊断脚本
-- 目标：解释为什么某学生 A 分为 0（或很低）
-- 口径对齐：fix44_46_score_functions.sql 当前实时计算逻辑
-- ============================================================================

WITH params AS (
  SELECT '梁书一'::TEXT AS p_student_name
),
r AS (
  SELECT sb.*
  FROM public.student_baseline sb
  JOIN params p ON p.p_student_name = sb.student_name
),
major_cnt AS (
  SELECT COUNT(*)::INT AS cnt
  FROM public.student_baseline sb
  JOIN r ON TRUE
  WHERE sb.student_major = r.student_major
    AND sb.mean_duration > 0
),
peer_stats AS (
  SELECT
    CASE
      WHEN mc.cnt >= 5 THEN (
        SELECT PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY sb.mean_duration)
        FROM public.student_baseline sb
        JOIN r ON TRUE
        WHERE sb.mean_duration IS NOT NULL
          AND sb.mean_duration > 0
          AND sb.student_major = r.student_major
      )
      ELSE (
        SELECT PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY sb.mean_duration)
        FROM public.student_baseline sb
        WHERE sb.mean_duration IS NOT NULL
          AND sb.mean_duration > 0
      )
    END AS median_mean,
    CASE
      WHEN mc.cnt >= 5 THEN (
        SELECT PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY sb.mean_duration)
        FROM public.student_baseline sb
        JOIN r ON TRUE
        WHERE sb.mean_duration IS NOT NULL
          AND sb.mean_duration > 0
          AND sb.student_major = r.student_major
      )
      ELSE (
        SELECT PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY sb.mean_duration)
        FROM public.student_baseline sb
        WHERE sb.mean_duration IS NOT NULL
          AND sb.mean_duration > 0
      )
    END AS p25_mean,
    CASE
      WHEN mc.cnt >= 5 THEN (
        SELECT PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY sb.mean_duration)
        FROM public.student_baseline sb
        JOIN r ON TRUE
        WHERE sb.mean_duration IS NOT NULL
          AND sb.mean_duration > 0
          AND sb.student_major = r.student_major
      )
      ELSE (
        SELECT PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY sb.mean_duration)
        FROM public.student_baseline sb
        WHERE sb.mean_duration IS NOT NULL
          AND sb.mean_duration > 0
      )
    END AS p75_mean,
    mc.cnt AS major_count
  FROM major_cnt mc
),
calc AS (
  SELECT
    r.student_name,
    r.student_major,
    r.record_count,
    r.mean_duration,
    r.accum_score AS baseline_accum_score,
    ps.major_count,
    ps.median_mean,
    ps.p25_mean,
    ps.p75_mean,
    GREATEST(COALESCE(ps.p75_mean, 0) - COALESCE(ps.p25_mean, 0), 1.0)::FLOAT8 AS pop_iqr,
    LEAST(1.0, COALESCE(r.record_count, 0)::FLOAT8 / 15.0)::FLOAT8 AS shrink_alpha
  FROM r
  CROSS JOIN peer_stats ps
),
calc2 AS (
  SELECT
    c.*,
    GREATEST(
      c.shrink_alpha * COALESCE(c.mean_duration, 0.0)
      + (1.0 - c.shrink_alpha) * COALESCE(c.median_mean, 30.0),
      15.0
    )::FLOAT8 AS v_effective_mean
  FROM calc c
),
calc3 AS (
  SELECT
    c2.*,
    GREATEST(
      0.0,
      LEAST(
        1.0,
        0.5 + (c2.v_effective_mean - COALESCE(c2.median_mean, 0.0)) / (2.0 * c2.pop_iqr)
      )
    )::FLOAT8 AS quality_score
  FROM calc2 c2
)
SELECT
  student_name,
  student_major,
  record_count,
  mean_duration,
  baseline_accum_score,
  major_count,
  median_mean,
  p25_mean,
  p75_mean,
  pop_iqr,
  shrink_alpha,
  v_effective_mean,
  quality_score,
  (GREATEST(COALESCE(record_count, 0), 0)::FLOAT8 * quality_score)::FLOAT8 AS accum_raw,
  LEAST(
    1.0,
    LN((GREATEST(COALESCE(record_count, 0), 0)::FLOAT8 * quality_score) + 1.0) / LN(31.0)
  )::FLOAT8 AS recomputed_a_score,
  CASE
    WHEN COALESCE(record_count, 0) = 0 THEN 'A=0 原因：record_count=0'
    WHEN quality_score <= 0.0001 THEN 'A≈0 原因：quality_score≈0（均时显著低于群体中位）'
    ELSE 'A 由 record_count 与 quality_score 共同决定'
  END AS diagnosis
FROM calc3;

