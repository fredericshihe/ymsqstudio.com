-- ============================================================================
-- FIX-81 验证脚本：W 日均基准个性化升级验收
-- 只读脚本
-- ============================================================================

-- 1) 抽样查看个体基准构成
SELECT
  sb.student_name,
  sb.student_major,
  r.w_daily_ref,
  r.personal_ref,
  r.peer_ref,
  r.effective_days,
  r.alpha_days,
  r.active_days_per_wk,
  r.cv_daily
FROM public.student_baseline sb
CROSS JOIN LATERAL public.get_personalized_w_daily_ref(sb.student_name) r
ORDER BY sb.last_updated DESC
LIMIT 100;


-- 2) 看“完成率过高”是否收敛（当前周）
WITH now_bjt AS (
  SELECT NOW() AT TIME ZONE 'Asia/Shanghai' AS now_ts
),
elapsed AS (
  SELECT
    CASE
      WHEN EXTRACT(ISODOW FROM now_ts) IN (6, 7) THEN 5::FLOAT8
      ELSE LEAST(EXTRACT(ISODOW FROM now_ts), 5)::FLOAT8
    END AS elapsed_days,
    DATE_TRUNC('week', now_ts)::TIMESTAMP AS week_start
  FROM now_bjt
),
wk AS (
  SELECT
    ps.student_name,
    COALESCE(SUM(ps.cleaned_duration), 0)::FLOAT8 AS weekly_mins
  FROM public.practice_sessions ps
  CROSS JOIN elapsed e
  WHERE ps.cleaned_duration > 0
    AND ps.session_start >= e.week_start
    AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  GROUP BY ps.student_name
),
ratios AS (
  SELECT
    sb.student_name,
    wk.weekly_mins,
    r.w_daily_ref,
    e.elapsed_days,
    CASE
      WHEN r.w_daily_ref <= 0 OR e.elapsed_days <= 0 THEN NULL
      ELSE wk.weekly_mins / (r.w_daily_ref * e.elapsed_days)
    END AS ratio
  FROM public.student_baseline sb
  CROSS JOIN elapsed e
  LEFT JOIN wk ON wk.student_name = sb.student_name
  CROSS JOIN LATERAL public.get_personalized_w_daily_ref(sb.student_name) r
)
SELECT
  COUNT(*) FILTER (WHERE ratio IS NOT NULL) AS sample_cnt,
  ROUND(AVG(ratio)::NUMERIC, 4) AS avg_ratio,
  ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY ratio)::NUMERIC, 4) AS p90_ratio,
  ROUND(AVG((ratio >= 2.0)::INT)::NUMERIC, 4) AS ratio_ge_200pct_rate,
  ROUND(AVG((ratio >= 3.0)::INT)::NUMERIC, 4) AS ratio_ge_300pct_rate
FROM ratios;


-- 3) W 分区分度体检
SELECT
  COUNT(*)::INT AS sample_cnt,
  ROUND(AVG(w_score)::NUMERIC, 4) AS avg_w,
  ROUND(PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY w_score)::NUMERIC, 4) AS p10_w,
  ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY w_score)::NUMERIC, 4) AS p50_w,
  ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY w_score)::NUMERIC, 4) AS p90_w,
  ROUND((PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY w_score)
       - PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY w_score))::NUMERIC, 4) AS p90_p10_spread
FROM public.student_baseline
WHERE w_score IS NOT NULL;

