-- ============================================================================
-- 维度阈值专项回测（B/T/M/A/W）
-- 文件：backtest_dimension_thresholds.sql
-- 说明：纯只读，不调用会写库的函数
-- 目标：检查“参数阈值是否合理”，而不仅是总分是否正常
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0) 当前口径参数快照（用于人工核对）
-- ---------------------------------------------------------------------------
SELECT *
FROM (
  VALUES
    ('B/T 混合权重', 'change=80%, level=20%', '已部署口径'),
    ('M 达标线', 'weekly_mins >= GREATEST(effective_mean,30)*5*1.00', '当前为100%，旧口径60%'),
    ('W 基线', 'progress = weekly_mins / (GREATEST(effective_mean,30)*elapsed_days)', '并截断到[0,1]'),
    ('综合权重(常规)', 'B22% T22% M15% A11% W30%', 'record_count >= 40'),
    ('综合权重(新生)', 'B10% T10% M10% A15% W55%', 'record_count < 40')
) AS t(param_name, current_value, note);


-- ---------------------------------------------------------------------------
-- 1) B/T/M/A 历史分布健康度（区分度 + 饱和度）
-- 建议阈值：
-- - near_top_rate(>=0.9) 过高 => 阈值偏松/易满分
-- - near_bottom_rate(<=0.1) 过高 => 阈值偏严
-- - p90-p10 < 0.20 => 区分度不足
-- ---------------------------------------------------------------------------
WITH params AS (
  SELECT 26::INT AS lookback_weeks
),
scope AS (
  SELECT *
  FROM public.student_score_history h
  CROSS JOIN params p
  WHERE h.snapshot_date >= (
    DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
    - (p.lookback_weeks::TEXT || ' weeks')::INTERVAL
  )
),
dim AS (
  SELECT 'B'::TEXT AS dim_name, baseline_score::NUMERIC AS dim_score FROM scope
  UNION ALL
  SELECT 'T', trend_score::NUMERIC FROM scope
  UNION ALL
  SELECT 'M', momentum_score::NUMERIC FROM scope
  UNION ALL
  SELECT 'A', accum_score::NUMERIC FROM scope
),
stats AS (
  SELECT
    dim_name,
    COUNT(*)::INT AS sample_cnt,
    ROUND(AVG(dim_score), 4) AS avg_score,
    ROUND(STDDEV_POP(dim_score), 4) AS std_score,
    ROUND(PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY dim_score)::NUMERIC, 4) AS p10,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY dim_score)::NUMERIC, 4) AS p50,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY dim_score)::NUMERIC, 4) AS p90,
    ROUND(AVG((dim_score <= 0.10)::INT)::NUMERIC, 4) AS near_bottom_rate,
    ROUND(AVG((dim_score >= 0.90)::INT)::NUMERIC, 4) AS near_top_rate,
    ROUND(AVG((dim_score BETWEEN 0.40 AND 0.60)::INT)::NUMERIC, 4) AS mid_band_rate
  FROM dim
  GROUP BY dim_name
)
SELECT
  dim_name,
  sample_cnt,
  avg_score,
  std_score,
  p10, p50, p90,
  ROUND((p90 - p10)::NUMERIC, 4) AS p90_p10_spread,
  near_bottom_rate,
  near_top_rate,
  mid_band_rate,
  CASE
    WHEN near_top_rate > 0.45 THEN '可能偏松(高分饱和)'
    WHEN near_bottom_rate > 0.45 THEN '可能偏严(低分堆积)'
    WHEN (p90 - p10) < 0.20 THEN '区分度偏弱'
    ELSE '基本合理'
  END AS health_hint
FROM stats
ORDER BY dim_name;


