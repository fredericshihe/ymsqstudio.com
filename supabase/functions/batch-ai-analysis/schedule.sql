-- ============================================================
-- batch-ai-analysis 每日定时调度配置（支持 300+ 学生分批处理）
-- 在 Supabase Dashboard > SQL Editor 中执行此脚本
-- ⚠️  注意：只能调用 cron 函数，不能直接查 cron.job 表（权限不足）
--     查看/管理任务请用 Dashboard > Database > Cron Jobs（可视化界面）
-- ============================================================

-- ─── 第一步：安全删除旧任务（不存在时忽略，不中断脚本）───────────────────────
DO $$
BEGIN
  PERFORM cron.unschedule('batch-ai-analysis-daily'); -- 旧单批任务
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

-- ─── 第二步：注册 3 个分批任务 ────────────────────────────────────────────────
-- 第 1 批：UTC 02:00 = 北京时间 10:00（仅周一~周五），处理第 1～100 名
SELECT cron.schedule(
  'ai-analysis-batch-1',
  '0 2 * * 1-5',
  $$
  SELECT net.http_post(
    url     := 'https://waesizzoqodntrlvrwhw.supabase.co/functions/v1/batch-ai-analysis',
    headers := jsonb_build_object(
      'Content-Type',   'application/json',
      'Authorization',  'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndhZXNpenpvcW9kbnRybHZyd2h3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTc4MjIyOTYsImV4cCI6MjA3MzM5ODI5Nn0.kE5gSV68q1nLo4z2IqgwqfTBVqNOJw5qs08f6r0SQH0',
      'x-batch-secret', 'menuhin2026'
    ),
    body    := '{"offset": 0, "limit": 100}'::jsonb,
    timeout_milliseconds := 420000
  );
  $$
);

-- 第 2 批：UTC 02:10 = 北京时间 10:10（仅周一~周五），处理第 101～200 名
SELECT cron.schedule(
  'ai-analysis-batch-2',
  '10 2 * * 1-5',
  $$
  SELECT net.http_post(
    url     := 'https://waesizzoqodntrlvrwhw.supabase.co/functions/v1/batch-ai-analysis',
    headers := jsonb_build_object(
      'Content-Type',   'application/json',
      'Authorization',  'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndhZXNpenpvcW9kbnRybHZyd2h3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTc4MjIyOTYsImV4cCI6MjA3MzM5ODI5Nn0.kE5gSV68q1nLo4z2IqgwqfTBVqNOJw5qs08f6r0SQH0',
      'x-batch-secret', 'menuhin2026'
    ),
    body    := '{"offset": 100, "limit": 100}'::jsonb,
    timeout_milliseconds := 420000
  );
  $$
);

-- 第 3 批：UTC 02:20 = 北京时间 10:20（仅周一~周五），处理第 201～300 名
SELECT cron.schedule(
  'ai-analysis-batch-3',
  '20 2 * * 1-5',
  $$
  SELECT net.http_post(
    url     := 'https://waesizzoqodntrlvrwhw.supabase.co/functions/v1/batch-ai-analysis',
    headers := jsonb_build_object(
      'Content-Type',   'application/json',
      'Authorization',  'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndhZXNpenpvcW9kbnRybHZyd2h3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTc4MjIyOTYsImV4cCI6MjA3MzM5ODI5Nn0.kE5gSV68q1nLo4z2IqgwqfTBVqNOJw5qs08f6r0SQH0',
      'x-batch-secret', 'menuhin2026'
    ),
    body    := '{"offset": 200, "limit": 100}'::jsonb,
    timeout_milliseconds := 420000
  );
  $$
);

-- 以上 3 条执行成功后，去 Dashboard > Database > Cron Jobs 可视化确认


-- ─── 手动测试（可选）────────────────────────────────────────────────────────
-- 每条单独执行，等上一批响应后再执行下一条

-- 测试第 1 批（offset=0）
/*
SELECT net.http_post(
  url     := 'https://waesizzoqodntrlvrwhw.supabase.co/functions/v1/batch-ai-analysis',
  headers := jsonb_build_object(
    'Content-Type',   'application/json',
    'Authorization',  'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndhZXNpenpvcW9kbnRybHZyd2h3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTc4MjIyOTYsImV4cCI6MjA3MzM5ODI5Nn0.kE5gSV68q1nLo4z2IqgwqfTBVqNOJw5qs08f6r0SQH0',
    'x-batch-secret', 'menuhin2026'
  ),
  body := '{"offset": 0, "limit": 100}'::jsonb
);
*/

-- 查看上面手动触发的请求结果（触发后等约 10 秒再执行）
/*
SELECT id, status_code, content::text, created
FROM net._http_response
ORDER BY created DESC
LIMIT 5;
*/


-- ─── 管理命令（全部用函数，不直接查表）──────────────────────────────────────

-- 暂停某个任务（先到 Dashboard > Database > Cron Jobs 找到任务 ID）
-- UPDATE cron.job SET active = false WHERE jobname = 'ai-analysis-batch-1';
-- ↑ 上面这句也需要权限，建议直接在 Dashboard Cron Jobs 界面里点 Pause

-- 删除分批任务（重新配置时先执行）
-- SELECT cron.unschedule('ai-analysis-batch-1');
-- SELECT cron.unschedule('ai-analysis-batch-2');
-- SELECT cron.unschedule('ai-analysis-batch-3');

-- 若学生超过 300 人，增加第 4 批（UTC 02:30 = 北京时间 10:30）：
-- SELECT cron.schedule('ai-analysis-batch-4', '30 2 * * *',
--   $$SELECT net.http_post(
--     url:='https://waesizzoqodntrlvrwhw.supabase.co/functions/v1/batch-ai-analysis',
--     headers:=jsonb_build_object('Content-Type','application/json',
--       'Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndhZXNpenpvcW9kbnRybHZyd2h3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTc4MjIyOTYsImV4cCI6MjA3MzM5ODI5Nn0.kE5gSV68q1nLo4z2IqgwqfTBVqNOJw5qs08f6r0SQH0',
--       'x-batch-secret','menuhin2026'),
--     body:='{"offset":300,"limit":100}'::jsonb,
--     timeout_milliseconds:=420000);$$);
