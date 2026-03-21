-- ================================================================
-- FIX-15: compute_student_score — 写入历史快照前先检查本周是否有练琴
--
-- 根本原因（三层）：
--   1. backfill 正确写 0 给无练琴的周
--   2. backfill 结束后 app.skip_score_trigger 恢复 'off'
--   3. STEP 4 执行 UPDATE student_baseline 触发 trg_fn_compute_score_on_baseline_update
--      → compute_student_score 运行 → 写 97 到 student_score_history
--        ON CONFLICT DO UPDATE → 覆盖了刚写好的 0
--
-- FIX-15 修复点：
--   compute_student_score 写入历史快照时先检查本周是否有练琴：
--     · 本周有练琴记录 → 正常 ON CONFLICT DO UPDATE（最新数据覆盖）
--     · 本周无练琴记录 → ON CONFLICT DO NOTHING（绝不覆盖周批次写的 0）
--                         若本周还没有任何快照 → INSERT 0 占位
--
-- 同时修复：backfill 和 fix 脚本的 STEP 4 baseline 同步用触发器屏蔽
-- ================================================================


-- ================================================================
-- STEP 1: 部署 FIX-15 版 compute_student_score
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
    v_week_monday      DATE;          -- FIX-14: 本周一
    v_has_session_this_week BOOLEAN;  -- FIX-15: 本周是否有练琴
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
        -- 本周无练琴：写入 0 占位（若本周已有快照 → DO NOTHING，绝不覆盖）
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

        -- baseline 表仍保留真实的历史最高分/置信度，但不更新 composite_score
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
    SELECT COUNT(*)::INTEGER, AVG(mean_duration), STDDEV(mean_duration)
    INTO hist_count, hist_mean_dur, hist_std_dur
    FROM public.student_score_history WHERE student_name = p_student_name;
    hist_count    := COALESCE(hist_count, 0);
    hist_mean_dur := COALESCE(hist_mean_dur, r.mean_duration);

    SELECT AVG(raw_score) FILTER (WHERE snapshot_date IN (
               SELECT snapshot_date FROM public.student_score_history
               WHERE student_name = p_student_name ORDER BY snapshot_date ASC LIMIT 5)),
           AVG(raw_score) FILTER (WHERE snapshot_date IN (
               SELECT snapshot_date FROM public.student_score_history
               WHERE student_name = p_student_name ORDER BY snapshot_date DESC LIMIT 5))
    INTO hist_score_early, hist_score_recent
    FROM public.student_score_history WHERE student_name = p_student_name;
    hist_score_early  := COALESCE(hist_score_early,  0.5);
    hist_score_recent := COALESCE(hist_score_recent, 0.5);

    -- ④ B
    b_score := GREATEST(0.0, LEAST(1.0,
        1.0 / (1.0 + EXP(-3.0 * (hist_score_recent - hist_score_early) / 0.3))));

    -- ⑤ T
    n_points := 0; sum_x:=0; sum_y:=0; sum_xy:=0; sum_x2:=0;
    FOR rec IN SELECT ROW_NUMBER() OVER (ORDER BY snapshot_date ASC) AS x,
                      COALESCE(raw_score, 0.5) AS y
               FROM (SELECT snapshot_date, raw_score FROM public.student_score_history
                     WHERE student_name = p_student_name ORDER BY snapshot_date DESC LIMIT 8) sub
    LOOP
        n_points:=n_points+1; sum_x:=sum_x+rec.x; sum_y:=sum_y+rec.y;
        sum_xy:=sum_xy+rec.x*rec.y; sum_x2:=sum_x2+rec.x*rec.x;
    END LOOP;
    IF n_points >= 3 THEN
        slope := COALESCE((n_points*sum_xy - sum_x*sum_y) / NULLIF(n_points*sum_x2 - sum_x*sum_x,0), 0.0);
        t_score := GREATEST(0.0, LEAST(1.0, 1.0/(1.0+EXP(-slope/0.02*3.0))));
    ELSE t_score := 0.5; END IF;

    -- ⑥ M
    consec_improve:=0; prev_val:=NULL;
    FOR rec IN SELECT raw_score AS y FROM public.student_score_history
               WHERE student_name=p_student_name ORDER BY snapshot_date DESC LIMIT 12 LOOP
        cur_val := COALESCE(rec.y, 0.0);
        IF prev_val IS NULL THEN prev_val:=cur_val; CONTINUE; END IF;
        IF prev_val > cur_val THEN consec_improve:=consec_improve+1; prev_val:=cur_val; ELSE EXIT; END IF;
    END LOOP;
    m_score := GREATEST(0.0, LEAST(1.0, LN(consec_improve::FLOAT+1.0)/LN(9.0)));

    -- ⑦ A
    DECLARE quality_score FLOAT; accum_raw FLOAT; BEGIN
        quality_score := GREATEST(0.1, LEAST(1.0,
            1.0/(1.0+EXP(-((COALESCE(r.mean_duration,0)-median_mean)/(pop_iqr/1.35))))));
        accum_raw := COALESCE(r.record_count,0)::FLOAT * quality_score;
        a_score   := GREATEST(0.0, LEAST(1.0, LN(accum_raw+1.0)/LN(31.0)));
    END;

    -- ⑧ Velocity
    DECLARE sx4 FLOAT:=0;sy4 FLOAT:=0;sxy4 FLOAT:=0;sx24 FLOAT:=0;n4 INTEGER:=0;
            sx8 FLOAT:=0;sy8 FLOAT:=0;sxy8 FLOAT:=0;sx28 FLOAT:=0;n8 INTEGER:=0;
            slope4 FLOAT; slope8 FLOAT; BEGIN
        FOR rec IN SELECT ROW_NUMBER() OVER(ORDER BY snapshot_date ASC) AS x,
                          COALESCE(raw_score,0.5) AS y,
                          ROW_NUMBER() OVER(ORDER BY snapshot_date DESC) AS rn
                   FROM (SELECT snapshot_date,raw_score FROM public.student_score_history
                         WHERE student_name=p_student_name ORDER BY snapshot_date DESC LIMIT 8) sub LOOP
            n8:=n8+1; sx8:=sx8+rec.x; sy8:=sy8+rec.y; sxy8:=sxy8+rec.x*rec.y; sx28:=sx28+rec.x*rec.x;
            IF rec.rn<=4 THEN n4:=n4+1;sx4:=sx4+rec.x;sy4:=sy4+rec.y;sxy4:=sxy4+rec.x*rec.y;sx24:=sx24+rec.x*rec.x; END IF;
        END LOOP;
        slope4:=CASE WHEN n4>=3 THEN (n4*sxy4-sx4*sy4)/NULLIF(n4*sx24-sx4*sx4,0) ELSE NULL END;
        slope8:=CASE WHEN n8>=3 THEN (n8*sxy8-sx8*sy8)/NULLIF(n8*sx28-sx8*sx8,0) ELSE NULL END;
        velocity:=COALESCE(slope4,0.0)-COALESCE(slope8,0.0);
    END;

    -- ⑨ 权重
    IF    hist_count < 4  THEN w_baseline:=0.10;w_trend:=0.10;w_momentum:=0.10;w_accum:=0.70;
    ELSIF hist_count < 12 THEN w_baseline:=0.25;w_trend:=0.25;w_momentum:=0.15;w_accum:=0.35;
    ELSE                       w_baseline:=0.30;w_trend:=0.30;w_momentum:=0.20;w_accum:=0.20;
    END IF;

    -- ⑩ 合成 + 惩罚
    composite_raw := GREATEST(0.0,LEAST(1.0, w_baseline*b_score+w_trend*t_score+w_momentum*m_score+w_accum*a_score));
    outlier_penalty := CASE WHEN COALESCE(r.outlier_rate,0.0)<=0.4 THEN 1.0
                            ELSE EXP(-5.0*(COALESCE(r.outlier_rate,0.0)-0.4)) END;
    composite_raw := GREATEST(0.0, LEAST(1.0, composite_raw*outlier_penalty));

    -- ⑫ 置信度
    days_stale := EXTRACT(DAY FROM (NOW()-COALESCE(r.last_updated, NOW()-INTERVAL '999 days')))::FLOAT;
    data_freshness := CASE WHEN days_stale<=7  THEN 1.0
                           WHEN days_stale<=30 THEN 1.0-0.5*((days_stale-7)/23.0)
                           WHEN days_stale<=90 THEN 0.5-0.4*((days_stale-30)/60.0)
                           ELSE 0.1 END;
    weight_conf_val := GREATEST(0.0,LEAST(1.0,
        LEAST(1.0,LN(GREATEST(hist_count,1)::FLOAT+1.0)/LN(13.0))
        *(1.0-COALESCE(r.outlier_rate,0.0)*0.5)*data_freshness));

    -- ⑬ 历史最高
    SELECT COALESCE(MAX(h.composite_score),0) INTO v_personal_best
    FROM public.student_score_history h WHERE h.student_name=p_student_name;
    v_personal_best := GREATEST(v_personal_best, ROUND(composite_raw*100)::INT);

    -- ⑭ [FIX-14+FIX-15] 写入历史（本周有练琴 → DO UPDATE；否则上面已 RETURN）
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

    -- ⑮ 写回 student_baseline
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
-- STEP 2: 立即修正当前周快照（将本周无练琴的学生快照强制归零）
-- ================================================================
DO $$
DECLARE
    v_monday DATE := DATE_TRUNC('week', CURRENT_DATE)::DATE;
    v_fixed  INTEGER := 0;
