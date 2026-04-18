-- ================================================================
-- FIX-16: compute_student_score — B/T/M 三维计算排除缺席周(raw_score=0)快照
--
-- 问题：FIX-13 为无练琴的周写入 raw_score=0 的快照，
--       这些快照被 B/T/M 三维当作"表现为零"参与计算，
--       导致久未练琴后第一次回来的学生分数极低，且不公平。
--
-- 修复：B/T/M 三维的历史查询均加 WHERE raw_score > 0
--       hist_count 也只统计有练琴的快照（用于权重判断）
--       A 维度和置信度不变（A 基于记录数/时长质量，与快照无关）
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
    hist_count         INTEGER;   -- 仅统计有练琴的快照数
    hist_count_all     INTEGER;   -- 全部快照数（含缺席周，用于置信度）
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
    v_week_monday      DATE;
    v_has_session_this_week BOOLEAN;
BEGIN
    v_week_monday := DATE_TRUNC('week', CURRENT_DATE)::DATE;

    -- ① 读取基线
    SELECT * INTO r FROM public.student_baseline WHERE student_name = p_student_name;
    IF NOT FOUND THEN
        RETURN QUERY SELECT 0::INT, 0::FLOAT;
        RETURN;
    END IF;

    -- [FIX-12] 停琴 > 30 天 → 冻结分数
    SELECT EXTRACT(DAY FROM (NOW() - MAX(session_start)))::FLOAT
    INTO v_days_inactive
    FROM public.practice_sessions WHERE student_name = p_student_name;
    v_days_inactive := COALESCE(v_days_inactive, 9999.0);

    IF v_days_inactive > 30 THEN
        v_frozen_score := COALESCE(r.composite_score, 0);
        v_frozen_conf  := GREATEST(0.05, LEAST(1.0,
            COALESCE(r.score_confidence, 0.0) * EXP(-0.005 * (v_days_inactive - 30))));

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
        SET score_confidence = ROUND(v_frozen_conf::NUMERIC, 3), last_updated = NOW()
        WHERE student_name = p_student_name;

        RETURN QUERY SELECT v_frozen_score, v_frozen_conf::FLOAT;
        RETURN;
    END IF;

    -- [FIX-15] 检查本周是否有练琴记录
    SELECT EXISTS (
        SELECT 1 FROM public.practice_sessions
        WHERE student_name    = p_student_name
          AND cleaned_duration > 0
          AND session_start   >= v_week_monday::TIMESTAMPTZ
    ) INTO v_has_session_this_week;

    IF NOT v_has_session_this_week THEN
        INSERT INTO public.student_score_history (
            student_name, snapshot_date,
            raw_score, composite_score,
            baseline_score, trend_score, momentum_score, accum_score,
            outlier_rate, short_session_rate, mean_duration, record_count
        ) VALUES (
            p_student_name, v_week_monday,
            0, 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
        )
        ON CONFLICT (student_name, snapshot_date) DO NOTHING;

        RETURN QUERY SELECT 0::INT, 0.0::FLOAT;
        RETURN;
    END IF;

    -- ── 以下为正常计算路径（本周有练琴）──

    -- ② A 维度群体统计
    SELECT COUNT(*) INTO major_sample_count
    FROM public.student_baseline WHERE student_major = r.student_major AND mean_duration > 0;

    IF major_sample_count >= 5 THEN
        SELECT percentile_cont(0.25) WITHIN GROUP (ORDER BY mean_duration),
               percentile_cont(0.50) WITHIN GROUP (ORDER BY mean_duration),
               percentile_cont(0.75) WITHIN GROUP (ORDER BY mean_duration)
        INTO p25_mean, median_mean, p75_mean
        FROM public.student_baseline
        WHERE mean_duration IS NOT NULL AND mean_duration > 0 AND student_major = r.student_major;
    ELSE
        SELECT percentile_cont(0.25) WITHIN GROUP (ORDER BY mean_duration),
               percentile_cont(0.50) WITHIN GROUP (ORDER BY mean_duration),
               percentile_cont(0.75) WITHIN GROUP (ORDER BY mean_duration)
        INTO p25_mean, median_mean, p75_mean
        FROM public.student_baseline WHERE mean_duration IS NOT NULL AND mean_duration > 0;
    END IF;
    pop_iqr := GREATEST(p75_mean - p25_mean, 1.0);

    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY std_duration)
    INTO median_stddev FROM public.student_baseline WHERE std_duration IS NOT NULL;
    median_stddev := GREATEST(COALESCE(median_stddev, 1.0), 1.0);

    -- ③ 历史快照统计
    -- [FIX-16] hist_count 只统计有实际练琴的快照（raw_score > 0），
    --          用于权重决策，避免缺席周快照虚增 hist_count 导致 B/T 权重过高
    SELECT COUNT(*) FILTER (WHERE raw_score > 0)::INTEGER,
           COUNT(*)::INTEGER,
           AVG(mean_duration) FILTER (WHERE raw_score > 0),
           STDDEV(mean_duration) FILTER (WHERE raw_score > 0)
    INTO hist_count, hist_count_all, hist_mean_dur, hist_std_dur
    FROM public.student_score_history WHERE student_name = p_student_name;
    hist_count    := COALESCE(hist_count, 0);
    hist_count_all:= COALESCE(hist_count_all, 0);
    hist_mean_dur := COALESCE(hist_mean_dur, r.mean_duration);

    -- ④ B：基线进步
    -- [FIX-16] 仅使用 raw_score > 0 的快照，排除缺席周
    SELECT AVG(raw_score) FILTER (WHERE snapshot_date IN (
               SELECT snapshot_date FROM public.student_score_history
               WHERE student_name = p_student_name
                 AND raw_score > 0                        -- FIX-16: 排除缺席周
               ORDER BY snapshot_date ASC LIMIT 5)),
           AVG(raw_score) FILTER (WHERE snapshot_date IN (
               SELECT snapshot_date FROM public.student_score_history
               WHERE student_name = p_student_name
                 AND raw_score > 0                        -- FIX-16: 排除缺席周
               ORDER BY snapshot_date DESC LIMIT 5))
    INTO hist_score_early, hist_score_recent
    FROM public.student_score_history
    WHERE student_name = p_student_name AND raw_score > 0;  -- FIX-16
    hist_score_early  := COALESCE(hist_score_early,  0.5);
    hist_score_recent := COALESCE(hist_score_recent, 0.5);

    b_score := GREATEST(0.0, LEAST(1.0,
        1.0 / (1.0 + EXP(-3.0 * (hist_score_recent - hist_score_early) / 0.3))));

    -- ⑤ T：趋势（线性回归）
    -- [FIX-16] 只取有练琴的快照（raw_score > 0）做回归，最近8周有练琴的周
    n_points := 0; sum_x:=0; sum_y:=0; sum_xy:=0; sum_x2:=0;
    FOR rec IN SELECT ROW_NUMBER() OVER (ORDER BY snapshot_date ASC) AS x,
                      raw_score AS y
               FROM (SELECT snapshot_date, raw_score FROM public.student_score_history
                     WHERE student_name = p_student_name
                       AND raw_score > 0                  -- FIX-16: 排除缺席周
                     ORDER BY snapshot_date DESC LIMIT 8) sub
    LOOP
        n_points:=n_points+1; sum_x:=sum_x+rec.x; sum_y:=sum_y+rec.y;
        sum_xy:=sum_xy+rec.x*rec.y; sum_x2:=sum_x2+rec.x*rec.x;
    END LOOP;
    IF n_points >= 3 THEN
        slope := COALESCE((n_points*sum_xy - sum_x*sum_y) / NULLIF(n_points*sum_x2 - sum_x*sum_x,0), 0.0);
        t_score := GREATEST(0.0, LEAST(1.0, 1.0/(1.0+EXP(-slope/0.02*3.0))));
    ELSE t_score := 0.5; END IF;

    -- ⑥ M：动量（连续改善周数）
    -- [FIX-16] 只比较有练琴的周，跳过缺席周
    consec_improve:=0; prev_val:=NULL;
    FOR rec IN SELECT raw_score AS y FROM public.student_score_history
               WHERE student_name=p_student_name
                 AND raw_score > 0                        -- FIX-16: 排除缺席周
               ORDER BY snapshot_date DESC LIMIT 12 LOOP
        cur_val := COALESCE(rec.y, 0.0);
        IF prev_val IS NULL THEN prev_val:=cur_val; CONTINUE; END IF;
        IF prev_val > cur_val THEN consec_improve:=consec_improve+1; prev_val:=cur_val; ELSE EXIT; END IF;
    END LOOP;
    m_score := GREATEST(0.0, LEAST(1.0, LN(consec_improve::FLOAT+1.0)/LN(9.0)));

    -- ⑦ A：积累
    DECLARE quality_score FLOAT; accum_raw FLOAT; BEGIN
        quality_score := GREATEST(0.1, LEAST(1.0,
            1.0/(1.0+EXP(-((COALESCE(r.mean_duration,0)-median_mean)/(pop_iqr/1.35))))));
        accum_raw := COALESCE(r.record_count,0)::FLOAT * quality_score;
        a_score   := GREATEST(0.0, LEAST(1.0, LN(accum_raw+1.0)/LN(31.0)));
    END;

    -- ⑧ Velocity（成长加速度，同样排除缺席周）
    DECLARE sx4 FLOAT:=0;sy4 FLOAT:=0;sxy4 FLOAT:=0;sx24 FLOAT:=0;n4 INTEGER:=0;
            sx8 FLOAT:=0;sy8 FLOAT:=0;sxy8 FLOAT:=0;sx28 FLOAT:=0;n8 INTEGER:=0;
            slope4 FLOAT; slope8 FLOAT; BEGIN
        FOR rec IN SELECT ROW_NUMBER() OVER(ORDER BY snapshot_date ASC) AS x,
                          raw_score AS y,
                          ROW_NUMBER() OVER(ORDER BY snapshot_date DESC) AS rn
                   FROM (SELECT snapshot_date, raw_score FROM public.student_score_history
                         WHERE student_name=p_student_name
                           AND raw_score > 0              -- FIX-16: 排除缺席周
                         ORDER BY snapshot_date DESC LIMIT 8) sub LOOP
            n8:=n8+1; sx8:=sx8+rec.x; sy8:=sy8+rec.y; sxy8:=sxy8+rec.x*rec.y; sx28:=sx28+rec.x*rec.x;
            IF rec.rn<=4 THEN n4:=n4+1;sx4:=sx4+rec.x;sy4:=sy4+rec.y;sxy4:=sxy4+rec.x*rec.y;sx24:=sx24+rec.x*rec.x; END IF;
        END LOOP;
        slope4:=CASE WHEN n4>=3 THEN (n4*sxy4-sx4*sy4)/NULLIF(n4*sx24-sx4*sx4,0) ELSE NULL END;
        slope8:=CASE WHEN n8>=3 THEN (n8*sxy8-sx8*sy8)/NULLIF(n8*sx28-sx8*sx8,0) ELSE NULL END;
        velocity:=COALESCE(slope4,0.0)-COALESCE(slope8,0.0);
    END;

    -- ⑨ 权重（基于有练琴快照数量，排除缺席周）
    IF    hist_count < 4  THEN w_baseline:=0.10;w_trend:=0.10;w_momentum:=0.10;w_accum:=0.70;
    ELSIF hist_count < 12 THEN w_baseline:=0.25;w_trend:=0.25;w_momentum:=0.15;w_accum:=0.35;
    ELSE                       w_baseline:=0.30;w_trend:=0.30;w_momentum:=0.20;w_accum:=0.20;
    END IF;

    -- ⑩ 合成 + 异常惩罚
    composite_raw := GREATEST(0.0,LEAST(1.0, w_baseline*b_score+w_trend*t_score+w_momentum*m_score+w_accum*a_score));
    outlier_penalty := CASE WHEN COALESCE(r.outlier_rate,0.0)<=0.4 THEN 1.0
                            ELSE EXP(-5.0*(COALESCE(r.outlier_rate,0.0)-0.4)) END;
    composite_raw := GREATEST(0.0, LEAST(1.0, composite_raw*outlier_penalty));

    -- ⑪ 置信度（使用 hist_count_all 包含缺席周，因为快照越多说明历史越长）
    days_stale := EXTRACT(DAY FROM (NOW()-COALESCE(r.last_updated, NOW()-INTERVAL '999 days')))::FLOAT;
    data_freshness := CASE WHEN days_stale<=7  THEN 1.0
                           WHEN days_stale<=30 THEN 1.0-0.5*((days_stale-7)/23.0)
                           WHEN days_stale<=90 THEN 0.5-0.4*((days_stale-30)/60.0)
                           ELSE 0.1 END;
    weight_conf_val := GREATEST(0.0,LEAST(1.0,
        LEAST(1.0,LN(GREATEST(hist_count_all,1)::FLOAT+1.0)/LN(13.0))
        *(1.0-COALESCE(r.outlier_rate,0.0)*0.5)*data_freshness));

    -- ⑫ 历史最高
    SELECT COALESCE(MAX(h.composite_score),0) INTO v_personal_best
    FROM public.student_score_history h WHERE h.student_name=p_student_name;
    v_personal_best := GREATEST(v_personal_best, ROUND(composite_raw*100)::INT);

    -- ⑬ 写入历史（本周有练琴）
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
        composite_raw, ROUND(composite_raw*100)::INT,
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

    -- ⑭ 写回 student_baseline
    UPDATE public.student_baseline
    SET composite_score  = ROUND(composite_raw*100)::INT,
        raw_score        = composite_raw,
        baseline_score   = b_score,
        trend_score      = t_score,
        momentum_score   = m_score,
        accum_score      = a_score,
        growth_velocity  = COALESCE(velocity,0.0),
        personal_best    = v_personal_best,
        weeks_improving  = consec_improve,
        score_confidence = ROUND(weight_conf_val::NUMERIC,3),
        last_updated     = NOW()
    WHERE student_name = p_student_name;

    RETURN QUERY SELECT ROUND(composite_raw*100)::INT, ROUND(weight_conf_val::NUMERIC,3)::FLOAT;
END;
$$;


-- ================================================================
-- 验证：查看修复前后的差异（选一个有缺席周的学生对比）
-- ================================================================
-- 查看某学生历史快照（包含 0 分缺席周）：
-- SELECT student_name, snapshot_date, raw_score, composite_score,
--        baseline_score, trend_score, momentum_score
-- FROM student_score_history
-- WHERE student_name = '某学生'
-- ORDER BY snapshot_date DESC LIMIT 15;
