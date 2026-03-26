-- ============================================================
-- 周榜音符币自动结算系统
-- 文件：setup_coin_rewards.sql
--
-- 功能概述：
--   每周五 北京时间 21:32 自动读取 get_weekly_leaderboards()，
--   按下表规则给各榜上榜学生发放音符币，并写入流水说明。
--
-- 发放规则（与 index.html Tips 弹窗保持一致）：
--   名次        综合榜   稳定榜   守则榜   进步榜
--   第 1 名      100      50       45       40
--   第 2–3 名     80      35       30       25
--   第 4–6 名     60      20       18       15
--   第 7–10 名    40      —        —        —
--
-- 正式开始日期：北京时间 2026-03-27（周五）
-- pg_cron 表达式（UTC）：32 13 * * 5
--
-- 依赖：
--   public.get_weekly_leaderboards()    排行榜数据
--   public.adjust_student_coins()       原子写余额 + 流水
--   pg_cron 扩展
-- ============================================================


-- ============================================================
-- 1. 系统全局配置表（key-value）
--    用于存储管理员可控开关，如自动结算开关
-- ============================================================
CREATE TABLE IF NOT EXISTS public.system_settings (
    key        TEXT        PRIMARY KEY,
    value      TEXT        NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.system_settings IS '系统全局配置，key-value 结构';

-- 默认：自动结算开关 = 开启
INSERT INTO public.system_settings (key, value)
VALUES ('auto_coin_reward_enabled', 'true')
ON CONFLICT (key) DO NOTHING;

-- 允许前端读取配置
GRANT SELECT ON public.system_settings TO anon, authenticated;

-- 切换开关的 RPC（SECURITY DEFINER 保证权限安全）
CREATE OR REPLACE FUNCTION public.set_auto_reward_enabled(p_enabled BOOLEAN)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    INSERT INTO public.system_settings (key, value, updated_at)
    VALUES ('auto_coin_reward_enabled', p_enabled::TEXT, NOW())
    ON CONFLICT (key) DO UPDATE
        SET value      = p_enabled::TEXT,
            updated_at = NOW();
    RETURN p_enabled;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_auto_reward_enabled(BOOLEAN) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_auto_reward_enabled(BOOLEAN) TO service_role;


-- ============================================================
-- 2. 防重复结算记录表
--    UNIQUE(week_monday) 确保同一周只执行一次
-- ============================================================
CREATE TABLE IF NOT EXISTS public.weekly_coin_reward_log (
    id            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    week_monday   DATE         NOT NULL UNIQUE,    -- 该周周一，唯一键
    rewarded_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    total_events  INTEGER      NOT NULL DEFAULT 0, -- 本周总发放次数（同学生多榜算多次）
    total_coins   INTEGER      NOT NULL DEFAULT 0, -- 本周总发放音符币数
    summary       JSONB                            -- 各榜人次/金额明细
);

COMMENT ON TABLE  public.weekly_coin_reward_log IS
    '每周音符币自动结算记录；UNIQUE(week_monday) 防重复执行';
COMMENT ON COLUMN public.weekly_coin_reward_log.summary IS
    '格式示例：{"综合榜":{"人次":8,"币":480},...}';

-- 允许前端只读查询（管理员页面可展示历史结算记录）
GRANT SELECT ON public.weekly_coin_reward_log TO anon, authenticated;

-- ============================================================
-- 2.1 结算明细表（审计增强）
--     记录每周每个榜单每位学生的实际发放明细，便于事后核对
-- ============================================================
CREATE TABLE IF NOT EXISTS public.weekly_coin_reward_detail (
    id                   UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    week_monday          DATE         NOT NULL,
    board                TEXT         NOT NULL,      -- 综合榜 / 进步榜 / 稳定榜 / 守则榜
    rank_no              INTEGER      NOT NULL,
    student_name         TEXT         NOT NULL,
    amount               INTEGER      NOT NULL,      -- 本笔发放音符币
    reason               TEXT         NOT NULL,      -- 实际写入 coin_transactions 的 reason
    display_score        NUMERIC,
    alpha                NUMERIC,
    trend_score          NUMERIC,
    recent10_outlier_rate NUMERIC,
    rewarded_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_weekly_coin_reward_detail
      UNIQUE (week_monday, board, rank_no, student_name)
);

COMMENT ON TABLE public.weekly_coin_reward_detail IS
    '周榜自动结算逐笔明细（每周/榜单/名次/学生唯一），用于发币准确性审计';

CREATE INDEX IF NOT EXISTS idx_weekly_coin_reward_detail_week
    ON public.weekly_coin_reward_detail (week_monday, board, rank_no);

CREATE INDEX IF NOT EXISTS idx_weekly_coin_reward_detail_student
    ON public.weekly_coin_reward_detail (student_name, week_monday DESC);

GRANT SELECT ON public.weekly_coin_reward_detail TO anon, authenticated;


-- ============================================================
-- 2. 核心结算函数
-- ============================================================
CREATE OR REPLACE FUNCTION public.reward_weekly_coins()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    /* ── 时间变量 ── */
    v_monday      DATE;       -- 本周一（北京时间）
    v_friday_bjt  DATE;       -- 本周五（北京时间），用于开始日期保护
    v_week_label  TEXT;       -- 流水说明前缀，如 "2026年04月03日当周"

    /* ── 循环变量 ── */
    r             RECORD;
    v_amount      INTEGER;
    v_reason      TEXT;
    v_title       TEXT;       -- 综合榜专属称号

    /* ── 汇总统计 ── */
    v_total_events  INTEGER := 0;
    v_total_coins   INTEGER := 0;
    -- 各榜统计（人次 / 音符币）
    v_comp_cnt      INTEGER := 0;  v_comp_coins    INTEGER := 0;
    v_stable_cnt    INTEGER := 0;  v_stable_coins  INTEGER := 0;
    v_rules_cnt     INTEGER := 0;  v_rules_coins   INTEGER := 0;
    v_prog_cnt      INTEGER := 0;  v_prog_coins    INTEGER := 0;
BEGIN

    /* ── ① 检查自动结算开关（管理员可在后台关闭）── */
    IF NOT COALESCE(
        (SELECT value::BOOLEAN FROM public.system_settings
         WHERE key = 'auto_coin_reward_enabled'),
        TRUE
    ) THEN
        RETURN '🔴 自动结算已关闭（管理员已在后台禁用），本次跳过。';
    END IF;

    /* ── ② 计算本周时间 ── */
    v_monday     := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
    v_friday_bjt := v_monday + 4;   -- 周一 + 4 天 = 周五

    /* ── ③ 正式开始日期保护：2026-03-27 之前不运行 ── */
    IF v_friday_bjt < '2026-03-27'::DATE THEN
        RETURN '⏳ 正式结算日期为 2026年3月27日，当前周五为 '
               || TO_CHAR(v_friday_bjt, 'YYYY年MM月DD日') || '，跳过。';
    END IF;

    /* ── ④ 防重复：同一周只结算一次 ── */
    IF EXISTS (
        SELECT 1 FROM public.weekly_coin_reward_log
        WHERE week_monday = v_monday
    ) THEN
        RETURN '⚠️ ' || v_monday::TEXT
               || ' 当周已结算，跳过（如需重新结算，先 DELETE FROM weekly_coin_reward_log WHERE week_monday = '''
               || v_monday::TEXT || ''';）';
    END IF;

    -- 审计安全网：若周汇总被误删但明细仍在，仍视为已结算，阻止重复发币
    IF EXISTS (
        SELECT 1 FROM public.weekly_coin_reward_detail
        WHERE week_monday = v_monday
    ) THEN
        RETURN '⚠️ ' || v_monday::TEXT
               || ' 当周结算明细已存在，判定为已结算。'
               || ' 如确需重算，请先核对并回滚相关 auto_reward 流水，再清理 weekly_coin_reward_log + weekly_coin_reward_detail。';
    END IF;

    /* ── ⑤ 生成流水说明中的周标签，例如 "2026年04月03日当周" ── */
    v_week_label := TO_CHAR(v_friday_bjt, 'YYYY年MM月DD日') || '当周';

    /* ── ⑥ 遍历四榜所有上榜学生，逐一发币 ── */
    FOR r IN
        SELECT
            board,
            rank_no,
            student_name,
            display_score,
            alpha,
            trend_score,
            recent10_outlier_rate
        FROM public.get_weekly_leaderboards()
        ORDER BY board, rank_no
    LOOP
        v_amount := 0;
        v_reason := NULL;
        v_title  := NULL;

        /* ─── 综合榜 ─────────────────────────────────────── */
        IF r.board = '综合榜' THEN
            IF    r.rank_no = 1                   THEN v_amount := 100; v_title := '榜首霸主';
            ELSIF r.rank_no BETWEEN 2 AND  3      THEN v_amount :=  80; v_title := '荣耀亚军';
            ELSIF r.rank_no BETWEEN 4 AND  6      THEN v_amount :=  60; v_title := '实力季军';
            ELSIF r.rank_no BETWEEN 7 AND 10      THEN v_amount :=  40; v_title := '优秀达人';
            END IF;
            IF v_amount > 0 THEN
                v_reason := '【周榜结算】' || v_week_label
                    || ' · 综合榜第' || r.rank_no || '名（' || v_title || '）'
                    || '· 综合分 ' || ROUND(r.display_score, 1)::TEXT || ' 分';
                v_comp_cnt   := v_comp_cnt   + 1;
                v_comp_coins := v_comp_coins + v_amount;
            END IF;

        /* ─── 稳定榜 ─────────────────────────────────────── */
        ELSIF r.board = '稳定榜' THEN
            IF    r.rank_no = 1              THEN v_amount := 50;
            ELSIF r.rank_no BETWEEN 2 AND 3  THEN v_amount := 35;
            ELSIF r.rank_no BETWEEN 4 AND 6  THEN v_amount := 20;
            END IF;
            IF v_amount > 0 THEN
                v_reason := '【周榜结算】' || v_week_label
                    || ' · 稳定榜第' || r.rank_no || '名'
                    || ' · α 可信度 ' || ROUND(COALESCE(r.alpha, 0), 3)::TEXT;
                v_stable_cnt   := v_stable_cnt   + 1;
                v_stable_coins := v_stable_coins + v_amount;
            END IF;

        /* ─── 守则榜 ─────────────────────────────────────── */
        ELSIF r.board = '守则榜' THEN
            IF    r.rank_no = 1              THEN v_amount := 45;
            ELSIF r.rank_no BETWEEN 2 AND 3  THEN v_amount := 30;
            ELSIF r.rank_no BETWEEN 4 AND 6  THEN v_amount := 18;
            END IF;
            IF v_amount > 0 THEN
                v_reason := '【周榜结算】' || v_week_label
                    || ' · 守则榜第' || r.rank_no || '名'
                    || ' · 近10次异常率 '
                    || ROUND(COALESCE(r.recent10_outlier_rate, 0) * 100, 1)::TEXT || '%';
                v_rules_cnt   := v_rules_cnt   + 1;
                v_rules_coins := v_rules_coins + v_amount;
            END IF;

        /* ─── 进步榜 ─────────────────────────────────────── */
        --   trend_score 此处复用为 delta 整数（本周综合分 − 上周综合分）
        ELSIF r.board = '进步榜' THEN
            IF    r.rank_no = 1              THEN v_amount := 40;
            ELSIF r.rank_no BETWEEN 2 AND 3  THEN v_amount := 25;
            ELSIF r.rank_no BETWEEN 4 AND 6  THEN v_amount := 15;
            END IF;
            IF v_amount > 0 THEN
                v_reason := '【周榜结算】' || v_week_label
                    || ' · 进步榜第' || r.rank_no || '名'
                    || ' · 本周进步 +' || ROUND(COALESCE(r.trend_score, 0))::TEXT || ' 分';
                v_prog_cnt   := v_prog_cnt   + 1;
                v_prog_coins := v_prog_coins + v_amount;
            END IF;

        END IF; -- board 判断结束

        /* ── 调用原子写入函数：更新余额 + 插入流水 ── */
        IF v_amount > 0 AND v_reason IS NOT NULL THEN
            PERFORM public.adjust_student_coins(
                p_student_name := r.student_name,
                p_amount       := v_amount,
                p_reason       := v_reason,
                p_type         := 'auto_reward'
            );

            INSERT INTO public.weekly_coin_reward_detail (
                week_monday,
                board,
                rank_no,
                student_name,
                amount,
                reason,
                display_score,
                alpha,
                trend_score,
                recent10_outlier_rate
            )
            VALUES (
                v_monday,
                r.board,
                r.rank_no,
                r.student_name,
                v_amount,
                v_reason,
                r.display_score,
                r.alpha,
                r.trend_score,
                r.recent10_outlier_rate
            );

            v_total_events := v_total_events + 1;
            v_total_coins  := v_total_coins  + v_amount;
        END IF;

    END LOOP; -- 遍历榜单结束

    /* ── ⑦ 写入本周结算记录（防止下次重复执行）── */
    INSERT INTO public.weekly_coin_reward_log
        (week_monday, total_events, total_coins, summary)
    VALUES (
        v_monday,
        v_total_events,
        v_total_coins,
        jsonb_build_object(
            '综合榜', jsonb_build_object('人次', v_comp_cnt,   '币', v_comp_coins),
            '稳定榜', jsonb_build_object('人次', v_stable_cnt, '币', v_stable_coins),
            '守则榜', jsonb_build_object('人次', v_rules_cnt,  '币', v_rules_coins),
            '进步榜', jsonb_build_object('人次', v_prog_cnt,   '币', v_prog_coins)
        )
    );

    /* ── ⑧ 返回本次结算摘要 ── */
    RETURN '✅ ' || v_week_label || ' 周榜结算完成'
        || ' | 总计 ' || v_total_events::TEXT || ' 次发放，共 ' || v_total_coins::TEXT || ' 枚音符币'
        || ' | 综合榜 ' || v_comp_cnt::TEXT   || '人/' || v_comp_coins::TEXT   || '币'
        || ' · 稳定榜 ' || v_stable_cnt::TEXT  || '人/' || v_stable_coins::TEXT  || '币'
        || ' · 守则榜 ' || v_rules_cnt::TEXT   || '人/' || v_rules_coins::TEXT   || '币'
        || ' · 进步榜 ' || v_prog_cnt::TEXT    || '人/' || v_prog_coins::TEXT    || '币';

END;
$$;

COMMENT ON FUNCTION public.reward_weekly_coins() IS
    '每周五 BJT 21:32 自动结算四榜音符币。
     防重复：UNIQUE(week_monday) 保证同一周只发一次。
     开始日期：2026-03-27。
     流水 p_type 固定为 auto_reward（前端显示"系统结算"紫色标签）。';

REVOKE EXECUTE ON FUNCTION public.reward_weekly_coins() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reward_weekly_coins() TO service_role;


-- ============================================================
-- 3. pg_cron 定时任务
--    北京时间 每周五 21:32 = UTC 每周五 13:32
--    注意：backup_weekly_leaderboards_job 在 21:30（UTC 13:30）运行，
--          本任务在 21:32（UTC 13:32）运行，两者互相独立，
--          reward_weekly_coins() 内部直接调用 get_weekly_leaderboards()
--          而非读备份表，所以两分钟差异不影响正确性。
-- ============================================================
CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
BEGIN
    -- 先删除旧任务（如有），避免重复注册
    PERFORM cron.unschedule('reward_weekly_coins_job');
EXCEPTION WHEN OTHERS THEN
    NULL; -- 任务不存在时报错，直接忽略
END;
$$;

SELECT cron.schedule(
    'reward_weekly_coins_job',   -- 任务名
    '32 13 * * 5',               -- UTC 每周五 13:32 = BJT 每周五 21:32
    $$SELECT public.reward_weekly_coins();$$
);


-- ============================================================
-- 4. 常用管理命令（注释，需要时手动执行）
-- ============================================================

-- 查看任务注册状态：
-- SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'reward_weekly_coins_job';

-- 查看最近执行日志（pg_cron >= 1.4）：
-- SELECT * FROM cron.job_run_details WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'reward_weekly_coins_job') ORDER BY start_time DESC LIMIT 10;

-- 手动触发一次（测试或补发）：
-- SELECT public.reward_weekly_coins();

-- 查看历次结算记录：
-- SELECT week_monday, rewarded_at, total_events, total_coins, summary FROM public.weekly_coin_reward_log ORDER BY week_monday DESC;

-- 删除某周结算记录（谨慎；仅删除 log/detail 不会自动回滚已发流水）：
-- DELETE FROM public.weekly_coin_reward_log    WHERE week_monday = '2026-03-30';
-- DELETE FROM public.weekly_coin_reward_detail WHERE week_monday = '2026-03-30';

-- 暂停/恢复任务（不删除）：
-- UPDATE cron.job SET active = false WHERE jobname = 'reward_weekly_coins_job';
-- UPDATE cron.job SET active = true  WHERE jobname = 'reward_weekly_coins_job';

-- 取消任务：
-- SELECT cron.unschedule('reward_weekly_coins_job');
