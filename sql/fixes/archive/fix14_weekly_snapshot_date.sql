-- ================================================================
-- FIX-14: compute_student_score — snapshot_date 统一使用本周一
--
-- 根本原因：
--   compute_student_score（实时触发版）使用 CURRENT_DATE 作为
--   snapshot_date，导致：
--     · 学生周三练琴 → 写入 2026-03-11（周三）的快照
--     · run_weekly_score_update 写入 2026-03-09（周一）的快照
--     · Dashboard 一周内出现两行，且"本周未练"与真实分数并存
--
-- 修复：
--   两处 CURRENT_DATE 改为 DATE_TRUNC('week', CURRENT_DATE)::DATE
--   确保实时触发和周任务都写到同一行（本周一），ON CONFLICT DO UPDATE
--   保证同一周最新一次练琴的计算结果始终覆盖旧值，每周只有一行
--
-- 执行步骤：
--   STEP 1 → 部署修复后的 compute_student_score
--   STEP 2 → 清理历史中非周一的杂乱快照
--   STEP 3 → 重跑 backfill_score_history 重建干净历史
-- ================================================================


-- ================================================================
-- STEP 1: 修复 compute_student_score（仅改 snapshot_date）
-- ================================================================
CREATE OR REPLACE FUNCTION public.compute_student_score(p_student_name TEXT)
RETURNS TABLE(composite_score INT, weight_conf FLOAT)
LANGUAGE plpgsql AS $$
DECLARE
    median_mean        FLOAT;
    p25_mean           FLOAT;
    p75_mean           FLOAT;
    pop_iqr            FLOAT;
    median_stddev      FLOAT;
    r                  RECORD;
    hist_mean_dur      FLOAT;
    hist_std_dur       FLOAT;
    hist_score_early   FLOAT;
    hist_score_recent  FLOAT;
    hist_count         INTEGER;
    slope              FLOAT;
    n_points           INTEGER;
    sum_x              FLOAT := 0;
    sum_y              FLOAT := 0;
    sum_xy             FLOAT := 0;
    sum_x2             FLOAT := 0;
    rec                RECORD;
    b_score            FLOAT;
    t_score            FLOAT;
    m_score            FLOAT;
    a_score            FLOAT;
    consec_improve     INTEGER := 0;
    prev_val           FLOAT   := NULL;
    cur_val            FLOAT;
    velocity           FLOAT   := 0.0;
    w_baseline         FLOAT;
    w_trend            FLOAT;
    w_momentum         FLOAT;
    w_accum            FLOAT;
    weight_conf_val    FLOAT;
    data_freshness     FLOAT;
    days_stale         FLOAT;
    composite_raw      FLOAT;
    outlier_penalty    FLOAT;
    v_personal_best    INTEGER;
    major_sample_count INTEGER;
    v_days_inactive    FLOAT;
    v_frozen_score     INT;
    v_frozen_conf      FLOAT;
    -- FIX-14: 统一使用本周一作为 snapshot_date
    v_week_monday      DATE;
