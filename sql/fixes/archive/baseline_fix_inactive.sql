-- ================================================================
-- FIX-12：停琴检测（compute_student_score）
-- 日期：2026-03-10
-- 说明：超过 30 天无新练琴 session 的学生不再重算四维成长分，
--       分数冻结、置信度按停琴天数指数衰减，并写入本周冻结快照以保持历史连续。
-- 依赖：已应用 FIX-5（compute_student_score 的 B/A 维度修复）。
-- 执行：在 Supabase SQL Editor 中执行下方整段 CREATE OR REPLACE。
-- ================================================================

-- 若你已有 FIX-5 版本，只需在 compute_student_score 内做两处修改：
--
-- 【1】在 DECLARE 末尾（major_sample_count INTEGER; 后）增加三行：
--     v_days_inactive    FLOAT;
--     v_frozen_score     INT;
--     v_frozen_conf      FLOAT;
--
-- 【2】在 “IF NOT FOUND THEN ... END IF;” 之后、在 “-- ② [FIX-5②] A 维度群体统计” 之前，
--     插入下面 “-- ①+ [FIX-12 停琴检测]” 至 “END IF;” 的整段逻辑。
--
-- 若尚未应用 FIX-5，请直接执行 baseline_fixes_v1.sql 中的 FIX-5 整段（该文件已含 FIX-12）。

-- 以下为「仅停琴检测」逻辑块，供手动合并时复制：
/*
    -- ①+ [FIX-12 停琴检测] 超过 30 天无新 session → 冻结分数，置信度衰减，仍写本周快照以保持历史连续
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

        -- 写入冻结快照，保证 run_weekly_score_update 按周 PERCENT_RANK 时不断档
        INSERT INTO public.student_score_history (
            student_name, snapshot_date,
            mean_duration, std_duration, record_count,
            outlier_rate, short_session_rate,
            raw_score, composite_score,
            baseline_score, trend_score, momentum_score, accum_score
        ) VALUES (
            p_student_name, CURRENT_DATE,
            r.mean_duration, r.std_duration, r.record_count,
            r.outlier_rate, r.short_session_rate,
            r.raw_score, v_frozen_score,
            r.baseline_score, r.trend_score, r.momentum_score, r.accum_score
        )
        ON CONFLICT (student_name, snapshot_date) DO UPDATE SET
            composite_score = EXCLUDED.composite_score,
            raw_score       = EXCLUDED.raw_score,
            mean_duration   = EXCLUDED.mean_duration,
            std_duration    = EXCLUDED.std_duration,
            record_count    = EXCLUDED.record_count,
            outlier_rate    = EXCLUDED.outlier_rate,
            short_session_rate = EXCLUDED.short_session_rate,
            baseline_score  = EXCLUDED.baseline_score,
            trend_score     = EXCLUDED.trend_score,
            momentum_score  = EXCLUDED.momentum_score,
            accum_score     = EXCLUDED.accum_score;

        UPDATE public.student_baseline
        SET score_confidence = ROUND(v_frozen_conf::NUMERIC, 3),
            last_updated     = NOW()
        WHERE student_name = p_student_name;

        RETURN QUERY SELECT v_frozen_score, v_frozen_conf::FLOAT;
        RETURN;
    END IF;
*/

-- 置信度衰减公式：conf_frozen = conf_last × e^(-0.005 × (days - 30))
-- 停琴 30 天：系数 1.0；60 天约 0.86；90 天约 0.74；120 天约 0.64；365 天约 0.16；下限 0.05。
