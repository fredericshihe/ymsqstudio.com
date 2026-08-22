-- 大幅下调进步榜 / 稳定榜 / 守则榜的音符币周榜奖励，综合榜金额不变。
--
-- 调整前 → 调整后（第1名 / 第2–3名 / 第4–6名）：
--   稳定榜  50 / 35 / 20  →  12 / 9 / 5
--   守则榜  45 / 30 / 18  →  11 / 8 / 5
--   进步榜  40 / 25 / 15  →  10 / 6 / 4
--   综合榜 100 / 80 / 60 / 40（不变）

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

        /* ─── 综合榜（不变）─────────────────────────────── */
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

        /* ─── 稳定榜（下调：50/35/20 → 12/9/5）───────────── */
        ELSIF r.board = '稳定榜' THEN
            IF    r.rank_no = 1              THEN v_amount := 12;
            ELSIF r.rank_no BETWEEN 2 AND 3  THEN v_amount :=  9;
            ELSIF r.rank_no BETWEEN 4 AND 6  THEN v_amount :=  5;
            END IF;
            IF v_amount > 0 THEN
                v_reason := '【周榜结算】' || v_week_label
                    || ' · 稳定榜第' || r.rank_no || '名'
                    || ' · α 可信度 ' || ROUND(COALESCE(r.alpha, 0), 3)::TEXT;
                v_stable_cnt   := v_stable_cnt   + 1;
                v_stable_coins := v_stable_coins + v_amount;
            END IF;

        /* ─── 守则榜（下调：45/30/18 → 11/8/5）───────────── */
        ELSIF r.board = '守则榜' THEN
            IF    r.rank_no = 1              THEN v_amount := 11;
            ELSIF r.rank_no BETWEEN 2 AND 3  THEN v_amount :=  8;
            ELSIF r.rank_no BETWEEN 4 AND 6  THEN v_amount :=  5;
            END IF;
            IF v_amount > 0 THEN
                v_reason := '【周榜结算】' || v_week_label
                    || ' · 守则榜第' || r.rank_no || '名'
                    || ' · 近10次异常率 '
                    || ROUND(COALESCE(r.recent10_outlier_rate, 0) * 100, 1)::TEXT || '%';
                v_rules_cnt   := v_rules_cnt   + 1;
                v_rules_coins := v_rules_coins + v_amount;
            END IF;

        /* ─── 进步榜（下调：40/25/15 → 10/6/4）───────────── */
        --   trend_score 此处复用为 delta 整数（本周综合分 − 上周综合分）
        ELSIF r.board = '进步榜' THEN
            IF    r.rank_no = 1              THEN v_amount := 10;
            ELSIF r.rank_no BETWEEN 2 AND 3  THEN v_amount :=  6;
            ELSIF r.rank_no BETWEEN 4 AND 6  THEN v_amount :=  4;
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
     2026-08-22起：进步/稳定/守则榜奖励大幅下调，综合榜不变。
     防重复：UNIQUE(week_monday) 保证同一周只发一次。
     开始日期：2026-03-27。
     流水 p_type 固定为 auto_reward（前端显示"系统结算"紫色标签）。';

REVOKE EXECUTE ON FUNCTION public.reward_weekly_coins() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reward_weekly_coins() TO service_role;