BEGIN
    v_week_monday := DATE_TRUNC('week', CURRENT_DATE)::DATE;

    -- ① 读取当前学生基线
    SELECT * INTO r
    FROM public.student_baseline
    WHERE student_name = p_student_name;

    IF NOT FOUND THEN
        RETURN QUERY SELECT 0::INT, 0::FLOAT;
        RETURN;
    END IF;

    -- ①+ [FIX-12 停琴检测] 超过 30 天无新 session → 冻结分数
    SELECT EXTRACT(DAY FROM (NOW() - MAX(session_start)))::FLOAT
    INTO v_days_inactive
    FROM public.practice_sessions
    WHERE student_name = p_student_name;

    v_days_inactive := COALESCE(v_days_inactive, 9999.0);

    IF v_days_inactive > 30 THEN
        v_frozen_score := COALESCE(r.composite_score, 0);
        v_frozen_conf  := COALESCE(r.score_confidence, 0.0)
                          * EXP(-0.005 * (v_days_inactive - 30));
        v_frozen_conf  := GREATEST(0.05, LEAST(1.0, v_frozen_conf));

        -- [FIX-14] snapshot_date = 本周一（原为 CURRENT_DATE）
        INSERT INTO public.student_score_history (
            student_name, snapshot_date,
            mean_duration, std_duration, record_count,
            outlier_rate, short_session_rate,
            raw_score, composite_score,
            baseline_score, trend_score, momentum_score, accum_score
        ) VALUES (
            p_student_name, v_week_monday,
            r.mean_duration, r.std_duration, r.record_count,
            r.outlier_rate, r.short_session_rate,
            r.raw_score, v_frozen_score,
            r.baseline_score, r.trend_score, r.momentum_score, r.accum_score
        )
        ON CONFLICT (student_name, snapshot_date) DO UPDATE SET
            composite_score    = EXCLUDED.composite_score,
            raw_score          = EXCLUDED.raw_score,
            mean_duration      = EXCLUDED.mean_duration,
            std_duration       = EXCLUDED.std_duration,
            record_count       = EXCLUDED.record_count,
            outlier_rate       = EXCLUDED.outlier_rate,
            short_session_rate = EXCLUDED.short_session_rate,
            baseline_score     = EXCLUDED.baseline_score,
            trend_score        = EXCLUDED.trend_score,
            momentum_score     = EXCLUDED.momentum_score,
            accum_score        = EXCLUDED.accum_score;

        UPDATE public.student_baseline
        SET score_confidence = ROUND(v_frozen_conf::NUMERIC, 3),
            last_updated     = NOW()
        WHERE student_name = p_student_name;

        RETURN QUERY SELECT v_frozen_score, v_frozen_conf::FLOAT;
        RETURN;
    END IF;

    -- ② A 维度群体统计：优先同专业，不足5人时回落全体
    SELECT COUNT(*) INTO major_sample_count
    FROM public.student_baseline
    WHERE student_major = r.student_major AND mean_duration > 0;

    IF major_sample_count >= 5 THEN
        SELECT
            percentile_cont(0.25) WITHIN GROUP (ORDER BY mean_duration),
            percentile_cont(0.50) WITHIN GROUP (ORDER BY mean_duration),
            percentile_cont(0.75) WITHIN GROUP (ORDER BY mean_duration)
        INTO p25_mean, median_mean, p75_mean
        FROM public.student_baseline
        WHERE mean_duration IS NOT NULL AND mean_duration > 0
          AND student_major = r.student_major;
    ELSE
        SELECT
            percentile_cont(0.25) WITHIN GROUP (ORDER BY mean_duration),
            percentile_cont(0.50) WITHIN GROUP (ORDER BY mean_duration),
            percentile_cont(0.75) WITHIN GROUP (ORDER BY mean_duration)
        INTO p25_mean, median_mean, p75_mean
        FROM public.student_baseline
        WHERE mean_duration IS NOT NULL AND mean_duration > 0;
    END IF;

    pop_iqr := GREATEST(p75_mean - p25_mean, 1.0);

    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY std_duration)
    INTO median_stddev
    FROM public.student_baseline
    WHERE std_duration IS NOT NULL;
    median_stddev := GREATEST(COALESCE(median_stddev, 1.0), 1.0);

    -- ③ 历史快照统计
    SELECT COUNT(*)::INTEGER, AVG(mean_duration), STDDEV(mean_duration)
    INTO hist_count, hist_mean_dur, hist_std_dur
    FROM public.student_score_history
    WHERE student_name = p_student_name;

    hist_count    := COALESCE(hist_count, 0);
    hist_mean_dur := COALESCE(hist_mean_dur, r.mean_duration);

    SELECT
        AVG(raw_score) FILTER (
            WHERE snapshot_date IN (
                SELECT snapshot_date FROM public.student_score_history
                WHERE student_name = p_student_name
                ORDER BY snapshot_date ASC LIMIT 5
            )
        ),
        AVG(raw_score) FILTER (
            WHERE snapshot_date IN (
                SELECT snapshot_date FROM public.student_score_history
                WHERE student_name = p_student_name
                ORDER BY snapshot_date DESC LIMIT 5
            )
        )
    INTO hist_score_early, hist_score_recent
    FROM public.student_score_history
    WHERE student_name = p_student_name;

    hist_score_early  := COALESCE(hist_score_early,  0.5);
    hist_score_recent := COALESCE(hist_score_recent, 0.5);

    -- ④ B：Baseline Progress
    b_score := 1.0 / (1.0 + EXP(
        -3.0 * (hist_score_recent - hist_score_early) / 0.3
    ));
    b_score := GREATEST(0.0, LEAST(1.0, b_score));

    -- ⑤ T：Trend（线性回归斜率，最近8周）
    n_points := 0;
    sum_x := 0; sum_y := 0; sum_xy := 0; sum_x2 := 0;

    FOR rec IN
        SELECT
            ROW_NUMBER() OVER (ORDER BY snapshot_date ASC) AS x,
            COALESCE(raw_score, 0.5) AS y
        FROM (
            SELECT snapshot_date, raw_score FROM public.student_score_history
            WHERE student_name = p_student_name
            ORDER BY snapshot_date DESC LIMIT 8
        ) sub
    LOOP
        n_points := n_points + 1;
        sum_x    := sum_x  + rec.x;
        sum_y    := sum_y  + rec.y;
        sum_xy   := sum_xy + rec.x * rec.y;
        sum_x2   := sum_x2 + rec.x * rec.x;
    END LOOP;

    IF n_points >= 3 THEN
        slope   := (n_points * sum_xy - sum_x * sum_y)
                 / NULLIF(n_points * sum_x2 - sum_x * sum_x, 0);
        slope   := COALESCE(slope, 0.0);
        t_score := 1.0 / (1.0 + EXP(-slope / 0.02 * 3.0));
    ELSE
        t_score := 0.5;
    END IF;
    t_score := GREATEST(0.0, LEAST(1.0, t_score));

    -- ⑥ M：Momentum（连续改善周数）
    consec_improve := 0;
    prev_val       := NULL;

    FOR rec IN
        SELECT raw_score AS y
        FROM public.student_score_history
        WHERE student_name = p_student_name
        ORDER BY snapshot_date DESC LIMIT 12
    LOOP
        cur_val := COALESCE(rec.y, 0.0);
        IF prev_val IS NULL THEN
            prev_val := cur_val;
            CONTINUE;
        END IF;
        IF prev_val > cur_val THEN
            consec_improve := consec_improve + 1;
            prev_val := cur_val;
        ELSE
            EXIT;
        END IF;
    END LOOP;

    m_score := LEAST(1.0, LN(consec_improve::FLOAT + 1.0) / LN(9.0));
    m_score := GREATEST(0.0, m_score);

    -- ⑦ A：Accumulation
    DECLARE
        quality_score FLOAT;
        accum_raw     FLOAT;
    BEGIN
        quality_score := 1.0 / (1.0 + EXP(
            -((COALESCE(r.mean_duration, 0) - median_mean) / (pop_iqr / 1.35))
        ));
        quality_score := GREATEST(0.1, LEAST(1.0, quality_score));
        accum_raw     := COALESCE(r.record_count, 0)::FLOAT * quality_score;
        a_score       := LEAST(1.0, LN(accum_raw + 1.0) / LN(31.0));
    END;
    a_score := GREATEST(0.0, a_score);

    -- ⑧ Velocity
    DECLARE
        sx4 FLOAT:=0; sy4 FLOAT:=0; sxy4 FLOAT:=0; sx24 FLOAT:=0; n4 INTEGER:=0;
        sx8 FLOAT:=0; sy8 FLOAT:=0; sxy8 FLOAT:=0; sx28 FLOAT:=0; n8 INTEGER:=0;
        slope4 FLOAT; slope8 FLOAT;
    BEGIN
        FOR rec IN
            SELECT
                ROW_NUMBER() OVER (ORDER BY snapshot_date ASC)  AS x,
                COALESCE(raw_score, 0.5)                         AS y,
                ROW_NUMBER() OVER (ORDER BY snapshot_date DESC)  AS rn
            FROM (
                SELECT snapshot_date, raw_score FROM public.student_score_history
                WHERE student_name = p_student_name
                ORDER BY snapshot_date DESC LIMIT 8
            ) sub
        LOOP
            n8   := n8   + 1;
            sx8  := sx8  + rec.x; sy8  := sy8  + rec.y;
            sxy8 := sxy8 + rec.x * rec.y;
            sx28 := sx28 + rec.x * rec.x;
            IF rec.rn <= 4 THEN
                n4   := n4   + 1;
                sx4  := sx4  + rec.x; sy4  := sy4  + rec.y;
                sxy4 := sxy4 + rec.x * rec.y;
                sx24 := sx24 + rec.x * rec.x;
            END IF;
        END LOOP;

        slope4 := CASE WHEN n4 >= 3
            THEN (n4 * sxy4 - sx4 * sy4) / NULLIF(n4 * sx24 - sx4 * sx4, 0)
            ELSE NULL END;
        slope8 := CASE WHEN n8 >= 3
            THEN (n8 * sxy8 - sx8 * sy8) / NULLIF(n8 * sx28 - sx8 * sx8, 0)
            ELSE NULL END;

        velocity := COALESCE(slope4, 0.0) - COALESCE(slope8, 0.0);
    END;

    -- ⑨ 动态权重
    IF hist_count < 4 THEN
        w_baseline := 0.10; w_trend := 0.10; w_momentum := 0.10; w_accum := 0.70;
    ELSIF hist_count < 12 THEN
        w_baseline := 0.25; w_trend := 0.25; w_momentum := 0.15; w_accum := 0.35;
    ELSE
        w_baseline := 0.30; w_trend := 0.30; w_momentum := 0.20; w_accum := 0.20;
    END IF;

    -- ⑩ 合成
    composite_raw := w_baseline * b_score + w_trend * t_score
                   + w_momentum * m_score + w_accum  * a_score;
    composite_raw := GREATEST(0.0, LEAST(1.0, composite_raw));

    -- ⑪ 异常惩罚
    outlier_penalty := CASE
        WHEN COALESCE(r.outlier_rate, 0.0) <= 0.4 THEN 1.0
        ELSE EXP(-5.0 * (COALESCE(r.outlier_rate, 0.0) - 0.4))
    END;
    composite_raw := GREATEST(0.0, LEAST(1.0, composite_raw * outlier_penalty));

    -- ⑫ 置信度
    days_stale := EXTRACT(
        DAY FROM (NOW() - COALESCE(r.last_updated, NOW() - INTERVAL '999 days'))
    )::FLOAT;

    data_freshness := CASE
        WHEN days_stale <= 7  THEN 1.0
        WHEN days_stale <= 30 THEN 1.0 - 0.5 * ((days_stale - 7) / 23.0)
        WHEN days_stale <= 90 THEN 0.5 - 0.4 * ((days_stale - 30) / 60.0)
        ELSE 0.1
    END;

    weight_conf_val :=
        LEAST(1.0, LN(GREATEST(hist_count, 1)::FLOAT + 1.0) / LN(13.0))
        * (1.0 - COALESCE(r.outlier_rate, 0.0) * 0.5)
        * data_freshness;
    weight_conf_val := GREATEST(0.0, LEAST(1.0, weight_conf_val));

    -- ⑬ 历史最高分
    SELECT COALESCE(MAX(h.composite_score), 0) INTO v_personal_best
    FROM public.student_score_history h
    WHERE h.student_name = p_student_name;
    v_personal_best := GREATEST(v_personal_best, ROUND(composite_raw * 100)::INT);

    -- ⑭ 写入历史快照（[FIX-14] snapshot_date = 本周一，原为 CURRENT_DATE）
    INSERT INTO public.student_score_history (
        student_name, snapshot_date,
        mean_duration, std_duration, record_count,
        outlier_rate, short_session_rate,
        raw_score, composite_score,
        baseline_score, trend_score, momentum_score, accum_score
    ) VALUES (
        p_student_name, v_week_monday,
        r.mean_duration, r.std_duration, r.record_count,
        r.outlier_rate, r.short_session_rate,
        composite_raw, ROUND(composite_raw * 100)::INT,
        b_score, t_score, m_score, a_score
    )
    ON CONFLICT (student_name, snapshot_date) DO UPDATE SET
        mean_duration      = EXCLUDED.mean_duration,
        std_duration       = EXCLUDED.std_duration,
        record_count       = EXCLUDED.record_count,
        outlier_rate       = EXCLUDED.outlier_rate,
        short_session_rate = EXCLUDED.short_session_rate,
        raw_score          = EXCLUDED.raw_score,
        composite_score    = EXCLUDED.composite_score,
        baseline_score     = EXCLUDED.baseline_score,
        trend_score        = EXCLUDED.trend_score,
        momentum_score     = EXCLUDED.momentum_score,
        accum_score        = EXCLUDED.accum_score,
        created_at         = NOW();

    -- ⑮ 写回基线表
    UPDATE public.student_baseline
    SET composite_score  = ROUND(composite_raw * 100)::INT,
        raw_score        = composite_raw,
        baseline_score   = b_score,
        trend_score      = t_score,
        momentum_score   = m_score,
        accum_score      = a_score,
        growth_velocity  = COALESCE(velocity, 0.0),
        personal_best    = v_personal_best,
        weeks_improving  = consec_improve,
        score_confidence = ROUND(weight_conf_val::NUMERIC, 3),
        last_updated     = NOW()
    WHERE student_name = p_student_name;

    RETURN QUERY SELECT ROUND(composite_raw * 100)::INT,
                        ROUND(weight_conf_val::NUMERIC, 3)::FLOAT;
