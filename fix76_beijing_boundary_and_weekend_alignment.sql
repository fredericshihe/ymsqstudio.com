-- ============================================================
-- FIX-76：北京时间边界修正 + 周末榜单口径统一
--
-- 解决的问题：
-- 1. DATE::TIMESTAMPTZ 在 UTC 会话下会把周边界整体偏移 8 小时
-- 2. 排行榜资格（week_cnt / recent10）此前仍把周末记录算进去
-- 3. compute_baseline / compute_baseline_as_of 的日期截止点未显式使用北京时间
--
-- 本文件一次性更新 5 个函数：
--   public.get_weekly_leaderboards()
--   public.compute_baseline_as_of(TEXT, DATE)
--   public.compute_baseline(TEXT)
--   public.backfill_score_history()
--   public.run_weekly_score_update()
--
-- 部署后必须执行：
--   SELECT public.backfill_score_history();
-- ============================================================

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
AS $$
WITH
week_monday AS (
    SELECT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS monday
),
recent10 AS (
    SELECT
        student_name,
        COUNT(*)::INTEGER                          AS cnt,
        ROUND(AVG((is_outlier)::INT)::NUMERIC, 4) AS outlier_rate,
        ROUND(AVG(cleaned_duration)::NUMERIC, 2)  AS mean_dur
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
    WHERE rn <= 10
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
    SELECT
        student_name,
        MAX(composite_score) AS lw_composite
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
        WHERE ssh.snapshot_date <  wm.monday
          AND ssh.snapshot_date >= wm.monday - INTERVAL '12 weeks'
          AND ssh.composite_score > 0
    ) recent
    WHERE rn <= 2
    GROUP BY student_name
),
ranked_pool AS (
    SELECT
        wc.student_name,
        sb.student_major,
        sb.student_grade,
        COALESCE(ws.composite_score, sb.composite_score)           AS display_score,
        sb.alpha,
        ws.trend_score,
        COALESCE(ws.mean_duration, sb.mean_duration)               AS mean_duration,
        COALESCE(ws.record_count, sb.record_count)::INTEGER        AS record_count,
        wc.cnt                                                     AS week_sessions
    FROM week_cnt wc
    JOIN public.student_baseline sb ON sb.student_name = wc.student_name
    LEFT JOIN week_scores ws        ON ws.student_name = wc.student_name
    WHERE COALESCE(ws.composite_score, sb.composite_score, 0) > 0
),
comp AS (
    SELECT
        '综合榜'::TEXT AS board,
        RANK() OVER (
            ORDER BY rp.display_score DESC NULLS LAST,
                     rp.mean_duration DESC NULLS LAST,
                     rp.record_count  DESC NULLS LAST
        )::INTEGER AS rank_no,
        rp.student_name, rp.student_major, rp.student_grade,
        rp.display_score, rp.alpha, rp.trend_score, rp.mean_duration, rp.record_count,
        r10.outlier_rate AS recent10_outlier_rate,
        r10.mean_dur     AS recent10_mean_dur,
        r10.cnt          AS recent10_count
    FROM ranked_pool rp
    LEFT JOIN recent10 r10 ON r10.student_name = rp.student_name
),
comp_top10 AS (
    SELECT student_name
    FROM comp
    WHERE rank_no <= 10
),
prog AS (
    SELECT
        '进步榜'::TEXT AS board,
        RANK() OVER (
            ORDER BY (rp.display_score - lws.lw_composite) DESC NULLS LAST,
                     rp.display_score                      DESC NULLS LAST,
                     rp.mean_duration                      DESC NULLS LAST
        )::INTEGER AS rank_no,
        rp.student_name, rp.student_major, rp.student_grade,
        rp.display_score, rp.alpha,
        ROUND((rp.display_score - lws.lw_composite)::NUMERIC, 1) AS trend_score,
        rp.mean_duration, rp.record_count,
        r10.outlier_rate AS recent10_outlier_rate,
        r10.mean_dur     AS recent10_mean_dur,
        r10.cnt          AS recent10_count
    FROM ranked_pool rp
    INNER JOIN last_week_scores lws ON lws.student_name = rp.student_name
    LEFT JOIN recent10 r10          ON r10.student_name = rp.student_name
    WHERE (rp.display_score - lws.lw_composite) > 0
      AND rp.week_sessions >= 2
      AND COALESCE(r10.outlier_rate, 1) <= 0.50
      AND rp.student_name NOT IN (SELECT student_name FROM comp_top10)
),
stable AS (
    SELECT
        '稳定榜'::TEXT AS board,
        RANK() OVER (
            ORDER BY rp.alpha                  DESC NULLS LAST,
                     COALESCE(r10.mean_dur, 0) DESC NULLS LAST,
                     COALESCE(r10.outlier_rate, 1) ASC
        )::INTEGER AS rank_no,
        rp.student_name, rp.student_major, rp.student_grade,
        rp.display_score, rp.alpha, rp.trend_score, rp.mean_duration, rp.record_count,
        r10.outlier_rate AS recent10_outlier_rate,
        r10.mean_dur     AS recent10_mean_dur,
        r10.cnt          AS recent10_count
    FROM ranked_pool rp
    LEFT JOIN recent10 r10 ON r10.student_name = rp.student_name
    WHERE COALESCE(rp.alpha, 0)         >= 0.55
      AND COALESCE(r10.cnt, 0)          >= 8
      AND COALESCE(r10.outlier_rate, 1) <= 0.40
      AND rp.student_name NOT IN (SELECT student_name FROM comp_top10)
),
rules AS (
    SELECT
        '守则榜'::TEXT AS board,
        RANK() OVER (
            ORDER BY COALESCE(r10.outlier_rate, 1) ASC,
                     rp.week_sessions DESC NULLS LAST,
                     COALESCE(r10.mean_dur, 0) DESC
        )::INTEGER AS rank_no,
        rp.student_name, rp.student_major, rp.student_grade,
        rp.display_score, rp.alpha, rp.trend_score, rp.mean_duration, rp.record_count,
        r10.outlier_rate AS recent10_outlier_rate,
        r10.mean_dur     AS recent10_mean_dur,
        r10.cnt          AS recent10_count
    FROM ranked_pool rp
    LEFT JOIN recent10 r10 ON r10.student_name = rp.student_name
    WHERE rp.week_sessions              >= 3
      AND COALESCE(r10.cnt, 0)          >= 4
      AND COALESCE(r10.mean_dur, 0)     > 25
      AND COALESCE(r10.outlier_rate, 1) <= 0.50
      AND COALESCE(rp.alpha, 0)         >= 0.55
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
$$;

GRANT EXECUTE ON FUNCTION public.get_weekly_leaderboards() TO anon, authenticated;


CREATE OR REPLACE FUNCTION public.compute_baseline_as_of(
    p_student_name TEXT,
    p_as_of_date   DATE
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_mean          FLOAT;
    v_std           FLOAT;
    v_count         INTEGER;
    v_outlier_rate  FLOAT;
    v_short_rate    FLOAT;
    v_alpha         FLOAT;
    v_cv            FLOAT;
    v_group_alpha   FLOAT;
    v_lambda        FLOAT;
    v_weekday_json  JSONB;
    v_student_major TEXT;
    v_student_grade TEXT;
    v_asof_bjt      TIMESTAMPTZ;
    v_last_updated  TIMESTAMPTZ;
BEGIN
    v_asof_bjt := (p_as_of_date::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';

    SELECT student_major, student_grade
    INTO v_student_major, v_student_grade
    FROM public.practice_sessions
    WHERE student_name  = p_student_name
      AND session_start < v_asof_bjt
      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    ORDER BY session_start DESC
    LIMIT 1;

    IF NOT FOUND THEN RETURN; END IF;

    WITH recent_valid AS (
        SELECT cleaned_duration
        FROM public.practice_sessions
        WHERE student_name     = p_student_name
          AND cleaned_duration > 0
          AND session_start    < v_asof_bjt
          AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
        ORDER BY session_start DESC
        LIMIT 30
    )
    SELECT COUNT(*)::INTEGER, AVG(cleaned_duration), STDDEV(cleaned_duration)
    INTO v_count, v_mean, v_std
    FROM recent_valid;

    IF COALESCE(v_count, 0) = 0 THEN RETURN; END IF;

    v_std := CASE
        WHEN v_count < 2              THEN NULL
        WHEN COALESCE(v_std, 0) < 1.0 THEN 1.0
        ELSE v_std
    END;

    v_cv := CASE
        WHEN COALESCE(v_mean, 0) > 0 AND v_std IS NOT NULL THEN v_std / v_mean
        ELSE 0.5
    END;

    SELECT
        AVG(CASE WHEN is_outlier THEN 1.0 ELSE 0.0 END),
        AVG(CASE WHEN cleaned_duration >= 5 AND cleaned_duration < 30 THEN 1.0 ELSE 0.0 END)
    INTO v_outlier_rate, v_short_rate
    FROM (
        SELECT is_outlier, cleaned_duration
        FROM public.practice_sessions
        WHERE student_name  = p_student_name
          AND session_start < v_asof_bjt
          AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
        ORDER BY session_start DESC
        LIMIT 30
    ) recent;

    WITH recent_dow AS (
        SELECT EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai')::INTEGER AS dow
        FROM public.practice_sessions
        WHERE student_name     = p_student_name
          AND cleaned_duration > 0
          AND session_start    < v_asof_bjt
          AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
        ORDER BY session_start DESC
        LIMIT 30
    )
    SELECT jsonb_object_agg(dow::TEXT, cnt)
    INTO v_weekday_json
    FROM (SELECT dow, COUNT(*) AS cnt FROM recent_dow GROUP BY dow) agg;

    v_alpha := 1.0
        - CASE
            WHEN COALESCE(v_mean, 0) > 0 THEN LEAST(0.15, 5.0 / v_mean)
            ELSE 0.15
          END
        - LEAST(0.20, v_cv * 0.15)
        - CASE
            WHEN COALESCE(v_outlier_rate, 0) <= 0.30
                THEN 0.08 * COALESCE(v_outlier_rate, 0)
            ELSE
                0.024 + 0.40 * (COALESCE(v_outlier_rate, 0) - 0.30)
          END
        - 0.05 * COALESCE(v_short_rate, 0);

    IF COALESCE(v_count, 0) < 10 THEN
        SELECT AVG(calc.mean_alpha)
        INTO v_group_alpha
        FROM (
            SELECT student_name, AVG(cleaned_duration) AS mean_dur
            FROM (
                SELECT student_name, cleaned_duration,
                       ROW_NUMBER() OVER (PARTITION BY student_name ORDER BY session_start DESC) AS rn
                FROM public.practice_sessions
                WHERE student_major    = v_student_major
                  AND student_grade    = v_student_grade
                  AND student_name    <> p_student_name
                  AND cleaned_duration > 0
                  AND session_start    < v_asof_bjt
                  AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
            ) sub
            WHERE rn <= 30
            GROUP BY student_name
            HAVING COUNT(*) >= 10
        ) grp
        CROSS JOIN LATERAL (
            SELECT 1.0
                 - LEAST(0.15, 5.0 / NULLIF(grp.mean_dur, 0))
                 - LEAST(0.20, CASE WHEN NULLIF(grp.mean_dur, 0) IS NOT NULL
                                    THEN (10.0 / grp.mean_dur) * 0.15
                                    ELSE 0.5 * 0.15 END)
                 AS mean_alpha
        ) calc;

        IF v_group_alpha IS NULL THEN
            SELECT AVG(calc2.mean_alpha)
            INTO v_group_alpha
            FROM (
                SELECT student_name, AVG(cleaned_duration) AS mean_dur
                FROM (
                    SELECT student_name, cleaned_duration,
                           ROW_NUMBER() OVER (PARTITION BY student_name ORDER BY session_start DESC) AS rn
                    FROM public.practice_sessions
                    WHERE student_major    = v_student_major
                      AND student_name    <> p_student_name
                      AND cleaned_duration > 0
                      AND session_start    < v_asof_bjt
                      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
                ) sub
                WHERE rn <= 30
                GROUP BY student_name
                HAVING COUNT(*) >= 10
            ) grp
            CROSS JOIN LATERAL (
                SELECT 1.0 - LEAST(0.15, 5.0 / NULLIF(grp.mean_dur, 0)) AS mean_alpha
            ) calc2;
        END IF;

        v_lambda := 1.0 - (COALESCE(v_count, 0)::FLOAT / 10.0);
        v_alpha  := v_lambda * COALESCE(v_group_alpha, 0.82)
                  + (1.0 - v_lambda) * v_alpha;
    END IF;

    v_alpha := GREATEST(0.5, LEAST(1.0, v_alpha));

    v_last_updated := CASE
        WHEN p_as_of_date > (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE THEN NOW()
        ELSE v_asof_bjt
    END;

    INSERT INTO public.student_baseline (
        student_name, student_major, student_grade,
        mean_duration, std_duration,
        outlier_rate, short_session_rate,
        alpha, record_count,
        weekday_pattern, is_cold_start, last_updated
    ) VALUES (
        p_student_name, v_student_major, v_student_grade,
        COALESCE(v_mean, 0), v_std,
        COALESCE(v_outlier_rate, 0), COALESCE(v_short_rate, 0),
        v_alpha, COALESCE(v_count, 0),
        COALESCE(v_weekday_json, '{}'::JSONB),
        (COALESCE(v_count, 0) < 10),
        v_last_updated
    )
    ON CONFLICT (student_name) DO UPDATE SET
        student_major      = EXCLUDED.student_major,
        student_grade      = EXCLUDED.student_grade,
        mean_duration      = EXCLUDED.mean_duration,
        std_duration       = EXCLUDED.std_duration,
        outlier_rate       = EXCLUDED.outlier_rate,
        short_session_rate = EXCLUDED.short_session_rate,
        alpha              = EXCLUDED.alpha,
        record_count       = EXCLUDED.record_count,
        weekday_pattern    = EXCLUDED.weekday_pattern,
        is_cold_start      = EXCLUDED.is_cold_start,
        last_updated       = EXCLUDED.last_updated;
END;
$$;


CREATE OR REPLACE FUNCTION public.compute_baseline(
    p_student_name TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    PERFORM public.compute_baseline_as_of(
        p_student_name,
        ((NOW() AT TIME ZONE 'Asia/Shanghai')::DATE + 1)
    );
END;
$$;


CREATE OR REPLACE FUNCTION public.backfill_score_history()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_start_date     DATE;
    v_end_date       DATE;
    v_current_date   DATE;
    v_next_date      DATE;
    v_week_start_bjt TIMESTAMPTZ;
    v_week_next_bjt  TIMESTAMPTZ;
    v_student        RECORD;
    v_week_count     INTEGER := 0;
    v_active_count   INTEGER := 0;
    v_zero_count     INTEGER := 0;
BEGIN
    PERFORM set_config('app.skip_score_trigger', 'on', TRUE);

    SELECT DATE_TRUNC('week', MIN(session_start))::DATE INTO v_start_date
    FROM public.practice_sessions
    WHERE cleaned_duration > 0;

    v_end_date     := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
    v_current_date := v_start_date;

    RAISE NOTICE '回溯范围：% → %（FIX-76）', v_start_date, v_end_date;

    WHILE v_current_date <= v_end_date LOOP
        v_week_count := v_week_count + 1;
        v_next_date  := v_current_date + INTERVAL '7 days';
        v_week_start_bjt := (v_current_date::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';
        v_week_next_bjt  := (v_next_date::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';

        FOR v_student IN
            SELECT DISTINCT student_name
            FROM public.practice_sessions
            WHERE session_start < v_week_start_bjt
              AND cleaned_duration > 0
            ORDER BY student_name
        LOOP
            BEGIN
                PERFORM public.compute_baseline_as_of(v_student.student_name, v_current_date);
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '[backfill baseline] % @ % 失败：%', v_student.student_name, v_current_date, SQLERRM;
            END;
        END LOOP;

        FOR v_student IN
            SELECT DISTINCT student_name
            FROM public.practice_sessions
            WHERE session_start < v_week_start_bjt
              AND cleaned_duration > 0
            ORDER BY student_name
        LOOP
            BEGIN
                IF EXISTS (
                    SELECT 1
                    FROM public.practice_sessions
                    WHERE student_name     = v_student.student_name
                      AND cleaned_duration > 0
                      AND session_start   >= v_week_start_bjt
                      AND session_start   <  v_week_next_bjt
                ) THEN
                    PERFORM public.compute_student_score_as_of(v_student.student_name, v_current_date);
                    v_active_count := v_active_count + 1;
                ELSE
                    INSERT INTO public.student_score_history (
                        student_name, snapshot_date, raw_score, composite_score,
                        baseline_score, trend_score, momentum_score, accum_score,
                        outlier_rate, short_session_rate, mean_duration, record_count
                    ) VALUES (
                        v_student.student_name, v_current_date, 0, 0,
                        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
                    )
                    ON CONFLICT (student_name, snapshot_date) DO NOTHING;
                    v_zero_count := v_zero_count + 1;
                END IF;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '[backfill score] % @ % 失败：%', v_student.student_name, v_current_date, SQLERRM;
            END;
        END LOOP;

        UPDATE public.student_score_history
        SET composite_score = ROUND((raw_score * 100)::NUMERIC, 1)
        WHERE snapshot_date   = v_current_date
          AND raw_score       IS NOT NULL
          AND raw_score        > 0
          AND (composite_score IS NULL OR composite_score <> ROUND((raw_score * 100)::NUMERIC, 1));

        v_current_date := v_next_date;
    END LOOP;

    UPDATE public.student_baseline b
    SET composite_score = latest.composite_score
    FROM (
        SELECT DISTINCT ON (student_name) student_name, composite_score
        FROM public.student_score_history
        WHERE composite_score > 0
        ORDER BY student_name, snapshot_date DESC
    ) latest
    WHERE b.student_name = latest.student_name;

    FOR v_student IN
        SELECT student_name
        FROM public.student_baseline
        ORDER BY student_name
    LOOP
        BEGIN
            PERFORM public.compute_baseline(v_student.student_name);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[backfill rebase] % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    FOR v_student IN
        SELECT DISTINCT student_name
        FROM public.student_baseline
    LOOP
        BEGIN
            PERFORM public.compute_and_store_w_score(v_student.student_name);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[backfill w_score] % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
    RAISE NOTICE '回溯完成（FIX-76）：共 % 周，重算 % 条，零分 % 条',
        v_week_count, v_active_count, v_zero_count;
END;
$$;


CREATE OR REPLACE FUNCTION public.run_weekly_score_update()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_student        RECORD;
    v_monday         DATE;
    v_week_start_bjt TIMESTAMPTZ;
BEGIN
    PERFORM set_config('app.skip_score_trigger', 'on', TRUE);

    v_monday := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
    v_week_start_bjt := (v_monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';
    RAISE NOTICE '[%] 每周评分更新，快照日期：%', NOW(), v_monday;

    FOR v_student IN
        SELECT student_name
        FROM public.student_baseline
        ORDER BY student_name
    LOOP
        BEGIN
            PERFORM public.compute_baseline_as_of(
                v_student.student_name,
                ((NOW() AT TIME ZONE 'Asia/Shanghai')::DATE + 1)
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[weekly baseline] 学生 % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    FOR v_student IN
        SELECT student_name
        FROM public.student_baseline
        WHERE student_name NOT IN (
            SELECT DISTINCT student_name
            FROM public.practice_sessions
            WHERE session_start >= v_week_start_bjt
              AND cleaned_duration > 0
              AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
        )
        ORDER BY student_name
    LOOP
        BEGIN
            PERFORM public.compute_student_score(v_student.student_name);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[weekly snapshot] 学生 % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
    RAISE NOTICE '[%] 每周更新完成（FIX-76：北京时间边界 + 周末不计榜）', NOW();
END;
$$;
