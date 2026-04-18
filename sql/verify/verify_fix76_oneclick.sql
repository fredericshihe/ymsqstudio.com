-- ============================================================
-- verify_fix76_oneclick.sql
-- 一键核验：FIX-74 / FIX-75 / FIX-76 是否完整生效
--
-- 用法：
--   直接在 Supabase SQL Editor 整段执行（只读，不写数据）
--
-- 覆盖范围：
--  1) 触发器绑定与启用状态
--  2) 关键函数 SECURITY DEFINER 与版本特征
--  3) 周任务 cron 注册状态
--  4) 排行榜口径（周末不计榜）是否存在明显异常
--  5) 分数口径（composite_score = raw_score*100）一致性
-- ============================================================

-- ============================================================
-- 0) 触发器链路核验
-- ============================================================
WITH trg AS (
  SELECT
    c.relname AS table_name,
    t.tgname  AS trigger_name,
    p.proname AS function_name,
    t.tgenabled,
    (p.prosecdef) AS security_definer,
    CASE (t.tgtype & 28)
      WHEN 4  THEN 'INSERT'
      WHEN 8  THEN 'DELETE'
      WHEN 16 THEN 'UPDATE'
      WHEN 20 THEN 'INSERT+UPDATE'
      WHEN 12 THEN 'INSERT+DELETE'
      ELSE 'OTHER'
    END AS event_type
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_proc  p ON p.oid = t.tgfoid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE NOT t.tgisinternal
    AND n.nspname = 'public'
    AND t.tgname IN (
      'trg_insert_session',
      'trg_update_baseline',
      'trg_compute_score_on_baseline_update'
    )
)
SELECT
  '触发器链路' AS check_item,
  trigger_name,
  table_name,
  event_type,
  CASE WHEN tgenabled = 'O' THEN '✅ 启用' ELSE '❌ 未启用' END AS enabled_status,
  CASE WHEN security_definer THEN '✅ SECURITY DEFINER' ELSE '❌ 普通权限' END AS security_mode
FROM trg
ORDER BY trigger_name;


-- ============================================================
-- 1) 关键函数版本特征核验
-- ============================================================
WITH f AS (
  SELECT
    p.proname AS fn,
    p.prosecdef AS security_definer,
    pg_get_functiondef(p.oid) AS def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN (
      'trigger_insert_session',
      'trigger_update_student_baseline',
      'trigger_compute_student_score',
      'compute_baseline_as_of',
      'compute_baseline',
      'run_weekly_score_update',
      'backfill_score_history',
      'get_weekly_leaderboards'
    )
)
SELECT
  fn AS function_name,
  CASE WHEN security_definer THEN '✅ SECURITY DEFINER' ELSE '❌ 普通权限' END AS security_mode,
  CASE
    WHEN fn = 'get_weekly_leaderboards' AND def ILIKE '%EXTRACT(DOW FROM session_start AT TIME ZONE ''Asia/Shanghai'') NOT IN (0, 6)%'
      AND def ILIKE '%(monday::TIMESTAMP) AT TIME ZONE ''Asia/Shanghai''%'
      THEN '✅ FIX-76 工作日口径 + 北京时间边界'
    WHEN fn = 'run_weekly_score_update' AND def ILIKE '%DATE_TRUNC(''week'', NOW() AT TIME ZONE ''Asia/Shanghai'')%'
      AND def ILIKE '%EXTRACT(DOW FROM session_start AT TIME ZONE ''Asia/Shanghai'') NOT IN (0, 6)%'
      AND def NOT ILIKE '%PERCENT_RANK()%'
      THEN '✅ FIX-75/76 生效'
    WHEN fn = 'backfill_score_history' AND def ILIKE '%(v_current_date::TIMESTAMP) AT TIME ZONE ''Asia/Shanghai''%'
      AND def ILIKE '%ROUND((raw_score * 100)::NUMERIC, 1)%'
      AND def ILIKE '%SET raw_score       = latest.raw_score%'
      AND def NOT ILIKE '%PERCENT_RANK()%'
      THEN '✅ FIX-74/76/77 生效'
    WHEN fn = 'compute_baseline_as_of' AND def ILIKE '%v_asof_bjt := (p_as_of_date::TIMESTAMP) AT TIME ZONE ''Asia/Shanghai''%'
      THEN '✅ FIX-76 生效'
    WHEN fn = 'compute_baseline' AND def ILIKE '%((NOW() AT TIME ZONE ''Asia/Shanghai'')::DATE + 1)%'
      THEN '✅ FIX-76 生效'
    WHEN fn = 'trigger_compute_student_score' AND def ILIKE '%pg_trigger_depth()%'
      AND def ILIKE '%app.skip_score_trigger%'
      THEN '✅ 防递归 + 批量保护'
    ELSE '⚠️ 请人工复核'
  END AS version_check