BEGIN
    -- 对本周无练琴但快照有分数的学生：更新为 0
    UPDATE public.student_score_history
    SET composite_score = 0,
        raw_score       = 0,
        baseline_score  = NULL,
        trend_score     = NULL,
        momentum_score  = NULL,
        accum_score     = NULL
    WHERE snapshot_date = v_monday
      AND composite_score > 0
      AND student_name NOT IN (
          SELECT DISTINCT student_name
          FROM public.practice_sessions
          WHERE cleaned_duration > 0
            AND session_start >= v_monday::TIMESTAMPTZ
      );

    GET DIAGNOSTICS v_fixed = ROW_COUNT;
    RAISE NOTICE '当前周快照修正完成：共修正 % 位学生', v_fixed;

    -- 对本周无练琴且还没有快照的学生：插入 0
    INSERT INTO public.student_score_history
        (student_name, snapshot_date, raw_score, composite_score,
         baseline_score, trend_score, momentum_score, accum_score,
         outlier_rate, short_session_rate, mean_duration, record_count)
    SELECT b.student_name, v_monday, 0, 0,
           NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    FROM public.student_baseline b
    WHERE NOT EXISTS (
        SELECT 1 FROM public.practice_sessions ps
        WHERE ps.student_name   = b.student_name
          AND ps.cleaned_duration > 0
          AND ps.session_start  >= v_monday::TIMESTAMPTZ
    )
    AND NOT EXISTS (
        SELECT 1 FROM public.student_score_history h
        WHERE h.student_name  = b.student_name
          AND h.snapshot_date = v_monday
    );

    GET DIAGNOSTICS v_fixed = ROW_COUNT;
    RAISE NOTICE '新增 0 分占位快照：% 位学生', v_fixed;