-- ---------------------------------------------------------------------------
-- 2) M 维度阈值敏感性回测（60% / 80% / 100% / 120%）
-- 解释：
-- - 用“最近4个活跃周均值”作为个人近期基线（并加 floor=150 分钟/周）
-- - 评估不同阈值下达标率，观察 100% 是否过严/过松
-- ---------------------------------------------------------------------------
WITH weekly AS (
  SELECT
    ps.student_name,
    DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE AS week_start,
    SUM(ps.cleaned_duration)::NUMERIC AS weekly_mins
  FROM public.practice_sessions ps
  WHERE ps.cleaned_duration > 0
    AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  GROUP BY ps.student_name, DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE
),
active AS (
  SELECT *
  FROM weekly
  WHERE weekly_mins > 0
),
base AS (
  SELECT
    student_name,
    week_start,
    weekly_mins,
    AVG(weekly_mins) OVER (
      PARTITION BY student_name
      ORDER BY week_start
      ROWS BETWEEN 4 PRECEDING AND 1 PRECEDING
    )::NUMERIC AS prev4_avg
  FROM active
),
eligible AS (
  SELECT
    student_name,
    week_start,
    weekly_mins,
    GREATEST(COALESCE(prev4_avg, 0), 150)::NUMERIC AS base_weekly
  FROM base
  WHERE prev4_avg IS NOT NULL
),
result AS (
  SELECT
    COUNT(*)::INT AS sample_cnt,
    ROUND(AVG((weekly_mins >= base_weekly * 0.60)::INT)::NUMERIC, 4) AS hit_60,
    ROUND(AVG((weekly_mins >= base_weekly * 0.80)::INT)::NUMERIC, 4) AS hit_80,
    ROUND(AVG((weekly_mins >= base_weekly * 1.00)::INT)::NUMERIC, 4) AS hit_100,
    ROUND(AVG((weekly_mins >= base_weekly * 1.20)::INT)::NUMERIC, 4) AS hit_120
  FROM eligible
)
SELECT
  sample_cnt,
  hit_60,
  hit_80,
  hit_100,
  hit_120,
  CASE
    WHEN hit_100 > 0.75 THEN '100%阈值可能偏松（达标过高）'
    WHEN hit_100 < 0.20 THEN '100%阈值可能偏严（达标过低）'
    ELSE '100%阈值区间合理'
  END AS m_threshold_hint
FROM result;


-- ---------------------------------------------------------------------------
-- 3) A 维度阈值（记录数驱动）合理性：分桶单调性检查
-- 预期：record_count 越高，A 维度中位数总体上升（允许轻微波动）
-- ---------------------------------------------------------------------------
WITH cur AS (
  SELECT
    student_name,
    COALESCE(record_count, 0) AS record_count,
    COALESCE(accum_score, 0)::NUMERIC AS accum_score
  FROM public.student_baseline
),
buckets AS (
  SELECT
    CASE
      WHEN record_count < 10 THEN '00-09'
      WHEN record_count < 20 THEN '10-19'
      WHEN record_count < 40 THEN '20-39'
      WHEN record_count < 80 THEN '40-79'
      ELSE '80+'
    END AS bucket,
    CASE
      WHEN record_count < 10 THEN 1
      WHEN record_count < 20 THEN 2
      WHEN record_count < 40 THEN 3
      WHEN record_count < 80 THEN 4
      ELSE 5
    END AS bucket_order,
    accum_score
  FROM cur
),
agg AS (
  SELECT
    bucket,
    bucket_order,
    COUNT(*)::INT AS student_cnt,
    ROUND(AVG(accum_score), 4) AS avg_a,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY accum_score)::NUMERIC, 4) AS p50_a
  FROM buckets
  GROUP BY bucket, bucket_order
),
mono AS (
  SELECT
    a.*,
    LAG(p50_a) OVER (ORDER BY bucket_order) AS prev_p50_a
  FROM agg a
)
SELECT
  bucket,
  student_cnt,
  avg_a,
  p50_a,
  prev_p50_a,
  CASE
    WHEN prev_p50_a IS NULL THEN '起始桶'
    WHEN p50_a + 0.03 < prev_p50_a THEN '可能不合理(明显逆序)'
    ELSE '基本合理'
  END AS monotonic_hint
FROM mono
ORDER BY bucket_order;


