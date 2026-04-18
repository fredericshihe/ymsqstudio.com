-- ============================================================
-- setup_weekly_score_cron.sql
-- 注册 run_weekly_score_update() 的 pg_cron 定时任务
--
-- 触发时间：北京时间 每周五 21:35（UTC 每周五 13:35）
--
-- 执行顺序（每周五晚）：
--   21:30  backup_weekly_leaderboards_job  排行榜快照备份
--   21:32  reward_weekly_coins_job         结算发币
--   21:35  weekly_score_update_job         ← 本任务
--
-- 选择周五而非周一的原因：
--   · 周六周日练琴数据不计入成绩
--   · 周五 21:35 卡在周末之前，本周快照只含五天工作日有效数据
--   · 下周进步榜用此快照作基准，避免周末练习抬高基准导致进步榜虚高
--
-- 依赖：
--   public.run_weekly_score_update()   基线重算 + 周快照写入
--   pg_cron 扩展（Supabase 默认已启用）
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- 先删除旧任务（防止重复注册）
DO $$
BEGIN
    PERFORM cron.unschedule('weekly_score_update_job');
EXCEPTION WHEN OTHERS THEN
    NULL;
END;
$$;

-- 注册定时任务
SELECT cron.schedule(
    'weekly_score_update_job',          -- 任务名
    '35 13 * * 5',                      -- UTC 每周五 13:35 = BJT 每周五 21:35
    $$SELECT public.run_weekly_score_update();$$
);


-- ============================================================
-- 常用管理命令（注释，需要时手动执行）
-- ============================================================

-- 查看所有已注册 cron 任务：
-- SELECT jobname, schedule, command, active FROM cron.job ORDER BY jobname;

-- 查看本任务最近执行日志：
-- SELECT status, start_time, end_time, return_message
-- FROM cron.job_run_details
-- WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'weekly_score_update_job')
-- ORDER BY start_time DESC LIMIT 10;

-- 暂停任务（不删除）：
-- UPDATE cron.job SET active = false WHERE jobname = 'weekly_score_update_job';

-- 恢复任务：
-- UPDATE cron.job SET active = true WHERE jobname = 'weekly_score_update_job';

-- 取消任务：
-- SELECT cron.unschedule('weekly_score_update_job');

-- 手动立即触发（测试）：
-- SELECT public.run_weekly_score_update();