END;
$$;


-- ================================================================
-- STEP 2: 清理历史中非周一的杂乱快照（由旧版 CURRENT_DATE 产生）
-- ================================================================
DELETE FROM public.student_score_history
WHERE snapshot_date != DATE_TRUNC('week', snapshot_date)::DATE;

-- 确认清理数量（可选）
-- SELECT COUNT(*) FROM public.student_score_history;


-- ================================================================
-- STEP 3: 重跑 backfill 重建干净的纯周一历史
-- ================================================================
TRUNCATE public.student_score_history;
SELECT public.backfill_score_history();


-- ================================================================
-- STEP 4: 同步最新有效分数回 student_baseline
-- ================================================================
UPDATE public.student_baseline b
SET composite_score = latest.composite_score
FROM (
    SELECT DISTINCT ON (student_name)
        student_name, composite_score
    FROM public.student_score_history
    WHERE composite_score > 0
    ORDER BY student_name, snapshot_date DESC
) latest
WHERE b.student_name = latest.student_name;

-- ================================================================
-- 验证：确认所有快照 snapshot_date 均为周一
-- ================================================================
-- SELECT EXTRACT(DOW FROM snapshot_date) AS weekday, COUNT(*)
-- FROM public.student_score_history
-- GROUP BY weekday;
-- 结果应只有 weekday=1（周一），若出现其他值说明仍有脏数据