-- ---------------------------------------------------------------------------
-- 4) W 维度（当前周）阈值合理性：w_score 与进度比一致性
-- 注意：历史表未存 w_score，这里检查“当前横截面”
-- ---------------------------------------------------------------------------
WITH now_bjt AS (
  SELECT NOW() AT TIME ZONE 'Asia/Shanghai' AS now_ts
),
elapsed AS (
  SELECT
    now_ts,
    CASE
      WHEN EXTRACT(ISODOW FROM now_ts) IN (6, 7) THEN 5::NUMERIC
      ELSE LEAST(EXTRACT(ISODOW FROM now_ts), 5)::NUMERIC
    END AS elapsed_weekdays,
    DATE_TRUNC('week', now_ts)::TIMESTAMP AS week_start
  FROM now_bjt
),
wk AS (
  SELECT
    ps.student_name,
    COALESCE(SUM(ps.cleaned_duration), 0)::NUMERIC AS weekly_mins
  FROM public.practice_sessions ps
  CROSS JOIN elapsed e
  WHERE ps.cleaned_duration > 0
    AND ps.session_start >= e.week_start
    AND ps.session_start < e.now_ts
    AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  GROUP BY ps.student_name
),
cur AS (
  SELECT
    b.student_name,
    COALESCE(b.mean_duration, 0)::NUMERIC AS mean_duration,
    COALESCE(b.w_score, 0)::NUMERIC AS w_score,
    COALESCE(wk.weekly_mins, 0)::NUMERIC AS weekly_mins
  FROM public.student_baseline b
  LEFT JOIN wk ON wk.student_name = b.student_name
),
kpi AS (
  SELECT
    c.student_name,
    c.w_score,
    c.weekly_mins,
    GREATEST(c.mean_duration, 30) AS effective_daily,
    e.elapsed_weekdays,
    LEAST(
      1.0,
      c.weekly_mins / NULLIF(GREATEST(c.mean_duration, 30) * e.elapsed_weekdays, 0)
    )::NUMERIC AS progress_ratio_cap
  FROM cur c
  CROSS JOIN elapsed e
)
SELECT
  COUNT(*)::INT AS sample_cnt,
  ROUND(AVG(w_score), 4) AS avg_w_score,
  ROUND(AVG(progress_ratio_cap), 4) AS avg_progress_ratio_cap,
  ROUND(CORR(w_score::FLOAT8, progress_ratio_cap::FLOAT8)::NUMERIC, 4) AS corr_w_vs_progress,
  ROUND(AVG((w_score <= 0.10)::INT)::NUMERIC, 4) AS w_near_bottom_rate,
  ROUND(AVG((w_score >= 0.90)::INT)::NUMERIC, 4) AS w_near_top_rate,
  CASE
    WHEN CORR(w_score::FLOAT8, progress_ratio_cap::FLOAT8) < 0.60 THEN 'W一致性偏弱，建议复核'
    WHEN AVG((w_score >= 0.90)::INT) > 0.60 THEN 'W可能偏松(高分饱和)'
    WHEN AVG((w_score <= 0.10)::INT) > 0.60 THEN 'W可能偏严(低分堆积)'
    ELSE 'W阈值基本合理'
  END AS w_threshold_hint
FROM kpi;

-- ---------------------------------------------------------------------------
-- 4B) W 维度深度诊断（剔除“未在本周刷新”的样本）
-- 说明：
-- 1) w_score 存在于 student_baseline，会在触发重算时更新，可能出现“旧周残留值”
-- 2) 为避免误判，分两组看相关性：
--    - refreshed_this_week：last_updated 在本周一之后（更可信）
--    - has_weekly_activity：本周有练琴数据
-- ---------------------------------------------------------------------------
WITH now_bjt AS (
  SELECT NOW() AT TIME ZONE 'Asia/Shanghai' AS now_ts
),
elapsed AS (
  SELECT
    now_ts,
    CASE
      WHEN EXTRACT(ISODOW FROM now_ts) IN (6, 7) THEN 5::NUMERIC
      ELSE LEAST(EXTRACT(ISODOW FROM now_ts), 5)::NUMERIC
    END AS elapsed_weekdays,
    DATE_TRUNC('week', now_ts)::TIMESTAMP AS week_start
  FROM now_bjt
),
wk AS (
  SELECT
    ps.student_name,
    COALESCE(SUM(ps.cleaned_duration), 0)::NUMERIC AS weekly_mins
  FROM public.practice_sessions ps
  CROSS JOIN elapsed e
  WHERE ps.cleaned_duration > 0
    AND ps.session_start >= e.week_start
    AND ps.session_start < e.now_ts
    AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  GROUP BY ps.student_name
),
cur AS (
  SELECT
    b.student_name,
    COALESCE(b.mean_duration, 0)::NUMERIC AS mean_duration,
    COALESCE(b.w_score, 0)::NUMERIC AS w_score,
    COALESCE(wk.weekly_mins, 0)::NUMERIC AS weekly_mins,
    (b.last_updated >= e.week_start) AS refreshed_this_week
  FROM public.student_baseline b
  CROSS JOIN elapsed e
  LEFT JOIN wk ON wk.student_name = b.student_name
),
kpi AS (
  SELECT
    c.student_name,
    c.w_score,
    c.weekly_mins,
    c.refreshed_this_week,
    (c.weekly_mins > 0) AS has_weekly_activity,
    LEAST(
      1.0,
      c.weekly_mins / NULLIF(GREATEST(c.mean_duration, 30) * e.elapsed_weekdays, 0)
    )::NUMERIC AS progress_ratio_cap
  FROM cur c
  CROSS JOIN elapsed e
)
SELECT
  grp_name,
  COUNT(*)::INT AS sample_cnt,
  ROUND(AVG(w_score), 4) AS avg_w_score,
  ROUND(AVG(progress_ratio_cap), 4) AS avg_progress_ratio_cap,
  ROUND(CORR(w_score::FLOAT8, progress_ratio_cap::FLOAT8)::NUMERIC, 4) AS corr_w_vs_progress,
  ROUND(AVG((w_score >= 0.90)::INT)::NUMERIC, 4) AS w_near_top_rate,
  ROUND(AVG((w_score <= 0.10)::INT)::NUMERIC, 4) AS w_near_bottom_rate
