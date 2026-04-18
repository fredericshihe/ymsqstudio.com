-- ============================================================================
-- W 维度专项核对：函数口径一致性 + 数据分布 + 时效性
-- 文件：verify_w_dimension_alignment.sql
-- 说明：纯只读；最后附可选修复语句（默认注释）
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) 核对线上函数定义是否与本地预期一致
--    重点看：compute_student_score / compute_and_store_w_score
-- ---------------------------------------------------------------------------
SELECT
  n.nspname AS schema_name,
  p.proname AS function_name,
  pg_get_function_identity_arguments(p.oid) AS args,
  p.prorettype::REGTYPE AS return_type
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('compute_student_score', 'compute_and_store_w_score', 'compute_student_score_as_of')
ORDER BY p.proname, args;

-- 查看函数源码（确认 W 的公式、是否 sigmoid、是否周末口径一致）
SELECT
  p.proname AS function_name,
  pg_get_functiondef(p.oid) AS ddl
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('compute_student_score', 'compute_and_store_w_score')
ORDER BY p.proname;


-- ---------------------------------------------------------------------------
-- 2) W 当前值分布（是否出现异常高分堆积）
-- ---------------------------------------------------------------------------
SELECT
  COUNT(*)::INT AS total_students,
  ROUND(AVG(COALESCE(w_score, 0))::NUMERIC, 4) AS avg_w,
  ROUND(STDDEV_POP(COALESCE(w_score, 0))::NUMERIC, 4) AS std_w,
  ROUND(PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY COALESCE(w_score, 0))::NUMERIC, 4) AS p10_w,
  ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY COALESCE(w_score, 0))::NUMERIC, 4) AS p50_w,
  ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY COALESCE(w_score, 0))::NUMERIC, 4) AS p90_w,
  ROUND(AVG((COALESCE(w_score, 0) >= 0.90)::INT)::NUMERIC, 4) AS ge_090_rate,
  ROUND(AVG((COALESCE(w_score, 0) >= 0.80)::INT)::NUMERIC, 4) AS ge_080_rate,
  ROUND(AVG((COALESCE(w_score, 0) <= 0.10)::INT)::NUMERIC, 4) AS le_010_rate
FROM public.student_baseline;


-- ---------------------------------------------------------------------------
-- 3) W 时效性检查（优先使用 w_score_updated_at）
-- 说明：
--   若列不存在或历史未回填，回退到 last_updated
-- ---------------------------------------------------------------------------
WITH now_bjt AS (
  SELECT NOW() AS now_utc
),
anchor AS (
  SELECT
    (DATE_TRUNC('week', now_utc AT TIME ZONE 'Asia/Shanghai')::TIMESTAMP
      AT TIME ZONE 'Asia/Shanghai') AS week_start_bjt_tz,
    now_utc
  FROM now_bjt
)
SELECT
  COUNT(*)::INT AS total_students,
  COUNT(*) FILTER (
    WHERE COALESCE(b.w_score_updated_at, b.last_updated) >= a.week_start_bjt_tz
  )::INT AS w_updated_since_week_start,
  COUNT(*) FILTER (
    WHERE COALESCE(b.w_score_updated_at, b.last_updated) < a.week_start_bjt_tz
       OR COALESCE(b.w_score_updated_at, b.last_updated) IS NULL
  )::INT AS w_not_updated_since_week_start,
  ROUND(
    COUNT(*) FILTER (
      WHERE COALESCE(b.w_score_updated_at, b.last_updated) < a.week_start_bjt_tz
         OR COALESCE(b.w_score_updated_at, b.last_updated) IS NULL
    )::NUMERIC
    / NULLIF(COUNT(*), 0), 4
  ) AS w_not_updated_ratio,
  '按 w_score_updated_at 统计；无该列时回退 last_updated'::TEXT AS note
FROM public.student_baseline b
CROSS JOIN anchor a;


-- ---------------------------------------------------------------------------
-- 4) W 与“同口径 progress_ratio”的一致性（分组）
--    注意：这里不强制 cap=1，避免信息损失
-- ---------------------------------------------------------------------------
WITH now_bjt AS (
  SELECT NOW() AS now_utc
),
elapsed AS (
  SELECT
    now_utc,
    (DATE_TRUNC('week', now_utc AT TIME ZONE 'Asia/Shanghai')::TIMESTAMP
      AT TIME ZONE 'Asia/Shanghai') AS week_start_bjt_tz,
    CASE
      WHEN EXTRACT(ISODOW FROM now_utc AT TIME ZONE 'Asia/Shanghai') IN (6, 7) THEN 5::NUMERIC
      ELSE LEAST(EXTRACT(ISODOW FROM now_utc AT TIME ZONE 'Asia/Shanghai'), 5)::NUMERIC
    END AS elapsed_days
  FROM now_bjt
),
wk AS (
  SELECT
    ps.student_name,
    COALESCE(SUM(ps.cleaned_duration), 0)::NUMERIC AS weekly_mins
  FROM public.practice_sessions ps
  CROSS JOIN elapsed e
  WHERE ps.cleaned_duration > 0
    AND ps.session_start >= e.week_start_bjt_tz
    AND ps.session_start < e.now_utc
    AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  GROUP BY ps.student_name
),
base AS (
  SELECT
    b.student_name,
    COALESCE(b.w_score, 0)::NUMERIC AS w_score,
    COALESCE(b.mean_duration, 0)::NUMERIC AS mean_duration,
    COALESCE(wk.weekly_mins, 0)::NUMERIC AS weekly_mins,
    (COALESCE(b.w_score_updated_at, b.last_updated) >= e.week_start_bjt_tz) AS refreshed_this_week,
    (COALESCE(wk.weekly_mins, 0) > 0) AS has_weekly_activity,
    COALESCE(wk.weekly_mins, 0)::NUMERIC
      / NULLIF(GREATEST(COALESCE(b.mean_duration, 0), 30) * e.elapsed_days, 0) AS progress_ratio_raw
  FROM public.student_baseline b
  CROSS JOIN elapsed e
  LEFT JOIN wk ON wk.student_name = b.student_name
)
SELECT
  grp_name,
  COUNT(*)::INT AS sample_cnt,
  ROUND(AVG(w_score), 4) AS avg_w_score,
  ROUND(AVG(progress_ratio_raw)::NUMERIC, 4) AS avg_progress_ratio_raw,
  ROUND(STDDEV_POP(progress_ratio_raw)::NUMERIC, 4) AS std_progress_ratio_raw,
  ROUND(CORR(w_score::FLOAT8, progress_ratio_raw::FLOAT8)::NUMERIC, 4) AS corr_w_vs_ratio,
  ROUND(
    CORR(
      w_score::FLOAT8,
      (1.0 / (1.0 + EXP(-3.0 * (progress_ratio_raw::FLOAT8 - 0.5))))
    )::NUMERIC, 4
  ) AS corr_w_vs_sigmoid_ratio
