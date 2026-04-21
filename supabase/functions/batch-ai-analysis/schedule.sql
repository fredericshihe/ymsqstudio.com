-- ============================================================
-- batch-ai-analysis 每日定时调度配置
-- 目标：自动触发时只分析“综合榜前 50 人”，不再做多批全量扫描
-- 在 Supabase Dashboard > SQL Editor 中执行此脚本
-- ============================================================

-- ─── 第一步：安全删除旧任务（不存在时忽略，不中断脚本）───────────────────────
DO $$
BEGIN
  PERFORM cron.unschedule('batch-ai-analysis-daily');
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

DO $$
BEGIN
  PERFORM cron.unschedule('ai-analysis-batch-1');
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

DO $$
BEGIN
  PERFORM cron.unschedule('ai-analysis-batch-2');
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

DO $$
BEGIN
  PERFORM cron.unschedule('ai-analysis-batch-3');
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

DO $$
BEGIN
  PERFORM cron.unschedule('ai-analysis-top50-daily');
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

-- ─── 第二步：注册“综合榜前 50”自动任务 ───────────────────────────────────────
-- 工作日 UTC 02:00 = 北京时间 10:00
-- 说明：
-- 1. 只触发 1 个任务
-- 2. 函数内部会按 composite_score DESC, student_name ASC 分页
-- 3. 这里固定 offset=0, limit=50，因此自动任务永远只处理综合榜前 50
SELECT cron.schedule(
  'ai-analysis-top50-daily',
  '0 2 * * 1-5',
  $$
  SELECT net.http_post(
    url := 'https://waesizzoqodntrlvrwhw.supabase.co/functions/v1/batch-ai-analysis',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndhZXNpenpvcW9kbnRybHZyd2h3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTc4MjIyOTYsImV4cCI6MjA3MzM5ODI5Nn0.kE5gSV68q1nLo4z2IqgwqfTBVqNOJw5qs08f6r0SQH0',
      'x-batch-secret', 'menuhin2026'
    ),
    body := '{"offset":0,"limit":50}'::jsonb,
    timeout_milliseconds := 420000
  );
  $$
);

-- ─── 手动测试（可选）────────────────────────────────────────────────────────
/*
SELECT net.http_post(
  url := 'https://waesizzoqodntrlvrwhw.supabase.co/functions/v1/batch-ai-analysis',
  headers := jsonb_build_object(
    'Content-Type', 'application/json',
    'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndhZXNpenpvcW9kbnRybHZyd2h3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTc4MjIyOTYsImV4cCI6MjA3MzM5ODI5Nn0.kE5gSV68q1nLo4z2IqgwqfTBVqNOJw5qs08f6r0SQH0',
    'x-batch-secret', 'menuhin2026'
  ),
  body := '{"offset":0,"limit":50,"force_run":true}'::jsonb,
  timeout_milliseconds := 420000
);
*/

/*
SELECT id, status_code, content::text, created
FROM net._http_response
ORDER BY created DESC
LIMIT 10;
*/

-- ─── 说明 ─────────────────────────────────────────────────────────────────
-- 若后续需要手动补跑综合榜 51~100 名：
-- body := '{"offset":50,"limit":50,"force_run":true}'::jsonb
--
-- 若后续需要手动补跑综合榜 101~150 名：
-- body := '{"offset":100,"limit":50,"force_run":true}'::jsonb
