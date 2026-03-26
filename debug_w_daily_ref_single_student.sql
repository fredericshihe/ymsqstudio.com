-- ============================================================================
-- 单学生 W 日均基准诊断脚本（FIX-81）
-- 用法：
-- 1) 把 p_student_name 改成目标学生
-- 2) 执行后查看每一步中间量，定位“为什么基准低/高”
-- ============================================================================

WITH params AS (
  SELECT '冼昊熹'::TEXT AS p_student_name
),
major_info AS (
  SELECT sb.student_name, sb.student_major
  FROM public.student_baseline sb
  JOIN params p ON p.p_student_name = sb.student_name
),
daily AS (
  SELECT
    DATE(ps.session_start AT TIME ZONE 'Asia/Shanghai') AS d,
    SUM(ps.cleaned_duration)::FLOAT8 AS day_mins
  FROM public.practice_sessions ps
  JOIN params p ON p.p_student_name = ps.student_name
  WHERE ps.cleaned_duration > 0
    AND ps.session_start >= NOW() - INTERVAL '12 weeks'
    AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  GROUP BY DATE(ps.session_start AT TIME ZONE 'Asia/Shanghai')
),
personal_stats AS (
  SELECT
    COUNT(*)::INT AS n_days,
    COALESCE(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY day_mins), 0)::FLOAT8 AS d50,
    COALESCE(PERCENTILE_CONT(0.70) WITHIN GROUP (ORDER BY day_mins), 0)::FLOAT8 AS d70,
    COALESCE(AVG(day_mins), 0)::FLOAT8 AS d_avg,
    COALESCE(STDDEV_POP(day_mins), 0)::FLOAT8 AS d_std
  FROM daily
),
active_weeks AS (
  SELECT COALESCE(COUNT(DISTINCT DATE_TRUNC('week', d))::FLOAT8, 0) AS wk_cnt
  FROM daily
),
personal_ref_calc AS (
  SELECT
    ps.n_days,
    ps.d50,
    ps.d70,
    ps.d_avg,
    ps.d_std,
    CASE WHEN ps.d_avg > 0 THEN ps.d_std / ps.d_avg ELSE 0 END::FLOAT8 AS cv,
    CASE WHEN aw.wk_cnt > 0 THEN ps.n_days / aw.wk_cnt ELSE 0 END::FLOAT8 AS active_days_per_wk,
    (0.50 * ps.d50 + 0.30 * ps.d70 + 0.20 * ps.d_avg)::FLOAT8 AS personal_ref_raw
  FROM personal_stats ps
  CROSS JOIN active_weeks aw
),
adjusted_personal AS (
  SELECT
    prc.n_days,
    prc.cv,
    prc.active_days_per_wk,
    prc.personal_ref_raw,
    GREATEST(0.85, LEAST(1.10, 0.85 + 0.25 * LEAST(prc.active_days_per_wk / 5.0, 1.0)))::FLOAT8 AS freq_factor,
    GREATEST(0.85, LEAST(1.05, 1.10 - 0.25 * prc.cv))::FLOAT8 AS stability_factor
  FROM personal_ref_calc prc
),
peer_daily AS (
  SELECT
    ps.student_name,
    DATE(ps.session_start AT TIME ZONE 'Asia/Shanghai') AS d,
    SUM(ps.cleaned_duration)::FLOAT8 AS day_mins
  FROM public.practice_sessions ps
  JOIN public.student_baseline sb ON sb.student_name = ps.student_name
  JOIN major_info mi ON TRUE
  WHERE ps.cleaned_duration > 0
    AND ps.session_start >= NOW() - INTERVAL '12 weeks'
    AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    AND (
      (mi.student_major IS NOT NULL AND sb.student_major = mi.student_major)
      OR (mi.student_major IS NULL)
    )
  GROUP BY ps.student_name, DATE(ps.session_start AT TIME ZONE 'Asia/Shanghai')
),
peer_ref_calc AS (
  SELECT COALESCE(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY day_mins), 60)::FLOAT8 AS peer_daily_median
  FROM peer_daily
),
recent4 AS (
  SELECT
    COALESCE(SUM(ps.cleaned_duration), 0)::FLOAT8 AS mins_4w,
    GREATEST(
      1.0,
      (
        COUNT(DISTINCT DATE(ps.session_start AT TIME ZONE 'Asia/Shanghai')) FILTER (
          WHERE EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
        )
      )::FLOAT8
    ) AS active_days_4w
  FROM public.practice_sessions ps
  JOIN params p ON p.p_student_name = ps.student_name
  WHERE ps.cleaned_duration > 0
    AND ps.session_start >= NOW() - INTERVAL '4 weeks'
    AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
),
final_ref AS (
  SELECT
    ap.n_days AS effective_days,
    ap.cv AS cv_daily,
    ap.active_days_per_wk,
    ap.personal_ref_raw,
    ap.freq_factor,
    ap.stability_factor,
    (ap.personal_ref_raw * ap.freq_factor * ap.stability_factor)::FLOAT8 AS personal_ref,
    pr.peer_daily_median::FLOAT8 AS peer_ref,
    LEAST(1.0, ap.n_days / 30.0)::FLOAT8 AS alpha_days,
    (r4.mins_4w / r4.active_days_4w)::FLOAT8 AS recent4_active_day_avg
  FROM adjusted_personal ap
  CROSS JOIN peer_ref_calc pr
  CROSS JOIN recent4 r4
),
scored AS (
  SELECT
    fr.*,
    (fr.alpha_days * fr.personal_ref + (1.0 - fr.alpha_days) * fr.peer_ref)::FLOAT8 AS blended_ref,
    (0.85 * fr.recent4_active_day_avg)::FLOAT8 AS floor_recent4,
    (0.70 * fr.peer_ref)::FLOAT8 AS floor_peer,
    CASE
      WHEN fr.effective_days >= 12 AND fr.active_days_per_wk >= 3.0 THEN
        GREATEST(
          (fr.alpha_days * fr.personal_ref + (1.0 - fr.alpha_days) * fr.peer_ref),
          0.85 * fr.recent4_active_day_avg,
          0.70 * fr.peer_ref
        )
      ELSE
        GREATEST(
          (fr.alpha_days * fr.personal_ref + (1.0 - fr.alpha_days) * fr.peer_ref),
          0.85 * fr.recent4_active_day_avg
        )
    END::FLOAT8 AS before_clamp
  FROM final_ref fr
)
SELECT
  p.p_student_name AS student_name,
  mi.student_major,
  s.effective_days,
  s.active_days_per_wk,
  s.cv_daily,
  s.personal_ref_raw,
  s.freq_factor,
  s.stability_factor,
  s.personal_ref,
  s.peer_ref,
  s.alpha_days,
  s.recent4_active_day_avg,
  s.blended_ref,
  s.floor_recent4,
  s.floor_peer,
  CASE
    WHEN s.effective_days >= 12 AND s.active_days_per_wk >= 3.0 THEN 'with_peer_floor'
    ELSE 'without_peer_floor'
  END AS floor_mode,
  s.before_clamp,
  GREATEST(30.0, LEAST(240.0, s.before_clamp))::FLOAT8 AS w_daily_ref
FROM scored s
CROSS JOIN params p
LEFT JOIN major_info mi ON TRUE;
