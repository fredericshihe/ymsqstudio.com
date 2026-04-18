-- ============================================================
-- 音符币自动结算准确性核对脚本（只读）
-- 文件：verify_coin_reward_accuracy.sql
--
-- 目标：
-- 1) 按当前 get_weekly_leaderboards() 规则重算“应发”金额
-- 2) 对比 weekly_coin_reward_detail / weekly_coin_reward_log 实际落库结果
-- 3) 校验 weekly_coin_reward_detail 与 coin_transactions(auto_reward) 一致性
-- ============================================================

-- A) 当前周“应发”预览（尚未结算时用于预检查）
WITH week_monday AS (
  SELECT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS monday
),
expected AS (
  SELECT
    wm.monday AS week_monday,
    r.board,
    r.rank_no,
    r.student_name,
    CASE
      WHEN r.board = '综合榜' AND r.rank_no = 1 THEN 100
      WHEN r.board = '综合榜' AND r.rank_no BETWEEN 2 AND 3 THEN 80
      WHEN r.board = '综合榜' AND r.rank_no BETWEEN 4 AND 6 THEN 60
      WHEN r.board = '综合榜' AND r.rank_no BETWEEN 7 AND 10 THEN 40
      WHEN r.board = '稳定榜' AND r.rank_no = 1 THEN 50
      WHEN r.board = '稳定榜' AND r.rank_no BETWEEN 2 AND 3 THEN 35
      WHEN r.board = '稳定榜' AND r.rank_no BETWEEN 4 AND 6 THEN 20
      WHEN r.board = '守则榜' AND r.rank_no = 1 THEN 45
      WHEN r.board = '守则榜' AND r.rank_no BETWEEN 2 AND 3 THEN 30
      WHEN r.board = '守则榜' AND r.rank_no BETWEEN 4 AND 6 THEN 18
      WHEN r.board = '进步榜' AND r.rank_no = 1 THEN 40
      WHEN r.board = '进步榜' AND r.rank_no BETWEEN 2 AND 3 THEN 25
      WHEN r.board = '进步榜' AND r.rank_no BETWEEN 4 AND 6 THEN 15
      ELSE 0
    END AS expected_amount
  FROM week_monday wm
  CROSS JOIN public.get_weekly_leaderboards() r
),
expected_filtered AS (
  SELECT * FROM expected WHERE expected_amount > 0
)
SELECT
  week_monday,
  board,
  rank_no,
  student_name,
  expected_amount
FROM expected_filtered
ORDER BY board, rank_no, student_name;

-- B) 当前周“应发汇总”
WITH week_monday AS (
  SELECT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS monday
),
expected AS (
  SELECT
    CASE
      WHEN r.board = '综合榜' AND r.rank_no = 1 THEN 100
      WHEN r.board = '综合榜' AND r.rank_no BETWEEN 2 AND 3 THEN 80
      WHEN r.board = '综合榜' AND r.rank_no BETWEEN 4 AND 6 THEN 60
      WHEN r.board = '综合榜' AND r.rank_no BETWEEN 7 AND 10 THEN 40
      WHEN r.board = '稳定榜' AND r.rank_no = 1 THEN 50
      WHEN r.board = '稳定榜' AND r.rank_no BETWEEN 2 AND 3 THEN 35
      WHEN r.board = '稳定榜' AND r.rank_no BETWEEN 4 AND 6 THEN 20
      WHEN r.board = '守则榜' AND r.rank_no = 1 THEN 45
      WHEN r.board = '守则榜' AND r.rank_no BETWEEN 2 AND 3 THEN 30
      WHEN r.board = '守则榜' AND r.rank_no BETWEEN 4 AND 6 THEN 18
      WHEN r.board = '进步榜' AND r.rank_no = 1 THEN 40
      WHEN r.board = '进步榜' AND r.rank_no BETWEEN 2 AND 3 THEN 25
      WHEN r.board = '进步榜' AND r.rank_no BETWEEN 4 AND 6 THEN 15
      ELSE 0
    END AS expected_amount
  FROM week_monday wm
  CROSS JOIN public.get_weekly_leaderboards() r
)
SELECT
  COUNT(*) FILTER (WHERE expected_amount > 0) AS expected_events,
  COALESCE(SUM(expected_amount) FILTER (WHERE expected_amount > 0), 0) AS expected_coins
FROM expected;