FROM (
  SELECT 'all_students'::TEXT AS grp_name, * FROM kpi
  UNION ALL
  SELECT 'refreshed_this_week', * FROM kpi WHERE refreshed_this_week
  UNION ALL
  SELECT 'has_weekly_activity', * FROM kpi WHERE has_weekly_activity
  UNION ALL
  SELECT 'refreshed_and_active', * FROM kpi WHERE refreshed_this_week AND has_weekly_activity
) s
GROUP BY grp_name
ORDER BY grp_name;


-- ---------------------------------------------------------------------------
-- 5) B/T 假期中性化触发率（参数阈值 3周/4周 的现实命中情况）
-- 目的：检查“中性化”是否几乎从不触发（阈值太高）或频繁触发（阈值太低）
-- ---------------------------------------------------------------------------
WITH weekly AS (
  SELECT
    ps.student_name,
    DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE AS week_start,
    SUM(ps.cleaned_duration)::NUMERIC AS weekly_mins
  FROM public.practice_sessions ps
  WHERE ps.cleaned_duration > 0
    AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  GROUP BY ps.student_name, DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE
),
active AS (
  SELECT * FROM weekly WHERE weekly_mins > 0
),
gaps AS (
  SELECT
    student_name,
    week_start,
    LAG(week_start) OVER (PARTITION BY student_name ORDER BY week_start) AS prev_week_start
  FROM active
),
g AS (
  SELECT
    student_name,
    week_start,
    ((week_start - prev_week_start)::NUMERIC / 7.0) AS gap_weeks
  FROM gaps
  WHERE prev_week_start IS NOT NULL
)
SELECT
  COUNT(*)::INT AS sample_cnt,
  ROUND(AVG((gap_weeks > 3)::INT)::NUMERIC, 4) AS trigger_b_gap_gt3_rate,
  ROUND(AVG((gap_weeks > 4)::INT)::NUMERIC, 4) AS trigger_t_gap_gt4_rate,
  ROUND(AVG((gap_weeks > 8)::INT)::NUMERIC, 4) AS long_break_gt8_rate,
  CASE
    WHEN AVG((gap_weeks > 3)::INT) < 0.02 THEN 'B中性化触发较少，可观察是否阈值偏高'
    WHEN AVG((gap_weeks > 3)::INT) > 0.40 THEN 'B中性化触发偏频繁，可观察是否阈值偏低'
    ELSE 'B/T 中性化阈值命中率正常'
  END AS holiday_neutralize_hint
FROM g;


-- ---------------------------------------------------------------------------
-- 6) 综合结论（自动 PASS/REVIEW）
-- 规则：只要命中“严重信号”则给 REVIEW
-- ---------------------------------------------------------------------------
WITH params AS (
  SELECT 26::INT AS lookback_weeks
),
scope AS (
  SELECT *
  FROM public.student_score_history h
  CROSS JOIN params p
  WHERE h.snapshot_date >= (
    DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
    - (p.lookback_weeks::TEXT || ' weeks')::INTERVAL
  )
),
dim AS (
  SELECT 'B'::TEXT AS dim_name, baseline_score::NUMERIC AS dim_score FROM scope
  UNION ALL SELECT 'T', trend_score::NUMERIC FROM scope
  UNION ALL SELECT 'M', momentum_score::NUMERIC FROM scope
  UNION ALL SELECT 'A', accum_score::NUMERIC FROM scope
),
dim_kpi AS (
  SELECT
    dim_name,
    AVG((dim_score <= 0.10)::INT)::NUMERIC AS near_bottom_rate,
    AVG((dim_score >= 0.90)::INT)::NUMERIC AS near_top_rate,
    (
      PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY dim_score)
      - PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY dim_score)
    )::NUMERIC AS spread
  FROM dim
  GROUP BY dim_name
),
risk_cnt AS (
  SELECT COUNT(*)::INT AS cnt
  FROM dim_kpi
  WHERE near_top_rate > 0.60
     OR near_bottom_rate > 0.60
     OR spread < 0.15
)
SELECT
  CASE WHEN cnt = 0 THEN 'PASS' ELSE 'REVIEW' END AS final_result,
  cnt AS severe_signal_count,
  CASE
    WHEN cnt = 0 THEN '维度阈值未见明显失衡，可继续观察'
    ELSE '存在维度饱和/堆积/区分度不足信号，建议调参前再做分群分析'
  END AS message
FROM risk_cnt;

