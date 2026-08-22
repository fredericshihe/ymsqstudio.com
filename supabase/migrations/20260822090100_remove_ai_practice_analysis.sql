-- 彻底下线 AI 练琴分析功能：取消定时任务、删除缓存表。
-- 前端展示与触发代码已从 practiceanalyse.html / menuhin-school-system/index.html 移除；
-- supabase/functions/batch-ai-analysis Edge Function 随本次变更一并下线（见部署记录）。

-- ─── 取消所有历史版本的定时任务（存在才删，不存在时忽略）───
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

-- ─── 删除 AI 分析缓存表 ───
DROP TABLE IF EXISTS public.student_ai_analysis;