-- C) 若本周已结算：应发 vs 实发（明细表）
WITH week_monday AS (
  SELECT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS monday
),
expected AS (
  SELECT
    wm.monday AS week_monday,
    r.board,
    r.rank_no,
    r.student_name,
    CASE
      WHEN r.board = '综合榜' AND r.rank_no = 1 THEN 100
      WHEN r.board = '综合榜' AND r.rank_no BETWEEN 2 AND 3 THEN 80
      WHEN r.board = '综合榜' AND r.rank_no BETWEEN 4 AND 6 THEN 60
      WHEN r.board = '综合榜' AND r.rank_no BETWEEN 7 AND 10 THEN 40
      WHEN r.board = '稳定榜' AND r.rank_no = 1 THEN 50
      WHEN r.board = '稳定榜' AND r.rank_no BETWEEN 2 AND 3 THEN 35
      WHEN r.board = '稳定榜' AND r.rank_no BETWEEN 4 AND 6 THEN 20
      WHEN r.board = '守则榜' AND r.rank_no = 1 THEN 45
      WHEN r.board = '守则榜' AND r.rank_no BETWEEN 2 AND 3 THEN 30
      WHEN r.board = '守则榜' AND r.rank_no BETWEEN 4 AND 6 THEN 18
      WHEN r.board = '进步榜' AND r.rank_no = 1 THEN 40
      WHEN r.board = '进步榜' AND r.rank_no BETWEEN 2 AND 3 THEN 25
      WHEN r.board = '进步榜' AND r.rank_no BETWEEN 4 AND 6 THEN 15
      ELSE 0
    END AS expected_amount
  FROM week_monday wm
  CROSS JOIN public.get_weekly_leaderboards() r
),
expected_filtered AS (
  SELECT * FROM expected WHERE expected_amount > 0
),
actual AS (
  SELECT
    d.week_monday,
    d.board,
    d.rank_no,
    d.student_name,
    d.amount AS actual_amount
  FROM public.weekly_coin_reward_detail d
  JOIN week_monday wm ON d.week_monday = wm.monday
)
SELECT
  COALESCE(e.week_monday, a.week_monday) AS week_monday,
  COALESCE(e.board, a.board) AS board,
  COALESCE(e.rank_no, a.rank_no) AS rank_no,
  COALESCE(e.student_name, a.student_name) AS student_name,
  e.expected_amount,
  a.actual_amount,
  CASE
    WHEN e.student_name IS NULL THEN 'UNEXPECTED_ACTUAL'
    WHEN a.student_name IS NULL THEN 'MISSING_ACTUAL'
    WHEN e.expected_amount <> a.actual_amount THEN 'AMOUNT_MISMATCH'
    ELSE 'OK'
  END AS check_result
FROM expected_filtered e
FULL OUTER JOIN actual a
  ON e.week_monday = a.week_monday
 AND e.board = a.board
 AND e.rank_no = a.rank_no
 AND e.student_name = a.student_name
ORDER BY board, rank_no, student_name;

-- D) 本周结算日志总计 vs 明细总计
WITH week_monday AS (
  SELECT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS monday
),
log_sum AS (
  SELECT
    l.week_monday,
    l.total_events,
    l.total_coins
  FROM public.weekly_coin_reward_log l
  JOIN week_monday wm ON l.week_monday = wm.monday
),
detail_sum AS (
  SELECT
    d.week_monday,
    COUNT(*) AS detail_events,
    COALESCE(SUM(d.amount), 0) AS detail_coins
  FROM public.weekly_coin_reward_detail d
  JOIN week_monday wm ON d.week_monday = wm.monday
  GROUP BY d.week_monday
)
SELECT
  COALESCE(ls.week_monday, ds.week_monday) AS week_monday,
  ls.total_events,
  ds.detail_events,
  ls.total_coins,
  ds.detail_coins,
  CASE WHEN ls.total_events = ds.detail_events THEN 'OK' ELSE 'MISMATCH' END AS events_check,
  CASE WHEN ls.total_coins = ds.detail_coins THEN 'OK' ELSE 'MISMATCH' END AS coins_check
FROM log_sum ls
FULL OUTER JOIN detail_sum ds
  ON ls.week_monday = ds.week_monday;

-- E) 本周明细表 vs 流水表（auto_reward）一致性
WITH week_monday AS (
  SELECT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS monday
),
detail_rows AS (
  SELECT
    d.week_monday,
    d.student_name,
    d.amount,
    d.reason
  FROM public.weekly_coin_reward_detail d
  JOIN week_monday wm ON d.week_monday = wm.monday
),
tx_rows AS (
  SELECT
    t.student_name,
    t.amount,
    t.reason
  FROM public.coin_transactions t
  WHERE t.transaction_type = 'auto_reward'
    AND t.created_at >= ((DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE)::TIMESTAMP AT TIME ZONE 'Asia/Shanghai')
)
SELECT
  COALESCE(d.student_name, t.student_name) AS student_name,
  d.amount AS detail_amount,
  t.amount AS tx_amount,
  d.reason AS detail_reason,
  t.reason AS tx_reason,
  CASE
    WHEN d.student_name IS NULL THEN 'UNEXPECTED_TX'
    WHEN t.student_name IS NULL THEN 'MISSING_TX'
    WHEN d.amount <> t.amount THEN 'AMOUNT_MISMATCH'
    WHEN d.reason <> t.reason THEN 'REASON_MISMATCH'
    ELSE 'OK'
  END AS check_result
FROM detail_rows d
FULL OUTER JOIN tx_rows t
  ON d.student_name = t.student_name
 AND d.amount = t.amount
 AND d.reason = t.reason
ORDER BY student_name;

