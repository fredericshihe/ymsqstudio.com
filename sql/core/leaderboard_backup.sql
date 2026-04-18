-- ============================================================================
-- 每周五 21:30 自动备份排行榜 SQL 脚本
-- ============================================================================

-- 1. 创建排行榜历史备份表
CREATE TABLE IF NOT EXISTS public.weekly_leaderboard_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    backup_date DATE NOT NULL DEFAULT CURRENT_DATE, -- 备份执行的日期
    week_monday DATE NOT NULL,                      -- 归属的周一日期（用于按周查询）
    board TEXT NOT NULL,                            -- 榜单名称
    rank_no INTEGER NOT NULL,                       -- 名次
    student_name TEXT NOT NULL,                     -- 学生姓名
    student_major TEXT,                             -- 专业
    student_grade TEXT,                             -- 年级
    display_score NUMERIC,                          -- 综合分
    alpha NUMERIC,                                  -- 可信度
    trend_score NUMERIC,                            -- 趋势分
    mean_duration NUMERIC,                          -- 均练时长
    record_count INTEGER,                           -- 记录数
    recent10_outlier_rate NUMERIC,                  -- 近10条异常率
    recent10_mean_dur NUMERIC,                      -- 近10条均练时长
    recent10_count INTEGER,                         -- 近10条记录数
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()   -- 备份写入时间
);

-- 为备份表创建索引，方便以后按周或按学生查询历史
CREATE INDEX IF NOT EXISTS idx_wlh_week_board ON public.weekly_leaderboard_history(week_monday, board);
CREATE INDEX IF NOT EXISTS idx_wlh_student ON public.weekly_leaderboard_history(student_name);

-- 2. 创建执行备份的函数
CREATE OR REPLACE FUNCTION public.backup_weekly_leaderboards()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER -- 使用创建者权限执行，确保有写入权限
AS $$
DECLARE
    v_monday DATE;
BEGIN
    -- 获取本周一的日期（北京时间）作为这一周的批次标识
    v_monday := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;

    -- 防重机制：如果同一周内多次执行备份，先删除该周旧数据，保证只保留最新的一份
    DELETE FROM public.weekly_leaderboard_history
    WHERE week_monday = v_monday;

    -- 将当前 get_weekly_leaderboards() 的所有数据快照插入备份表
    INSERT INTO public.weekly_leaderboard_history (
        week_monday, backup_date, board, rank_no, student_name, student_major, student_grade,
        display_score, alpha, trend_score, mean_duration, record_count,
        recent10_outlier_rate, recent10_mean_dur, recent10_count
    )
    SELECT
        v_monday,
        (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE,
        board, rank_no, student_name, student_major, student_grade,
        display_score, alpha, trend_score, mean_duration, record_count,
        recent10_outlier_rate, recent10_mean_dur, recent10_count
    FROM public.get_weekly_leaderboards();
END;
$$;

-- 3. 配置定时任务 (使用 pg_cron)
-- 开启 pg_cron 扩展（如果尚未开启）
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- 如果之前有同名任务，先取消掉（避免重复创建报错）
DO $$
BEGIN
    PERFORM cron.unschedule('backup_weekly_leaderboards_job');
EXCEPTION WHEN OTHERS THEN
    -- 忽略错误
END;
$$;

-- 创建定时任务
-- 注意：Supabase 的 pg_cron 默认使用 UTC 时间。
-- 北京时间周五 21:30 = UTC 时间周五 13:30。
-- Cron 表达式: '30 13 * * 5' (分 时 日 月 星期，5代表周五)
SELECT cron.schedule(
    'backup_weekly_leaderboards_job',
    '30 13 * * 5',
    $$SELECT public.backup_weekly_leaderboards();$$
);
