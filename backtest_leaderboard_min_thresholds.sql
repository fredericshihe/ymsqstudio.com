-- ============================================================================
-- 三个专项榜“最低上榜限度”全历史回测脚本（只读）
-- 文件：backtest_leaderboard_min_thresholds.sql
--
-- 目标：
-- 1) 用所有历史练琴记录 + 历史周快照重建每周专项榜候选样本
-- 2) 评估不同“最低门槛参数组”下，榜单是否过松/过严
-- 3) 为 leaderboard_rpc.sql 的参数更新提供可追溯依据
--
-- 数据来源（全历史）：
-- - public.student_score_history
-- - public.practice_sessions（仅工作日、cleaned_duration > 0）
--
-- 说明：
-- - 不依赖 weekly_leaderboard_history，避免“只备份了1周”导致回测失真
-- - alpha 使用历史快照中的 record_count 构造 alpha_proxy = LEAST(1, record_count / 15)
--   （用于历史回测分层，避免直接使用当前 student_baseline.alpha 造成穿越）
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0) 全历史样本分布（按榜单候选池）
-- ---------------------------------------------------------------------------
WITH weeks AS (
  SELECT DISTINCT h.snapshot_date::DATE AS week_monday
  FROM public.student_score_history h
  WHERE h.composite_score > 0
),
base_scores AS (
  SELECT
    h.snapshot_date::DATE AS week_monday,
    h.student_name,
    h.composite_score::NUMERIC AS display_score,
    COALESCE(h.mean_duration, 0)::NUMERIC AS mean_duration,
    COALESCE(h.record_count, 0)::INT AS record_count
  FROM public.student_score_history h
  WHERE h.composite_score > 0
),
week_sessions AS (
  SELECT
    w.week_monday,
    ps.student_name,
    COUNT(*)::INT AS week_sessions
  FROM weeks w
  JOIN public.practice_sessions ps
    ON ps.cleaned_duration > 0
   AND ps.session_start >= ((w.week_monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
   AND ps.session_start <  (((w.week_monday + INTERVAL '7 day')::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
   AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  GROUP BY w.week_monday, ps.student_name
),
recent10_raw AS (
  SELECT
    b.week_monday,
    b.student_name,
    ps.is_outlier,
    ps.cleaned_duration,
    ROW_NUMBER() OVER (
      PARTITION BY b.week_monday, b.student_name
      ORDER BY ps.session_start DESC
    ) AS rn
  FROM base_scores b
  JOIN public.practice_sessions ps
    ON ps.student_name = b.student_name
   AND ps.cleaned_duration > 0
   AND ps.session_start <  (((b.week_monday + INTERVAL '7 day')::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
   AND ps.session_start >= ((((b.week_monday + INTERVAL '7 day')::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai') - INTERVAL '12 weeks')
   AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
),
recent10 AS (
  SELECT
    week_monday,
    student_name,
    COUNT(*)::INT AS recent10_count,
    ROUND(AVG((is_outlier)::INT)::NUMERIC, 4) AS outlier_rate,
    ROUND(AVG(cleaned_duration)::NUMERIC, 2) AS recent10_mean_dur
  FROM recent10_raw
  WHERE rn <= 10
  GROUP BY week_monday, student_name
),
prev2_raw AS (
  SELECT
    b.week_monday,
    b.student_name,
    p.composite_score::NUMERIC AS prev_composite,
    ROW_NUMBER() OVER (
      PARTITION BY b.week_monday, b.student_name
      ORDER BY p.snapshot_date DESC
    ) AS rn
  FROM base_scores b
  JOIN public.student_score_history p
    ON p.student_name = b.student_name
   AND p.snapshot_date < b.week_monday
   AND p.snapshot_date >= b.week_monday - INTERVAL '12 weeks'
   AND p.composite_score > 0
),
prev2 AS (
  SELECT
    week_monday,
    student_name,
    MAX(prev_composite)::NUMERIC AS prev2_max
  FROM prev2_raw
  WHERE rn <= 2
  GROUP BY week_monday, student_name
),
hist_base AS (
  SELECT
    b.week_monday,
    b.student_name,
    b.display_score,
    b.mean_duration,
    b.record_count,
    ROUND(LEAST(1, b.record_count::NUMERIC / 15.0), 3) AS alpha_proxy,
    COALESCE(ws.week_sessions, 0)::INT AS week_sessions,
    COALESCE(r10.recent10_count, 0)::INT AS recent10_count,
    COALESCE(r10.outlier_rate, 1)::NUMERIC AS outlier_rate,
    COALESCE(r10.recent10_mean_dur, 0)::NUMERIC AS recent10_mean_dur,
    p2.prev2_max,
    ROUND((b.display_score - p2.prev2_max)::NUMERIC, 1) AS trend_delta
  FROM base_scores b
  LEFT JOIN week_sessions ws
    ON ws.week_monday = b.week_monday
   AND ws.student_name = b.student_name
  LEFT JOIN recent10 r10
    ON r10.week_monday = b.week_monday
   AND r10.student_name = b.student_name
  LEFT JOIN prev2 p2
    ON p2.week_monday = b.week_monday
   AND p2.student_name = b.student_name
),
comp AS (
  SELECT
    h.*,
    RANK() OVER (
      PARTITION BY h.week_monday
      ORDER BY h.display_score DESC NULLS LAST,
               h.mean_duration DESC NULLS LAST,
               h.record_count DESC NULLS LAST
    )::INT AS comp_rank
  FROM hist_base h
  WHERE h.week_sessions > 0
    AND h.display_score > 0
),
comp_top10 AS (
  SELECT week_monday, student_name
  FROM comp
  WHERE comp_rank <= 10
),
prog_pool AS (
  SELECT
    h.week_monday,
    '进步榜'::TEXT AS board,
    h.student_name,
    h.trend_delta,
    h.alpha_proxy,
    h.outlier_rate,
    h.recent10_mean_dur,
    h.recent10_count,
    h.week_sessions
  FROM hist_base h
  LEFT JOIN comp_top10 ct
    ON ct.week_monday = h.week_monday
   AND ct.student_name = h.student_name
  WHERE ct.student_name IS NULL
    AND h.prev2_max IS NOT NULL
    AND h.week_sessions >= 2
    AND h.trend_delta IS NOT NULL
    AND h.trend_delta > 0
),
stable_pool AS (
  SELECT
    h.week_monday,
    '稳定榜'::TEXT AS board,
    h.student_name,
    h.trend_delta,
    h.alpha_proxy,
    h.outlier_rate,
    h.recent10_mean_dur,
    h.recent10_count,
    h.week_sessions
  FROM hist_base h
  LEFT JOIN comp_top10 ct
    ON ct.week_monday = h.week_monday
   AND ct.student_name = h.student_name
  WHERE ct.student_name IS NULL
),
rules_pool AS (
  SELECT
    h.week_monday,
    '守则榜'::TEXT AS board,
    h.student_name,
    h.trend_delta,
    h.alpha_proxy,
    h.outlier_rate,
    h.recent10_mean_dur,
    h.recent10_count,
    h.week_sessions
  FROM hist_base h
  LEFT JOIN comp_top10 ct
    ON ct.week_monday = h.week_monday
   AND ct.student_name = h.student_name
  WHERE ct.student_name IS NULL
),
pool AS (
  SELECT * FROM prog_pool
  UNION ALL
  SELECT * FROM stable_pool
  UNION ALL
  SELECT * FROM rules_pool
)
SELECT
  board,
  COUNT(*)::INT AS sample_cnt,
  ROUND(PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY trend_delta)::NUMERIC, 2) AS p10_trend,
  ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY trend_delta)::NUMERIC, 2) AS p25_trend,
  ROUND(PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY alpha_proxy)::NUMERIC, 3) AS p10_alpha,
  ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY alpha_proxy)::NUMERIC, 3) AS p25_alpha,
  ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY outlier_rate)::NUMERIC, 3) AS p75_outlier,
  ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY outlier_rate)::NUMERIC, 3) AS p90_outlier,
  ROUND(PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY recent10_mean_dur)::NUMERIC, 1) AS p10_recent10_mean_dur,
  ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY recent10_mean_dur)::NUMERIC, 1) AS p25_recent10_mean_dur,
  ROUND(PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY recent10_count)::NUMERIC, 1) AS p10_recent10_count,
  ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY recent10_count)::NUMERIC, 1) AS p25_recent10_count,
  ROUND(PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY week_sessions)::NUMERIC, 1) AS p10_week_sessions,
  ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY week_sessions)::NUMERIC, 1) AS p25_week_sessions