FROM (
  SELECT 'all_students'::TEXT AS grp_name, * FROM base
  UNION ALL
  SELECT 'refreshed_this_week', * FROM base WHERE refreshed_this_week
  UNION ALL
  SELECT 'has_weekly_activity', * FROM base WHERE has_weekly_activity
  UNION ALL
  SELECT 'refreshed_and_active', * FROM base WHERE refreshed_this_week AND has_weekly_activity
) s
GROUP BY grp_name
ORDER BY grp_name;


-- ---------------------------------------------------------------------------
-- 5) 极值样本抽样（便于人工看）
-- ---------------------------------------------------------------------------
WITH now_bjt AS (
  SELECT NOW() AS now_utc
),
elapsed AS (
  SELECT
    now_utc,
    (DATE_TRUNC('week', now_utc AT TIME ZONE 'Asia/Shanghai')::TIMESTAMP
      AT TIME ZONE 'Asia/Shanghai') AS week_start_bjt_tz,
    CASE
      WHEN EXTRACT(ISODOW FROM now_utc AT TIME ZONE 'Asia/Shanghai') IN (6, 7) THEN 5::NUMERIC
      ELSE LEAST(EXTRACT(ISODOW FROM now_utc AT TIME ZONE 'Asia/Shanghai'), 5)::NUMERIC
    END AS elapsed_days
  FROM now_bjt
),
wk AS (
  SELECT
    ps.student_name,
    COALESCE(SUM(ps.cleaned_duration), 0)::NUMERIC AS weekly_mins
  FROM public.practice_sessions ps
  CROSS JOIN elapsed e
  WHERE ps.cleaned_duration > 0
    AND ps.session_start >= e.week_start_bjt_tz
    AND ps.session_start < e.now_utc
    AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  GROUP BY ps.student_name
),
z AS (
  SELECT
    b.student_name,
    b.w_score,
    b.mean_duration,
    COALESCE(b.w_score_updated_at, b.last_updated) AS w_refreshed_at,
    COALESCE(wk.weekly_mins, 0) AS weekly_mins,
    COALESCE(wk.weekly_mins, 0)
      / NULLIF(GREATEST(COALESCE(b.mean_duration, 0), 30) * e.elapsed_days, 0) AS progress_ratio_raw
  FROM public.student_baseline b
  CROSS JOIN elapsed e
  LEFT JOIN wk ON wk.student_name = b.student_name
)
SELECT *
FROM z
ORDER BY w_score DESC NULLS LAST
LIMIT 30;

-- ---------------------------------------------------------------------------
-- 6) 异常计数：本周分钟为0，但 W 高分（理论不应出现）
-- ---------------------------------------------------------------------------
WITH now_bjt AS (
  SELECT NOW() AS now_utc
),
elapsed AS (
  SELECT
    now_utc,
    (DATE_TRUNC('week', now_utc AT TIME ZONE 'Asia/Shanghai')::TIMESTAMP
      AT TIME ZONE 'Asia/Shanghai') AS week_start_bjt_tz
  FROM now_bjt
),
wk AS (
  SELECT
    ps.student_name,
    COALESCE(SUM(ps.cleaned_duration), 0)::NUMERIC AS weekly_mins
  FROM public.practice_sessions ps
  CROSS JOIN elapsed e
  WHERE ps.cleaned_duration > 0
    AND ps.session_start >= e.week_start_bjt_tz
    AND ps.session_start < e.now_utc
    AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  GROUP BY ps.student_name
)
SELECT
  COUNT(*)::INT AS suspicious_cnt,
  ROUND(AVG(b.w_score)::NUMERIC, 4) AS suspicious_avg_w
FROM public.student_baseline b
LEFT JOIN wk ON wk.student_name = b.student_name
WHERE COALESCE(wk.weekly_mins, 0) = 0
  AND COALESCE(b.w_score, 0) >= 0.85;

-- 可选修复（谨慎，默认不执行）：
-- 1) 若确认线上公式已变更且需要统一，可先部署最新函数 SQL
-- 2) 全量刷新当前周 W（只在你确认函数正确后执行）
-- SELECT public.compute_and_store_w_score(student_name) FROM public.student_baseline;