FROM f
ORDER BY fn;


-- ============================================================
-- 2) cron 任务核验（周五链路）
-- ============================================================
SELECT
  jobname,
  schedule,
  active,
  CASE
    WHEN jobname = 'backup_weekly_leaderboards_job' AND schedule = '30 13 * * 5' AND active THEN '✅ 21:30 备份'
    WHEN jobname = 'reward_weekly_coins_job'       AND schedule = '32 13 * * 5' AND active THEN '✅ 21:32 发币'
    WHEN jobname = 'weekly_score_update_job'       AND schedule = '35 13 * * 5' AND active THEN '✅ 21:35 周快照'
    ELSE '⚠️ 配置不符'
  END AS cron_check
FROM cron.job
WHERE jobname IN (
  'backup_weekly_leaderboards_job',
  'reward_weekly_coins_job',
  'weekly_score_update_job'
)
ORDER BY jobname;


-- ============================================================
-- 3) 分数口径一致性（绝对分）核验
-- ============================================================
SELECT
  COUNT(*) AS sample_count,
  COUNT(*) FILTER (
    WHERE composite_score = ROUND((raw_score * 100)::NUMERIC, 1)
  ) AS exact_match_count,
  ROUND(
    100.0 * COUNT(*) FILTER (
      WHERE composite_score = ROUND((raw_score * 100)::NUMERIC, 1)
    ) / NULLIF(COUNT(*), 0),
    2
  ) AS exact_match_rate_pct
FROM public.student_baseline
WHERE raw_score IS NOT NULL;

SELECT
  student_name,
  raw_score,
  composite_score,
  ROUND((raw_score * 100)::NUMERIC, 1) AS expected_score,
  (composite_score - ROUND((raw_score * 100)::NUMERIC, 1)) AS diff
FROM public.student_baseline
WHERE raw_score IS NOT NULL
  AND composite_score <> ROUND((raw_score * 100)::NUMERIC, 1)
ORDER BY ABS(composite_score - ROUND((raw_score * 100)::NUMERIC, 1)) DESC
LIMIT 20;


-- ============================================================
-- 4) 周末不计榜的观测核验（当前周）
-- ============================================================
WITH wm AS (
  SELECT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS monday
),
wk AS (
  SELECT
    ps.student_name,
    COUNT(*) FILTER (
      WHERE ps.session_start >= ((wm.monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
    ) AS all_sessions,
    COUNT(*) FILTER (
      WHERE ps.session_start >= ((wm.monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
        AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    ) AS weekday_sessions
  FROM public.practice_sessions ps
  CROSS JOIN wm
  GROUP BY ps.student_name
)
SELECT
  COUNT(*) FILTER (WHERE all_sessions > 0 AND weekday_sessions = 0) AS weekend_only_students_this_week,
  COUNT(*) FILTER (WHERE weekday_sessions > 0) AS weekday_active_students_this_week
FROM wk;

-- weekend_only_students_this_week > 0 并不一定是问题（可能真实有人只周末练）
-- 但如果很多，且用户反馈“周末不应影响榜单”，请重点抽查这些学生是否上榜：
SELECT
  w.student_name,
  w.all_sessions,
  w.weekday_sessions
FROM (
  WITH wm AS (
    SELECT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS monday
  )
  SELECT
    ps.student_name,
    COUNT(*) FILTER (
      WHERE ps.session_start >= ((wm.monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
    ) AS all_sessions,
    COUNT(*) FILTER (
      WHERE ps.session_start >= ((wm.monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
        AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    ) AS weekday_sessions
  FROM public.practice_sessions ps
  CROSS JOIN wm
  GROUP BY ps.student_name
) w
WHERE w.all_sessions > 0
  AND w.weekday_sessions = 0
ORDER BY w.all_sessions DESC
LIMIT 30;


-- ============================================================
-- 5) 最终总览（人工快速读）
-- ============================================================
SELECT
  NOW() AS checked_at,
  '请确认：上面所有关键函数 version_check 均为✅，三条 cron_check 均为✅，exact_match_rate_pct 接近 100%' AS summary_hint;