END;
$$;


-- ================================================================
-- STEP 3: 修复 backfill_score_history 的 baseline sync 步骤
--         （在 STEP 4 的 baseline 最终同步前后禁用触发器）
-- ================================================================
CREATE OR REPLACE FUNCTION public.backfill_score_history()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_start_date    DATE;
    v_end_date      DATE;
    v_current_date  DATE;
    v_next_date     DATE;
    v_student       RECORD;
    v_week_count    INTEGER := 0;
    v_active_count  INTEGER := 0;
    v_zero_count    INTEGER := 0;
    v_student_count INTEGER;
BEGIN
    PERFORM set_config('app.skip_score_trigger', 'on', TRUE);

    SELECT DATE_TRUNC('week', MIN(session_start))::DATE INTO v_start_date
    FROM public.practice_sessions WHERE cleaned_duration > 0;

    v_end_date     := DATE_TRUNC('week', CURRENT_DATE)::DATE;
    v_current_date := v_start_date;
    RAISE NOTICE '回溯范围：% → %（FIX-15）', v_start_date, v_end_date;

    WHILE v_current_date <= v_end_date LOOP
        v_week_count := v_week_count + 1;
        v_next_date  := v_current_date + INTERVAL '7 days';

        -- ① baseline
        FOR v_student IN
            SELECT DISTINCT student_name FROM public.practice_sessions
            WHERE session_start < v_current_date::TIMESTAMPTZ AND cleaned_duration > 0
            ORDER BY student_name
        LOOP
            BEGIN
                PERFORM public.compute_baseline_as_of(v_student.student_name, v_current_date);
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '[backfill baseline] % @ % 失败：%', v_student.student_name, v_current_date, SQLERRM;
            END;
        END LOOP;

        -- ② 成长分：本周活跃 → 重算；本周无练 → 写 0
        FOR v_student IN
            SELECT DISTINCT student_name FROM public.practice_sessions
            WHERE session_start < v_current_date::TIMESTAMPTZ AND cleaned_duration > 0
            ORDER BY student_name
        LOOP
            BEGIN
                IF EXISTS (
                    SELECT 1 FROM public.practice_sessions
                    WHERE student_name    = v_student.student_name
                      AND cleaned_duration > 0
                      AND session_start  >= v_current_date::TIMESTAMPTZ
                      AND session_start  <  v_next_date::TIMESTAMPTZ
                ) THEN
                    PERFORM public.compute_student_score_as_of(v_student.student_name, v_current_date);
                    v_active_count := v_active_count + 1;
                ELSE
                    INSERT INTO public.student_score_history
                        (student_name, snapshot_date, raw_score, composite_score,
                         baseline_score, trend_score, momentum_score, accum_score,
                         outlier_rate, short_session_rate, mean_duration, record_count)
                    VALUES
                        (v_student.student_name, v_current_date, 0, 0,
                         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
                    ON CONFLICT (student_name, snapshot_date) DO NOTHING;
                    v_zero_count := v_zero_count + 1;
                END IF;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '[backfill score] % @ % 失败：%', v_student.student_name, v_current_date, SQLERRM;
            END;
        END LOOP;

        -- ③ PERCENT_RANK（仅活跃学生）
        SELECT COUNT(DISTINCT sh.student_name) INTO v_student_count
        FROM public.student_score_history sh
        WHERE sh.snapshot_date = v_current_date
          AND sh.raw_score IS NOT NULL AND sh.raw_score > 0
          AND EXISTS (
              SELECT 1 FROM public.practice_sessions ps
              WHERE ps.student_name    = sh.student_name
                AND ps.cleaned_duration > 0
                AND ps.session_start  >= v_current_date::TIMESTAMPTZ
                AND ps.session_start  <  v_next_date::TIMESTAMPTZ);

        IF v_student_count >= 5 THEN
            UPDATE public.student_score_history h
            SET composite_score = norm.normalized
            FROM (
                SELECT sh.student_name,
                       ROUND(PERCENT_RANK() OVER (ORDER BY sh.raw_score) * 100)::INT AS normalized
                FROM public.student_score_history sh
                WHERE sh.snapshot_date = v_current_date
                  AND sh.raw_score IS NOT NULL AND sh.raw_score > 0
                  AND EXISTS (
                      SELECT 1 FROM public.practice_sessions ps
                      WHERE ps.student_name    = sh.student_name
                        AND ps.cleaned_duration > 0
                        AND ps.session_start  >= v_current_date::TIMESTAMPTZ
                        AND ps.session_start  <  v_next_date::TIMESTAMPTZ)
            ) norm
            WHERE h.snapshot_date = v_current_date AND h.student_name = norm.student_name;
        ELSE
            UPDATE public.student_score_history
            SET composite_score = ROUND(raw_score * 100)::INT
            WHERE snapshot_date = v_current_date
              AND raw_score IS NOT NULL AND raw_score > 0
              AND EXISTS (
                  SELECT 1 FROM public.practice_sessions ps
                  WHERE ps.student_name    = student_score_history.student_name
                    AND ps.cleaned_duration > 0
                    AND ps.session_start  >= v_current_date::TIMESTAMPTZ
                    AND ps.session_start  <  v_next_date::TIMESTAMPTZ);
        END IF;

        v_current_date := v_next_date;
    END LOOP;

    -- ④ [FIX-15] 同步最新有效分数到 student_baseline
    --    触发器仍处于关闭状态，防止 UPDATE 触发 compute_student_score 覆盖快照
    UPDATE public.student_baseline b
    SET composite_score = latest.composite_score
    FROM (
        SELECT DISTINCT ON (student_name) student_name, composite_score
        FROM public.student_score_history
        WHERE composite_score > 0
        ORDER BY student_name, snapshot_date DESC
    ) latest
    WHERE b.student_name = latest.student_name;

    -- ⑤ FIX-53: 刷新所有学生的实时 W 分
    --    backfill 仅重算历史周快照，不自动更新 student_baseline.w_score
    --    此处补充调用 compute_and_store_w_score 确保 W 卡片显示最新值
    FOR v_student IN SELECT DISTINCT student_name FROM public.student_baseline LOOP
        BEGIN
            PERFORM public.compute_and_store_w_score(v_student.student_name);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[backfill w_score] % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
    RAISE NOTICE '回溯完成（FIX-15）：共 % 周，重算 % 条，零分 % 条',
        v_week_count, v_active_count, v_zero_count;
END;
$$;


-- ================================================================
-- STEP 4: 重建历史（清理并重跑 backfill，触发器在内部管理）
-- ================================================================
TRUNCATE public.student_score_history;
SELECT public.backfill_score_history();


-- ================================================================
-- 验证：当前周无练琴的学生是否全部为 0
-- ================================================================
-- SELECT student_name, composite_score
-- FROM public.student_score_history
-- WHERE snapshot_date = DATE_TRUNC('week', CURRENT_DATE)::DATE
--   AND composite_score > 0
--   AND student_name NOT IN (
--       SELECT DISTINCT student_name FROM practice_sessions
--       WHERE session_start >= DATE_TRUNC('week', CURRENT_DATE)
--         AND cleaned_duration > 0
--   );
-- 结果应为空（0 行）
