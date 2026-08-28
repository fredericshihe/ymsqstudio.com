BEGIN;

-- 系统自动扣币与手动扣币分开记账；余额允许直接降为负数。
CREATE OR REPLACE FUNCTION public.adjust_student_coins(
    p_student_name TEXT,
    p_amount       INTEGER,
    p_reason       TEXT,
    p_type         TEXT DEFAULT 'compensation'
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
    v_current_balance INTEGER;
    v_new_balance INTEGER;
    v_new_semester_earned INTEGER;
BEGIN
    IF p_type NOT IN ('auto_reward', 'auto_penalty', 'compensation', 'deduction', 'redemption') THEN
        RAISE EXCEPTION '不支持的 p_type: %', p_type;
    END IF;

    IF p_type IN ('auto_reward', 'compensation') AND p_amount <= 0 THEN
        RAISE EXCEPTION '类型 % 的 p_amount 必须为正数', p_type;
    END IF;

    IF p_type IN ('auto_penalty', 'deduction', 'redemption') AND p_amount >= 0 THEN
        RAISE EXCEPTION '类型 % 的 p_amount 必须为负数', p_type;
    END IF;

    INSERT INTO public.student_coins (student_name, balance, semester_earned)
    VALUES (p_student_name, 0, 0)
    ON CONFLICT (student_name) DO NOTHING;

    SELECT balance, semester_earned
    INTO v_current_balance, v_new_semester_earned
    FROM public.student_coins
    WHERE student_name = p_student_name
    FOR UPDATE;

    v_new_balance := v_current_balance + p_amount;
    v_new_semester_earned := CASE
        WHEN p_type IN ('auto_reward', 'compensation')
            THEN v_new_semester_earned + p_amount
        WHEN p_type IN ('auto_penalty', 'deduction')
            THEN GREATEST(0, v_new_semester_earned + p_amount)
        ELSE v_new_semester_earned
    END;

    UPDATE public.student_coins
    SET balance = v_new_balance,
        semester_earned = v_new_semester_earned,
        updated_at = NOW()
    WHERE student_name = p_student_name;

    INSERT INTO public.coin_transactions
        (student_name, amount, balance_after, reason, transaction_type)
    VALUES
        (p_student_name, p_amount, v_new_balance, p_reason, p_type);

    RETURN v_new_balance;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.adjust_student_coins(TEXT, INTEGER, TEXT, TEXT) TO anon, authenticated;

-- 四个正向榜单只认 student_database 中未归档学生，姓名、专业、年级也以学生库为准。
CREATE OR REPLACE FUNCTION public.get_weekly_leaderboards()
RETURNS TABLE (
    board                 TEXT,
    rank_no               INTEGER,
    student_name          TEXT,
    student_major         TEXT,
    student_grade         TEXT,
    display_score         NUMERIC,
    alpha                 NUMERIC,
    trend_score           NUMERIC,
    mean_duration         NUMERIC,
    record_count          INTEGER,
    recent10_outlier_rate NUMERIC,
    recent10_mean_dur     NUMERIC,
    recent10_count        INTEGER
)
LANGUAGE SQL
STABLE
SET search_path = public
AS $function$
WITH
week_monday AS (
    SELECT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS monday
),
current_students AS (
    SELECT DISTINCT ON (sd.name)
        sd.name AS student_name,
        NULLIF(BTRIM(sd.major), '') AS student_major,
        NULLIF(BTRIM(sd.grade), '') AS student_grade
    FROM public.student_database sd
    WHERE COALESCE(sd.archived, FALSE) IS FALSE
      AND NULLIF(BTRIM(sd.name), '') IS NOT NULL
    ORDER BY sd.name, sd.updated_at DESC NULLS LAST, sd.id DESC
),
recent20 AS (
    SELECT
        student_name,
        COUNT(*)::INTEGER AS cnt,
        ROUND(AVG((is_outlier)::INT)::NUMERIC, 4) AS outlier_rate,
        ROUND(AVG(cleaned_duration)::NUMERIC, 2) AS mean_dur
    FROM (
        SELECT
            student_name,
            is_outlier,
            cleaned_duration,
            ROW_NUMBER() OVER (PARTITION BY student_name ORDER BY session_start DESC) AS rn
        FROM public.practice_sessions
        WHERE cleaned_duration > 0
          AND session_start >= NOW() - INTERVAL '12 weeks'
          AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    ) sub
    WHERE rn <= 20
    GROUP BY student_name
),
week_cnt AS (
    SELECT
        student_name,
        COUNT(*)::INTEGER AS cnt
    FROM public.practice_sessions
    CROSS JOIN week_monday
    WHERE session_start >= ((monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    GROUP BY student_name
),
week_scores AS (
    SELECT
        ssh.student_name,
        ssh.composite_score,
        ssh.raw_score,
        ssh.trend_score,
        ssh.baseline_score,
        ssh.mean_duration,
        ssh.record_count::INTEGER,
        ssh.outlier_rate
    FROM public.student_score_history ssh
    CROSS JOIN week_monday wm
    WHERE ssh.snapshot_date = wm.monday
      AND ssh.composite_score > 0
),
last_week_scores AS (
    SELECT student_name, MAX(composite_score) AS lw_composite
    FROM (
        SELECT
            ssh.student_name,
            ssh.composite_score,
            ROW_NUMBER() OVER (
                PARTITION BY ssh.student_name
                ORDER BY ssh.snapshot_date DESC
            ) AS rn
        FROM public.student_score_history ssh
        CROSS JOIN week_monday wm
        WHERE ssh.snapshot_date < wm.monday
          AND ssh.snapshot_date >= wm.monday - INTERVAL '12 weeks'
          AND ssh.composite_score > 0
    ) recent
    WHERE rn <= 2
    GROUP BY student_name
),
ranked_pool AS (
    SELECT
        wc.student_name,
        COALESCE(cs.student_major, sb.student_major) AS student_major,
        COALESCE(cs.student_grade, sb.student_grade) AS student_grade,
        COALESCE(ws.composite_score, sb.composite_score) AS display_score,
        sb.alpha,
        ws.trend_score,
        COALESCE(ws.mean_duration, sb.mean_duration) AS mean_duration,
        COALESCE(ws.record_count, sb.record_count)::INTEGER AS record_count,
        wc.cnt AS week_sessions
    FROM week_cnt wc
    JOIN current_students cs ON cs.student_name = wc.student_name
    JOIN public.student_baseline sb ON sb.student_name = wc.student_name
    LEFT JOIN week_scores ws ON ws.student_name = wc.student_name
    WHERE COALESCE(ws.composite_score, sb.composite_score, 0) > 0
),
comp AS (
    SELECT
        '综合榜'::TEXT AS board,
        RANK() OVER (
            ORDER BY rp.display_score DESC NULLS LAST,
                     rp.mean_duration DESC NULLS LAST,
                     rp.record_count DESC NULLS LAST
        )::INTEGER AS rank_no,
        rp.student_name, rp.student_major, rp.student_grade,
        rp.display_score, rp.alpha, rp.trend_score, rp.mean_duration, rp.record_count,
        r20.outlier_rate AS recent10_outlier_rate,
        r20.mean_dur AS recent10_mean_dur,
        r20.cnt AS recent10_count
    FROM ranked_pool rp
    LEFT JOIN recent20 r20 ON r20.student_name = rp.student_name
),
comp_top10 AS (
    SELECT student_name FROM comp WHERE rank_no <= 10
),
prog AS (
    SELECT
        '进步榜'::TEXT AS board,
        RANK() OVER (
            ORDER BY (rp.display_score - lws.lw_composite) DESC NULLS LAST,
                     rp.display_score DESC NULLS LAST,
                     rp.mean_duration DESC NULLS LAST
        )::INTEGER AS rank_no,
        rp.student_name, rp.student_major, rp.student_grade,
        rp.display_score, rp.alpha,
        ROUND((rp.display_score - lws.lw_composite)::NUMERIC, 1) AS trend_score,
        rp.mean_duration, rp.record_count,
        r20.outlier_rate AS recent10_outlier_rate,
        r20.mean_dur AS recent10_mean_dur,
        r20.cnt AS recent10_count
    FROM ranked_pool rp
    INNER JOIN last_week_scores lws ON lws.student_name = rp.student_name
    LEFT JOIN recent20 r20 ON r20.student_name = rp.student_name
    WHERE (rp.display_score - lws.lw_composite) >= 1.0
      AND rp.week_sessions >= 2
      AND COALESCE(r20.cnt, 0) >= 4
      AND COALESCE(r20.outlier_rate, 1) <= 0.20
      AND rp.student_name NOT IN (SELECT student_name FROM comp_top10)
),
stable AS (
    SELECT
        '稳定榜'::TEXT AS board,
        RANK() OVER (
            ORDER BY COALESCE(r20.mean_dur, 0) DESC NULLS LAST,
                     rp.alpha DESC NULLS LAST,
                     COALESCE(r20.outlier_rate, 1) ASC
        )::INTEGER AS rank_no,
        rp.student_name, rp.student_major, rp.student_grade,
        rp.display_score, rp.alpha, rp.trend_score, rp.mean_duration, rp.record_count,
        r20.outlier_rate AS recent10_outlier_rate,
        r20.mean_dur AS recent10_mean_dur,
        r20.cnt AS recent10_count
    FROM ranked_pool rp
    LEFT JOIN recent20 r20 ON r20.student_name = rp.student_name
    WHERE COALESCE(rp.alpha, 0) >= 0.60
      AND COALESCE(r20.cnt, 0) >= 8
      AND COALESCE(r20.outlier_rate, 1) <= 0.20
      AND COALESCE(r20.mean_dur, 0) >= 30
      AND rp.student_name NOT IN (SELECT student_name FROM comp_top10)
),
rules AS (
    SELECT
        '守则榜'::TEXT AS board,
        RANK() OVER (
            ORDER BY COALESCE(r20.outlier_rate, 1) ASC,
                     rp.week_sessions DESC NULLS LAST,
                     COALESCE(r20.mean_dur, 0) DESC
        )::INTEGER AS rank_no,
        rp.student_name, rp.student_major, rp.student_grade,
        rp.display_score, rp.alpha, rp.trend_score, rp.mean_duration, rp.record_count,
        r20.outlier_rate AS recent10_outlier_rate,
        r20.mean_dur AS recent10_mean_dur,
        r20.cnt AS recent10_count
    FROM ranked_pool rp
    LEFT JOIN recent20 r20 ON r20.student_name = rp.student_name
    WHERE rp.week_sessions >= 3
      AND COALESCE(r20.cnt, 0) >= 5
      AND COALESCE(r20.mean_dur, 0) >= 30
      AND COALESCE(r20.outlier_rate, 1) <= 0.20
      AND COALESCE(rp.alpha, 0) >= 0.60
      AND rp.student_name NOT IN (SELECT student_name FROM comp_top10)
)
SELECT board, rank_no, student_name, student_major, student_grade,
       display_score, alpha, trend_score, mean_duration, record_count,
       recent10_outlier_rate, recent10_mean_dur, recent10_count
FROM comp
UNION ALL
SELECT board, rank_no, student_name, student_major, student_grade,
       display_score, alpha, trend_score, mean_duration, record_count,
       recent10_outlier_rate, recent10_mean_dur, recent10_count
FROM prog
UNION ALL
SELECT board, rank_no, student_name, student_major, student_grade,
       display_score, alpha, trend_score, mean_duration, record_count,
       recent10_outlier_rate, recent10_mean_dur, recent10_count
FROM stable
UNION ALL
SELECT board, rank_no, student_name, student_major, student_grade,
       display_score, alpha, trend_score, mean_duration, record_count,
       recent10_outlier_rate, recent10_mean_dur, recent10_count
FROM rules
ORDER BY board, rank_no;
$function$;

GRANT EXECUTE ON FUNCTION public.get_weekly_leaderboards() TO anon, authenticated;

-- 正向奖励与缩水榜扣币在同一事务、同一总开关、同一防重复记录下结算。
CREATE OR REPLACE FUNCTION public.reward_weekly_coins()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
    v_monday      DATE;
    v_friday_bjt  DATE;
    v_week_label  TEXT;
    r             RECORD;
    v_amount      INTEGER;
    v_reason      TEXT;
    v_title       TEXT;
    v_total_events     INTEGER := 0;
    v_reward_coins     INTEGER := 0;
    v_penalty_coins    INTEGER := 0;
    v_net_coins        INTEGER := 0;
    v_comp_cnt         INTEGER := 0;  v_comp_coins   INTEGER := 0;
    v_stable_cnt       INTEGER := 0;  v_stable_coins INTEGER := 0;
    v_rules_cnt        INTEGER := 0;  v_rules_coins  INTEGER := 0;
    v_prog_cnt         INTEGER := 0;  v_prog_coins   INTEGER := 0;
    v_shrink_cnt       INTEGER := 0;
BEGIN
    IF NOT COALESCE(
        (SELECT value::BOOLEAN
         FROM public.system_settings
         WHERE key = 'auto_coin_reward_enabled'),
        TRUE
    ) THEN
        RETURN '🔴 自动音符币结算已关闭，本次奖励与缩水榜扣币均跳过。';
    END IF;

    v_monday := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
    v_friday_bjt := v_monday + 4;

    IF v_friday_bjt < '2026-03-27'::DATE THEN
        RETURN '⏳ 正式结算日期为 2026年3月27日，当前周五为 '
               || TO_CHAR(v_friday_bjt, 'YYYY年MM月DD日') || '，跳过。';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.weekly_coin_reward_log WHERE week_monday = v_monday
    ) THEN
        RETURN '⚠️ ' || v_monday::TEXT || ' 当周已结算，跳过。';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.weekly_coin_reward_detail WHERE week_monday = v_monday
    ) THEN
        RETURN '⚠️ ' || v_monday::TEXT || ' 当周结算明细已存在，判定为已结算。';
    END IF;

    v_week_label := TO_CHAR(v_friday_bjt, 'YYYY年MM月DD日') || '当周';

    FOR r IN
        SELECT
            board, rank_no, student_name, display_score,
            alpha, trend_score, recent10_outlier_rate
        FROM public.get_weekly_leaderboards()
        ORDER BY board, rank_no
    LOOP
        v_amount := 0;
        v_reason := NULL;
        v_title := NULL;

        IF r.board = '综合榜' THEN
            IF r.rank_no = 1 THEN v_amount := 80; v_title := '榜首霸主';
            ELSIF r.rank_no BETWEEN 2 AND 3 THEN v_amount := 64; v_title := '荣耀亚军';
            ELSIF r.rank_no BETWEEN 4 AND 6 THEN v_amount := 48; v_title := '实力季军';
            ELSIF r.rank_no BETWEEN 7 AND 10 THEN v_amount := 32; v_title := '优秀达人';
            END IF;
            IF v_amount > 0 THEN
                v_reason := '【周榜结算】' || v_week_label
                    || ' · 综合榜第' || r.rank_no || '名（' || v_title || '）'
                    || ' · 综合分 ' || ROUND(r.display_score, 1)::TEXT || ' 分';
                v_comp_cnt := v_comp_cnt + 1;
                v_comp_coins := v_comp_coins + v_amount;
            END IF;
        ELSIF r.board = '稳定榜' THEN
            IF r.rank_no = 1 THEN v_amount := 12;
            ELSIF r.rank_no BETWEEN 2 AND 3 THEN v_amount := 9;
            ELSIF r.rank_no BETWEEN 4 AND 6 THEN v_amount := 5;
            END IF;
            IF v_amount > 0 THEN
                v_reason := '【周榜结算】' || v_week_label
                    || ' · 稳定榜第' || r.rank_no || '名'
                    || ' · α 可信度 ' || ROUND(COALESCE(r.alpha, 0), 3)::TEXT;
                v_stable_cnt := v_stable_cnt + 1;
                v_stable_coins := v_stable_coins + v_amount;
            END IF;
        ELSIF r.board = '守则榜' THEN
            IF r.rank_no = 1 THEN v_amount := 11;
            ELSIF r.rank_no BETWEEN 2 AND 3 THEN v_amount := 8;
            ELSIF r.rank_no BETWEEN 4 AND 6 THEN v_amount := 5;
            END IF;
            IF v_amount > 0 THEN
                v_reason := '【周榜结算】' || v_week_label
                    || ' · 守则榜第' || r.rank_no || '名'
                    || ' · 近10次异常率 '
                    || ROUND(COALESCE(r.recent10_outlier_rate, 0) * 100, 1)::TEXT || '%';
                v_rules_cnt := v_rules_cnt + 1;
                v_rules_coins := v_rules_coins + v_amount;
            END IF;
        ELSIF r.board = '进步榜' THEN
            IF r.rank_no = 1 THEN v_amount := 10;
            ELSIF r.rank_no BETWEEN 2 AND 3 THEN v_amount := 6;
            ELSIF r.rank_no BETWEEN 4 AND 6 THEN v_amount := 4;
            END IF;
            IF v_amount > 0 THEN
                v_reason := '【周榜结算】' || v_week_label
                    || ' · 进步榜第' || r.rank_no || '名'
                    || ' · 本周进步 +' || ROUND(COALESCE(r.trend_score, 0))::TEXT || ' 分';
                v_prog_cnt := v_prog_cnt + 1;
                v_prog_coins := v_prog_coins + v_amount;
            END IF;
        END IF;

        IF v_amount > 0 AND v_reason IS NOT NULL THEN
            PERFORM public.adjust_student_coins(
                p_student_name := r.student_name,
                p_amount := v_amount,
                p_reason := v_reason,
                p_type := 'auto_reward'
            );

            INSERT INTO public.weekly_coin_reward_detail (
                week_monday, board, rank_no, student_name, amount, reason,
                display_score, alpha, trend_score, recent10_outlier_rate
            ) VALUES (
                v_monday, r.board, r.rank_no, r.student_name, v_amount, v_reason,
                r.display_score, r.alpha, r.trend_score, r.recent10_outlier_rate
            );

            v_total_events := v_total_events + 1;
            v_reward_coins := v_reward_coins + v_amount;
            v_net_coins := v_net_coins + v_amount;
        END IF;
    END LOOP;

    FOR r IN
        SELECT
            board, rank_no, student_name, display_score,
            completed_minutes, completion_ratio, shortfall_minutes
        FROM public.get_weekly_decline_leaderboard(v_monday)
        WHERE rank_no <= 6
        ORDER BY rank_no
    LOOP
        IF r.rank_no = 1 THEN v_amount := -10;
        ELSIF r.rank_no BETWEEN 2 AND 3 THEN v_amount := -6;
        ELSIF r.rank_no BETWEEN 4 AND 6 THEN v_amount := -4;
        ELSE v_amount := 0;
        END IF;

        IF v_amount < 0 THEN
            v_reason := '【周榜结算】' || v_week_label
                || ' · 缩水榜第' || r.rank_no || '名'
                || ' · 当前应完成进度 '
                || ROUND(COALESCE(r.completion_ratio, 0) * 100, 1)::TEXT || '%'
                || ' · 本周累计 ' || ROUND(COALESCE(r.completed_minutes, 0), 0)::TEXT || ' 分钟'
                || ' · 当前还差 ' || ROUND(COALESCE(r.shortfall_minutes, 0), 0)::TEXT || ' 分钟';

            PERFORM public.adjust_student_coins(
                p_student_name := r.student_name,
                p_amount := v_amount,
                p_reason := v_reason,
                p_type := 'auto_penalty'
            );

            INSERT INTO public.weekly_coin_reward_detail (
                week_monday, board, rank_no, student_name, amount, reason, display_score
            ) VALUES (
                v_monday, r.board, r.rank_no, r.student_name, v_amount, v_reason, r.display_score
            );

            v_total_events := v_total_events + 1;
            v_penalty_coins := v_penalty_coins + ABS(v_amount);
            v_net_coins := v_net_coins + v_amount;
            v_shrink_cnt := v_shrink_cnt + 1;
        END IF;
    END LOOP;

    INSERT INTO public.weekly_coin_reward_log
        (week_monday, total_events, total_coins, summary)
    VALUES (
        v_monday,
        v_total_events,
        v_net_coins,
        jsonb_build_object(
            '综合榜', jsonb_build_object('人次', v_comp_cnt, '币', v_comp_coins),
            '稳定榜', jsonb_build_object('人次', v_stable_cnt, '币', v_stable_coins),
            '守则榜', jsonb_build_object('人次', v_rules_cnt, '币', v_rules_coins),
            '进步榜', jsonb_build_object('人次', v_prog_cnt, '币', v_prog_coins),
            '缩水榜', jsonb_build_object('人次', v_shrink_cnt, '币', -v_penalty_coins),
            '奖励合计', v_reward_coins,
            '扣币合计', v_penalty_coins,
            '净变化', v_net_coins
        )
    );

    RETURN '✅ ' || v_week_label || ' 音符币结算完成'
        || ' | 奖励 ' || v_reward_coins::TEXT || ' 枚'
        || ' · 缩水榜扣除 ' || v_penalty_coins::TEXT || ' 枚'
        || ' · 净变化 ' || v_net_coins::TEXT || ' 枚'
        || ' | 共 ' || v_total_events::TEXT || ' 笔';
END;
$function$;

COMMENT ON FUNCTION public.reward_weekly_coins() IS
    '每周五自动结算音符币：四个正向榜单发放，缩水榜前6名按进步榜同名次额度扣除。奖励与扣币共同受 auto_coin_reward_enabled 控制；余额允许为负数。';

COMMENT ON COLUMN public.weekly_coin_reward_log.total_coins IS
    '本周自动结算音符币净变化：正向榜奖励减去缩水榜扣币';

COMMENT ON COLUMN public.weekly_coin_reward_detail.amount IS
    '本笔自动结算金额：正数为榜单奖励，负数为缩水榜扣币';

REVOKE EXECUTE ON FUNCTION public.reward_weekly_coins() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reward_weekly_coins() TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