FROM pool
GROUP BY board
ORDER BY board;


-- ---------------------------------------------------------------------------
-- 1) 参数组回测（全历史）
-- 指标解释：
-- - pass_rows: 满足最低门槛的历史候选行数
-- - pass_rate: 满足门槛占比
-- - empty_week_rate: 每周通过人数为0的比例（越低越好）
-- ---------------------------------------------------------------------------
WITH weeks AS (
  SELECT DISTINCT h.snapshot_date::DATE AS week_monday
  FROM public.student_score_history h
  WHERE h.composite_score > 0
),
base_scores AS (
  SELECT
    h.snapshot_date::DATE AS week_monday,
    h.student_name,
    h.composite_score::NUMERIC AS display_score,
    COALESCE(h.mean_duration, 0)::NUMERIC AS mean_duration,
    COALESCE(h.record_count, 0)::INT AS record_count
  FROM public.student_score_history h
  WHERE h.composite_score > 0
),
week_sessions AS (
  SELECT
    w.week_monday,
    ps.student_name,
    COUNT(*)::INT AS week_sessions
  FROM weeks w
  JOIN public.practice_sessions ps
    ON ps.cleaned_duration > 0
   AND ps.session_start >= ((w.week_monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
   AND ps.session_start <  (((w.week_monday + INTERVAL '7 day')::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
   AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  GROUP BY w.week_monday, ps.student_name
),
recent10_raw AS (
  SELECT
    b.week_monday,
    b.student_name,
    ps.is_outlier,
    ps.cleaned_duration,
    ROW_NUMBER() OVER (
      PARTITION BY b.week_monday, b.student_name
      ORDER BY ps.session_start DESC
    ) AS rn
  FROM base_scores b
  JOIN public.practice_sessions ps
    ON ps.student_name = b.student_name
   AND ps.cleaned_duration > 0
   AND ps.session_start <  (((b.week_monday + INTERVAL '7 day')::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
   AND ps.session_start >= ((((b.week_monday + INTERVAL '7 day')::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai') - INTERVAL '12 weeks')
   AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
),
recent10 AS (
  SELECT
    week_monday,
    student_name,
    COUNT(*)::INT AS recent10_count,
    ROUND(AVG((is_outlier)::INT)::NUMERIC, 4) AS outlier_rate,
    ROUND(AVG(cleaned_duration)::NUMERIC, 2) AS recent10_mean_dur
  FROM recent10_raw
  WHERE rn <= 10
  GROUP BY week_monday, student_name
),
prev2_raw AS (
  SELECT
    b.week_monday,
    b.student_name,
    p.composite_score::NUMERIC AS prev_composite,
    ROW_NUMBER() OVER (
      PARTITION BY b.week_monday, b.student_name
      ORDER BY p.snapshot_date DESC
    ) AS rn
  FROM base_scores b
  JOIN public.student_score_history p
    ON p.student_name = b.student_name
   AND p.snapshot_date < b.week_monday
   AND p.snapshot_date >= b.week_monday - INTERVAL '12 weeks'
   AND p.composite_score > 0
),
prev2 AS (
  SELECT
    week_monday,
    student_name,
    MAX(prev_composite)::NUMERIC AS prev2_max
  FROM prev2_raw
  WHERE rn <= 2
  GROUP BY week_monday, student_name
),
hist_base AS (
  SELECT
    b.week_monday,
    b.student_name,
    b.display_score,
    b.mean_duration,
    b.record_count,
    ROUND(LEAST(1, b.record_count::NUMERIC / 15.0), 3) AS alpha_proxy,
    COALESCE(ws.week_sessions, 0)::INT AS week_sessions,
    COALESCE(r10.recent10_count, 0)::INT AS recent10_count,
    COALESCE(r10.outlier_rate, 1)::NUMERIC AS outlier_rate,
    COALESCE(r10.recent10_mean_dur, 0)::NUMERIC AS recent10_mean_dur,
    p2.prev2_max,
    ROUND((b.display_score - p2.prev2_max)::NUMERIC, 1) AS trend_delta
  FROM base_scores b
  LEFT JOIN week_sessions ws
    ON ws.week_monday = b.week_monday
   AND ws.student_name = b.student_name
  LEFT JOIN recent10 r10
    ON r10.week_monday = b.week_monday
   AND r10.student_name = b.student_name
  LEFT JOIN prev2 p2
    ON p2.week_monday = b.week_monday
   AND p2.student_name = b.student_name
),
comp AS (
  SELECT
    h.*,
    RANK() OVER (
      PARTITION BY h.week_monday
      ORDER BY h.display_score DESC NULLS LAST,
               h.mean_duration DESC NULLS LAST,
               h.record_count DESC NULLS LAST
    )::INT AS comp_rank
  FROM hist_base h
  WHERE h.week_sessions > 0
    AND h.display_score > 0
),
comp_top10 AS (
  SELECT week_monday, student_name
  FROM comp
  WHERE comp_rank <= 10
),
pool AS (
  SELECT
    h.week_monday, '进步榜'::TEXT AS board, h.student_name,
    h.trend_delta, h.alpha_proxy, h.outlier_rate, h.recent10_mean_dur, h.recent10_count, h.week_sessions
  FROM hist_base h
  LEFT JOIN comp_top10 ct
    ON ct.week_monday = h.week_monday
   AND ct.student_name = h.student_name
  WHERE ct.student_name IS NULL
    AND h.prev2_max IS NOT NULL
    AND h.week_sessions >= 2
    AND h.trend_delta IS NOT NULL
    AND h.trend_delta > 0

  UNION ALL

  SELECT
    h.week_monday, '稳定榜'::TEXT AS board, h.student_name,
    h.trend_delta, h.alpha_proxy, h.outlier_rate, h.recent10_mean_dur, h.recent10_count, h.week_sessions
  FROM hist_base h
  LEFT JOIN comp_top10 ct
    ON ct.week_monday = h.week_monday
   AND ct.student_name = h.student_name
  WHERE ct.student_name IS NULL

  UNION ALL

  SELECT
    h.week_monday, '守则榜'::TEXT AS board, h.student_name,
    h.trend_delta, h.alpha_proxy, h.outlier_rate, h.recent10_mean_dur, h.recent10_count, h.week_sessions
  FROM hist_base h
  LEFT JOIN comp_top10 ct
    ON ct.week_monday = h.week_monday
   AND ct.student_name = h.student_name
  WHERE ct.student_name IS NULL
),
profiles AS (
  SELECT *
  FROM (VALUES
    -- profile_name,
    -- prog_min_delta, prog_min_recent10_count, prog_max_outlier,
    -- stable_min_alpha, stable_max_outlier, stable_min_recent10_count, stable_min_mean_dur,
    -- rules_min_week_sessions, rules_min_recent10_count, rules_min_mean_dur, rules_max_outlier, rules_min_alpha
    ('baseline_old', 0.0::NUMERIC, 0::INT, 0.50::NUMERIC, 0.55::NUMERIC, 0.40::NUMERIC, 8::INT, 0::NUMERIC, 3::INT, 4::INT, 25::NUMERIC, 0.50::NUMERIC, 0.55::NUMERIC),
    ('fix_lb_80',    1.0::NUMERIC, 4::INT, 0.45::NUMERIC, 0.60::NUMERIC, 0.35::NUMERIC, 8::INT, 30::NUMERIC, 3::INT, 5::INT, 30::NUMERIC, 0.40::NUMERIC, 0.60::NUMERIC),
    ('strict_high',  2.0::NUMERIC, 6::INT, 0.40::NUMERIC, 0.65::NUMERIC, 0.30::NUMERIC, 9::INT, 35::NUMERIC, 4::INT, 6::INT, 35::NUMERIC, 0.35::NUMERIC, 0.65::NUMERIC)
  ) AS t(
    profile_name,
    prog_min_delta, prog_min_recent10_count, prog_max_outlier,
    stable_min_alpha, stable_max_outlier, stable_min_recent10_count, stable_min_mean_dur,
    rules_min_week_sessions, rules_min_recent10_count, rules_min_mean_dur, rules_max_outlier, rules_min_alpha
  )
),
eval_rows AS (
  SELECT
    p.profile_name,
    b.week_monday,
    b.board,
    b.student_name,
    CASE
      WHEN b.board = '进步榜' THEN
        (b.trend_delta >= p.prog_min_delta)
        AND (b.recent10_count >= p.prog_min_recent10_count)
        AND (b.outlier_rate <= p.prog_max_outlier)
      WHEN b.board = '稳定榜' THEN
        (b.alpha_proxy >= p.stable_min_alpha)
        AND (b.outlier_rate <= p.stable_max_outlier)
        AND (b.recent10_count >= p.stable_min_recent10_count)
        AND (b.recent10_mean_dur >= p.stable_min_mean_dur)
      WHEN b.board = '守则榜' THEN
        (b.week_sessions >= p.rules_min_week_sessions)
        AND (b.recent10_count >= p.rules_min_recent10_count)
        AND (b.recent10_mean_dur >= p.rules_min_mean_dur)
        AND (b.outlier_rate <= p.rules_max_outlier)
        AND (b.alpha_proxy >= p.rules_min_alpha)
      ELSE FALSE
    END AS pass_flag
  FROM pool b
  CROSS JOIN profiles p
),
board_dim AS (
  SELECT board FROM (VALUES ('进步榜'::TEXT), ('稳定榜'::TEXT), ('守则榜'::TEXT)) t(board)
),
weekly_rollup AS (
  SELECT
    profile_name,
    board,
    week_monday,
    COUNT(*)::INT AS raw_rows,
    COUNT(*) FILTER (WHERE pass_flag)::INT AS pass_rows
  FROM eval_rows
  GROUP BY profile_name, board, week_monday
),
all_weeks AS (
  SELECT DISTINCT week_monday FROM weeks
),
weekly_full AS (
  SELECT
    p.profile_name,
    d.board,
    w.week_monday,
    COALESCE(r.raw_rows, 0)::INT AS raw_rows,
    COALESCE(r.pass_rows, 0)::INT AS pass_rows
  FROM profiles p
  CROSS JOIN board_dim d
  CROSS JOIN all_weeks w
  LEFT JOIN weekly_rollup r
    ON r.profile_name = p.profile_name
   AND r.board = d.board
   AND r.week_monday = w.week_monday
)
SELECT
  profile_name,
  board,
  SUM(raw_rows)::INT AS raw_rows,
  SUM(pass_rows)::INT AS pass_rows,
  ROUND((SUM(pass_rows)::NUMERIC / NULLIF(SUM(raw_rows), 0)), 4) AS pass_rate,
  COUNT(*)::INT AS week_cnt,
  ROUND(AVG(pass_rows)::NUMERIC, 2) AS avg_pass_rows_per_week,
  ROUND(AVG((pass_rows = 0)::INT)::NUMERIC, 4) AS empty_week_rate
FROM weekly_full
GROUP BY profile_name, board
ORDER BY profile_name, board;


-- ---------------------------------------------------------------------------
-- 2) 回测样本充分性告警（全历史）
-- 建议：
-- - week_cnt < 4  : 仅做方向性观察，不建议改参数
-- - 4 <= week_cnt < 8 : 可小幅微调，需连续复核
-- - week_cnt >= 8 : 可作为正式调参依据
-- ---------------------------------------------------------------------------
WITH weeks AS (
  SELECT DISTINCT h.snapshot_date::DATE AS week_monday
  FROM public.student_score_history h
  WHERE h.composite_score > 0
),
wk AS (
  SELECT
    b.board,
    COUNT(DISTINCT b.week_monday)::INT AS week_cnt,
    COUNT(*)::INT AS row_cnt
  FROM (
    SELECT week_monday, '进步榜'::TEXT AS board
    FROM weeks
    UNION ALL
    SELECT week_monday, '稳定榜'::TEXT
    FROM weeks
    UNION ALL
    SELECT week_monday, '守则榜'::TEXT
    FROM weeks
  ) b
  GROUP BY b.board
)
SELECT
  board,
  week_cnt,
  row_cnt,
  CASE
    WHEN week_cnt < 4 THEN 'INSUFFICIENT'
    WHEN week_cnt < 8 THEN 'LIMITED'
    ELSE 'SUFFICIENT'
  END AS sample_status,
  CASE
    WHEN week_cnt < 4 THEN '样本周数过少：仅做方向性观察，暂不建议继续收紧阈值'
    WHEN week_cnt < 8 THEN '样本周数有限：可小幅微调，建议连续2-4周复核'
    ELSE '样本周数充足：可作为正式调参依据'
  END AS guidance
FROM wk
ORDER BY board;

