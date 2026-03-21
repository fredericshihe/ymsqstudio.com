-- ================================================================
-- 练琴基线监控系统 — 修复补丁 v1.0
-- 日期：2026-03-10
-- 说明：按顺序在 Supabase SQL Editor 中逐段执行
-- ================================================================


-- ================================================================
-- FIX-1: clean_duration — 冷启动保护 + std=0/NULL 保护
-- 原问题：冷启动期 std=NULL 导致个人离群检测完全跳过；
--         std=0 时所有高于均值的记录都会被错误压缩。
-- 修复：record_count<10 或 std≤1.0 时改用全局硬上限 180 分钟
-- ================================================================
CREATE OR REPLACE FUNCTION public.clean_duration(student TEXT, raw_dur FLOAT)
RETURNS TABLE(cleaned_dur FLOAT, is_outlier BOOL, reason TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    student_mean      FLOAT;
    student_std       FLOAT;
    record_cnt        INTEGER;
    last_session_date TIMESTAMPTZ;
    days_since_last   INTEGER;
    use_personal_det  BOOLEAN;
BEGIN
    SELECT mean_duration, std_duration, record_count
    INTO student_mean, student_std, record_cnt
    FROM public.student_baseline
    WHERE student_name = student;

    -- 无时长
    IF raw_dur IS NULL THEN
        RETURN QUERY SELECT 0::FLOAT, TRUE, 'no_duration'::TEXT;
        RETURN;
    END IF;

    -- 太短：< 5 分钟，无效
    IF raw_dur < 5 THEN
        RETURN QUERY SELECT 0::FLOAT, TRUE, 'too_short'::TEXT;
        RETURN;
    END IF;

    -- FIX-53: 停练归来检测——查最近一次有效练琴时间间隔
    -- 若 > 30 天无练琴，说明 baseline 均值是旧数据，降级为全局检测，避免误判
    SELECT MAX(session_start) INTO last_session_date
    FROM public.practice_sessions
    WHERE student_name = student AND cleaned_duration > 0;

    days_since_last := COALESCE(
        EXTRACT(DAYS FROM (NOW() - last_session_date))::INTEGER,
        999
    );

    -- 同时满足以下全部条件才使用个人离群检测：
    -- ① 已有足够历史（record_count >= 10）
    -- ② std 可靠（> 1.0）
    -- ③ 近期有持续练琴（30天内）—— FIX-53 新增
    use_personal_det := student_mean IS NOT NULL
                    AND student_std IS NOT NULL
                    AND student_std > 1.0
                    AND COALESCE(record_cnt, 0) >= 10
                    AND days_since_last <= 30;

    IF use_personal_det THEN
        IF raw_dur > student_mean + 3 * student_std THEN
            RETURN QUERY SELECT (student_mean + student_std)::FLOAT, TRUE, 'personal_outlier'::TEXT;
            RETURN;
        END IF;
    ELSE
        -- 冷启动期 / std 不可靠 / 停练归来：改用全局硬上限 180 分钟
        IF raw_dur > 180 THEN
            RETURN QUERY SELECT 120::FLOAT, TRUE,
                CASE WHEN days_since_last > 30
                     THEN 'global_cap_returning'   -- 停练归来降级标记
                     ELSE 'global_cap_cold_start'
                END::TEXT;
            RETURN;
        END IF;
    END IF;

    -- 超长：> 120 分钟，截断为 120 分钟，视为有效练习（不标记异常）
    IF raw_dur > 120 THEN
        RETURN QUERY SELECT 120::FLOAT, FALSE, 'capped_120'::TEXT;
        RETURN;
    END IF;

    -- 正常
    RETURN QUERY SELECT raw_dur, FALSE, NULL::TEXT;
END;
$$;


-- ================================================================
-- FIX-2: compute_baseline_as_of — 三处修复：
--   ① std 处理：< 2 条记录时保留 NULL，过小时设最小值 1.0
--   ② alpha 波动项：从基于 mean 的伪波动改为基于 CV 的真实波动
--   ③ last_updated：p_as_of_date 为未来日期时写 NOW()，避免写入未来时间戳
-- ================================================================
CREATE OR REPLACE FUNCTION public.compute_baseline_as_of(
    p_student_name TEXT,
    p_as_of_date   DATE
)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_mean          FLOAT;
    v_std           FLOAT;
    v_count         INTEGER;
    v_outlier_rate  FLOAT;
    v_short_rate    FLOAT;
    v_alpha         FLOAT;
    v_cv            FLOAT;   -- [FIX-2①] 变异系数
    v_group_alpha   FLOAT;
    v_lambda        FLOAT;
    v_weekday_json  JSONB;
    v_student_major TEXT;
    v_student_grade TEXT;
    v_last_updated  TIMESTAMPTZ; -- [FIX-2③]
BEGIN
    -- ① meta 信息（截止日期前最近一条工作日练琴）
    SELECT student_major, student_grade
    INTO v_student_major, v_student_grade
    FROM public.practice_sessions
    WHERE student_name  = p_student_name
      AND session_start < p_as_of_date::TIMESTAMPTZ
      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    ORDER BY session_start DESC
    LIMIT 1;

    IF NOT FOUND THEN RETURN; END IF;

    -- ② 有效记录：截止日期前最近30条（仅工作日，与 B/T/M/W 保持一致）
    WITH recent_valid AS (
        SELECT cleaned_duration
        FROM public.practice_sessions
        WHERE student_name     = p_student_name
          AND cleaned_duration > 0
          AND session_start    < p_as_of_date::TIMESTAMPTZ
          AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
        ORDER BY session_start DESC
        LIMIT 30
    )
    SELECT COUNT(*)::INTEGER, AVG(cleaned_duration), STDDEV(cleaned_duration)
    INTO v_count, v_mean, v_std
    FROM recent_valid;

    IF COALESCE(v_count, 0) = 0 THEN RETURN; END IF;

    -- [FIX-2①] std 保护：< 2 条时无意义保留 NULL；过小时设最小值 1.0
    v_std := CASE
        WHEN v_count < 2             THEN NULL
        WHEN COALESCE(v_std, 0) < 1.0 THEN 1.0
        ELSE v_std
    END;

    -- [FIX-2①] CV（变异系数）= std / mean
    v_cv := CASE
        WHEN COALESCE(v_mean, 0) > 0 AND v_std IS NOT NULL
            THEN v_std / v_mean
        ELSE 0.5  -- 无均值或 std 不可用时视为中等波动
    END;

    -- ③ 异常率 & 短时率（仅工作日）
    SELECT
        AVG(CASE WHEN is_outlier THEN 1.0 ELSE 0.0 END),
        AVG(CASE WHEN cleaned_duration >= 5 AND cleaned_duration < 30 THEN 1.0 ELSE 0.0 END)
    INTO v_outlier_rate, v_short_rate
    FROM (
        SELECT is_outlier, cleaned_duration
        FROM public.practice_sessions
        WHERE student_name  = p_student_name
          AND session_start < p_as_of_date::TIMESTAMPTZ
          AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
        ORDER BY session_start DESC
        LIMIT 30
    ) recent;

    -- ④ 星期分布（仅工作日，周一~周五）
    WITH recent_dow AS (
        SELECT EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai')::INTEGER AS dow
        FROM public.practice_sessions
        WHERE student_name     = p_student_name
          AND cleaned_duration > 0
          AND session_start    < p_as_of_date::TIMESTAMPTZ
          AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
        ORDER BY session_start DESC
        LIMIT 30
    )
    SELECT jsonb_object_agg(dow::TEXT, cnt)
    INTO v_weekday_json
    FROM (SELECT dow, COUNT(*) AS cnt FROM recent_dow GROUP BY dow) agg;

    -- ⑤ [FIX-2② + FIX-47] alpha 计算
    --   FIX-47：异常率惩罚分段加速（旧 0.02×rate 最多仅扣2%，已过小）
    --     rate ≤ 30%: 0.08 × rate
    --     rate  > 30%: 0.024 + 0.40 × (rate - 0.30)
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

    -- ⑥ 冷启动混合
    -- 0.82 来源：60分钟均值时的理论 alpha = 1.0-LEAST(0.15,5/60)-LEAST(0.20,0.3*0.15) ≈ 0.82
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
                  AND session_start    < p_as_of_date::TIMESTAMPTZ
                  AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
            ) sub
            WHERE rn <= 30
            GROUP BY student_name
            HAVING COUNT(*) >= 10
        ) grp
        CROSS JOIN LATERAL (
            SELECT
                1.0
                - LEAST(0.15, 5.0 / NULLIF(grp.mean_dur, 0))
                - LEAST(0.20, CASE WHEN NULLIF(grp.mean_dur, 0) IS NOT NULL
                                   THEN (10.0 / grp.mean_dur) * 0.15
                                   ELSE 0.5 * 0.15 END)
                AS mean_alpha
        ) calc;

        -- 降级：若同专业同年级无足够样本，扩大至仅按专业匹配
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
                      AND session_start    < p_as_of_date::TIMESTAMPTZ
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

    -- ⑦ 硬截断
    v_alpha := GREATEST(0.5, LEAST(1.0, v_alpha));

    -- [FIX-2③] last_updated：未来日期（如明天）写 NOW()，历史日期写原日期
    v_last_updated := CASE
        WHEN p_as_of_date > CURRENT_DATE THEN NOW()
        ELSE p_as_of_date::TIMESTAMPTZ
    END;

    -- ⑧ UPSERT
    INSERT INTO public.student_baseline (
        student_name, student_major, student_grade,
        mean_duration, std_duration,
        outlier_rate, short_session_rate,
        alpha, record_count,
        weekday_pattern, is_cold_start, last_updated
    ) VALUES (
        p_student_name, v_student_major, v_student_grade,
        COALESCE(v_mean, 0), v_std,         -- [FIX-2①] std 保留 NULL
        COALESCE(v_outlier_rate, 0), COALESCE(v_short_rate, 0),
        v_alpha, COALESCE(v_count, 0),
        COALESCE(v_weekday_json, '{}'::JSONB),
        (COALESCE(v_count, 0) < 10),
        v_last_updated                       -- [FIX-2③]
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


-- ================================================================
-- FIX-3: compute_baseline — 改为薄封装，消除代码重复
-- 原问题：compute_baseline 与 compute_baseline_as_of 逻辑几乎完全重复，
--         修改一处必须同步修改另一处，极易遗漏。
-- 修复：compute_baseline 只是 compute_baseline_as_of 的薄封装
-- ================================================================
CREATE OR REPLACE FUNCTION public.compute_baseline(p_student_name TEXT)
RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    -- 传入明天：过滤条件 < p_as_of_date 等价于 <= 今天，包含今天所有数据
    -- last_updated 在 as_of 内部会判断未来日期并写 NOW()
    PERFORM public.compute_baseline_as_of(
        p_student_name,
        (CURRENT_DATE + INTERVAL '1 day')::DATE
    );
END;
$$;


-- ================================================================
-- FIX-4: 删除双触发器路径 — 移除 practice_logs 上的 trg_baseline_update
-- 原问题：一次练琴结束可能同时触发两条基线更新路径：
--   路径1：practice_logs → trg_baseline_update（每5条）→ compute_baseline
--   路径2：practice_logs → trg_insert_session → practice_sessions
--           → trg_update_baseline（动态）→ compute_baseline
-- 两路径在同一事务内可能产生竞态条件，浪费计算资源。
-- 修复：只保留路径2（基于已清洗的 practice_sessions，语义更合理）
-- ================================================================
DROP TRIGGER IF EXISTS trg_baseline_update ON public.practice_logs;

-- 验证：practice_logs 上只剩 trg_insert_session
SELECT trigger_name, action_statement
FROM information_schema.triggers
WHERE trigger_schema = 'public'
  AND event_object_table = 'practice_logs'
  AND event_manipulation = 'INSERT';


-- ================================================================
-- FIX-5: compute_student_score — 两处修复：
--   ① B 维度：分母改为固定归一化系数 0.3，消除低基数学生虚高
--   ② A 维度：IQR 优先按同专业计算，人数不足时回落全体
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
    v_days_inactive    FLOAT;   -- 停琴检测：距最近一次 session 的天数
    v_frozen_score     INT;     -- 停琴时冻结的 composite_score
    v_frozen_conf      FLOAT;   -- 停琴时衰减后的置信度
BEGIN
    -- ① 读取当前学生基线（先读 r，因为 IQR 需要用 r.student_major）
    SELECT * INTO r
    FROM public.student_baseline
    WHERE student_name = p_student_name;

    IF NOT FOUND THEN
        RETURN QUERY SELECT 0::INT, 0::FLOAT;
        RETURN;
    END IF;

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

    -- ② [FIX-5②] A 维度群体统计：优先同专业，不足5人时回落全体
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
          AND student_major = r.student_major;  -- 同专业
    ELSE
        SELECT
            percentile_cont(0.25) WITHIN GROUP (ORDER BY mean_duration),
            percentile_cont(0.50) WITHIN GROUP (ORDER BY mean_duration),
            percentile_cont(0.75) WITHIN GROUP (ORDER BY mean_duration)
        INTO p25_mean, median_mean, p75_mean
        FROM public.student_baseline
        WHERE mean_duration IS NOT NULL AND mean_duration > 0;  -- 全体回落
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

    -- 早期 / 近期 raw_score 均值
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

    -- ④ [FIX-5①] B：Baseline Progress
    -- 旧：/ GREATEST(hist_score_early, 0.01)  →  低基数学生虚高
    -- 新：/ 0.3  →  固定归一化系数，0.3 为 raw_score 典型有意义变化幅度
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

    -- ⑥ M：Momentum（连续改善周数，基于 raw_score）
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

    -- ⑦ A：Accumulation（记录数 × 质量分）
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

    -- ⑭ 写入历史快照
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
-- FIX-6: compute_student_score_as_of — 同步 FIX-5 的 B 和 A 维度修复
-- ================================================================
CREATE OR REPLACE FUNCTION public.compute_student_score_as_of(
    p_student_name  TEXT,
    p_snapshot_date DATE
)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    median_mean        FLOAT;
    p25_mean           FLOAT;
    p75_mean           FLOAT;
    pop_iqr            FLOAT;
    median_stddev      FLOAT;
    r                  RECORD;
    hist_count         INTEGER;
    hist_mean_dur      FLOAT;
    hist_score_early   FLOAT;
    hist_score_recent  FLOAT;
    b_score            FLOAT;
    t_score            FLOAT;
    m_score            FLOAT;
    a_score            FLOAT;
    slope              FLOAT;
    n_points           INTEGER;
    sum_x              FLOAT := 0;
    sum_y              FLOAT := 0;
    sum_xy             FLOAT := 0;
    sum_x2             FLOAT := 0;
    rec                RECORD;
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
    p_best             INTEGER;
    major_sample_count INTEGER;
BEGIN
    -- ① 读取当前学生基线
    SELECT * INTO r
    FROM public.student_baseline
    WHERE student_name = p_student_name;

    IF NOT FOUND THEN RETURN; END IF;

    -- ② [FIX-6] A 维度群体统计：优先同专业，不足5人时回落全体
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
    FROM public.student_baseline WHERE std_duration IS NOT NULL;
    median_stddev := GREATEST(COALESCE(median_stddev, 1.0), 1.0);

    -- ③ 历史快照统计（只看该快照日期之前）
    SELECT COUNT(*)::INTEGER, AVG(mean_duration)
    INTO hist_count, hist_mean_dur
    FROM public.student_score_history
    WHERE student_name = p_student_name AND snapshot_date < p_snapshot_date;

    hist_count    := COALESCE(hist_count, 0);
    hist_mean_dur := COALESCE(hist_mean_dur, r.mean_duration);

    SELECT
        AVG(raw_score) FILTER (
            WHERE snapshot_date IN (
                SELECT snapshot_date FROM public.student_score_history
                WHERE student_name = p_student_name AND snapshot_date < p_snapshot_date
                ORDER BY snapshot_date ASC LIMIT 5
            )
        ),
        AVG(raw_score) FILTER (
            WHERE snapshot_date IN (
                SELECT snapshot_date FROM public.student_score_history
                WHERE student_name = p_student_name AND snapshot_date < p_snapshot_date
                ORDER BY snapshot_date DESC LIMIT 5
            )
        )
    INTO hist_score_early, hist_score_recent
    FROM public.student_score_history
    WHERE student_name = p_student_name AND snapshot_date < p_snapshot_date;

    hist_score_early  := COALESCE(hist_score_early,  0.5);
    hist_score_recent := COALESCE(hist_score_recent, 0.5);

    -- ④ [FIX-6] B：Baseline Progress（同 FIX-5①，分母改为 0.3）
    b_score := 1.0 / (1.0 + EXP(
        -3.0 * (hist_score_recent - hist_score_early) / 0.3
    ));
    b_score := GREATEST(0.0, LEAST(1.0, b_score));

    -- ⑤ T：Trend
    n_points := 0;
    sum_x := 0; sum_y := 0; sum_xy := 0; sum_x2 := 0;

    FOR rec IN
        SELECT
            ROW_NUMBER() OVER (ORDER BY snapshot_date ASC) AS x,
            COALESCE(raw_score, 0.5) AS y
        FROM (
            SELECT snapshot_date, raw_score FROM public.student_score_history
            WHERE student_name = p_student_name AND snapshot_date < p_snapshot_date
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
        t_score := 1.0 / (1.0 + EXP(-COALESCE(slope, 0.0) / 0.02 * 3.0));
    ELSE
        t_score := 0.5;
    END IF;
    t_score := GREATEST(0.0, LEAST(1.0, t_score));

    -- ⑥ M：Momentum（基于 raw_score）
    consec_improve := 0; prev_val := NULL;
    FOR rec IN
        SELECT raw_score AS y FROM public.student_score_history
        WHERE student_name = p_student_name AND snapshot_date < p_snapshot_date
        ORDER BY snapshot_date DESC LIMIT 12
    LOOP
        cur_val := COALESCE(rec.y, 0.0);
        IF prev_val IS NULL THEN prev_val := cur_val; CONTINUE; END IF;
        IF prev_val > cur_val THEN consec_improve := consec_improve + 1; prev_val := cur_val;
        ELSE EXIT; END IF;
    END LOOP;
    m_score := GREATEST(0.0, LEAST(1.0, LN(consec_improve::FLOAT + 1.0) / LN(9.0)));

    -- ⑦ A：Accumulation
    DECLARE quality_score FLOAT; accum_raw FLOAT; BEGIN
        quality_score := GREATEST(0.1, LEAST(1.0,
            1.0 / (1.0 + EXP(-((COALESCE(r.mean_duration,0) - median_mean) / (pop_iqr/1.35))))
        ));
        accum_raw := COALESCE(r.record_count, 0)::FLOAT * quality_score;
        a_score   := GREATEST(0.0, LEAST(1.0, LN(accum_raw + 1.0) / LN(31.0)));
    END;

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
                WHERE student_name = p_student_name AND snapshot_date < p_snapshot_date
                ORDER BY snapshot_date DESC LIMIT 8
            ) sub
        LOOP
            n8 := n8+1; sx8 := sx8+rec.x; sy8 := sy8+rec.y;
            sxy8 := sxy8+rec.x*rec.y; sx28 := sx28+rec.x*rec.x;
            IF rec.rn <= 4 THEN
                n4 := n4+1; sx4 := sx4+rec.x; sy4 := sy4+rec.y;
                sxy4 := sxy4+rec.x*rec.y; sx24 := sx24+rec.x*rec.x;
            END IF;
        END LOOP;
        slope4 := CASE WHEN n4>=3 THEN (n4*sxy4-sx4*sy4)/NULLIF(n4*sx24-sx4*sx4,0) ELSE NULL END;
        slope8 := CASE WHEN n8>=3 THEN (n8*sxy8-sx8*sy8)/NULLIF(n8*sx28-sx8*sx8,0) ELSE NULL END;
        velocity := COALESCE(slope4, 0.0) - COALESCE(slope8, 0.0);
    END;

    -- ⑨ 动态权重
    IF hist_count < 4 THEN
        w_baseline:=0.10; w_trend:=0.10; w_momentum:=0.10; w_accum:=0.70;
    ELSIF hist_count < 12 THEN
        w_baseline:=0.25; w_trend:=0.25; w_momentum:=0.15; w_accum:=0.35;
    ELSE
        w_baseline:=0.30; w_trend:=0.30; w_momentum:=0.20; w_accum:=0.20;
    END IF;

    composite_raw := GREATEST(0.0, LEAST(1.0,
        w_baseline*b_score + w_trend*t_score + w_momentum*m_score + w_accum*a_score
    ));

    outlier_penalty := CASE
        WHEN COALESCE(r.outlier_rate, 0.0) <= 0.4 THEN 1.0
        ELSE EXP(-5.0 * (COALESCE(r.outlier_rate, 0.0) - 0.4))
    END;
    composite_raw := GREATEST(0.0, LEAST(1.0, composite_raw * outlier_penalty));

    -- 置信度（用 p_snapshot_date 避免 freshness 恒为 1）
    days_stale := EXTRACT(
        DAY FROM (p_snapshot_date::TIMESTAMPTZ
                  - COALESCE(r.last_updated, p_snapshot_date::TIMESTAMPTZ - INTERVAL '999 days'))
    )::FLOAT;
    data_freshness := CASE
        WHEN days_stale <= 7  THEN 1.0
        WHEN days_stale <= 30 THEN 1.0 - 0.5 * ((days_stale - 7) / 23.0)
        WHEN days_stale <= 90 THEN 0.5 - 0.4 * ((days_stale - 30) / 60.0)
        ELSE 0.1
    END;
    weight_conf_val := GREATEST(0.0, LEAST(1.0,
        LEAST(1.0, LN(GREATEST(hist_count,1)::FLOAT+1.0)/LN(13.0))
        * (1.0 - COALESCE(r.outlier_rate,0.0)*0.5)
        * data_freshness
    ));

    SELECT COALESCE(MAX(composite_score), 0) INTO p_best
    FROM public.student_score_history
    WHERE student_name = p_student_name AND snapshot_date < p_snapshot_date;
    p_best := GREATEST(p_best, ROUND(composite_raw * 100)::INT);

    INSERT INTO public.student_score_history (
        student_name, snapshot_date,
        mean_duration, std_duration, record_count,
        outlier_rate, short_session_rate,
        raw_score, composite_score,
        baseline_score, trend_score, momentum_score, accum_score
    ) VALUES (
        p_student_name, p_snapshot_date,
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
END;
$$;


-- ================================================================
-- FIX-7: backfill_score_history — 两处修复：
--   ① 每个学生的计算用 BEGIN/EXCEPTION 包裹，单个失败不中断整体
--   ② PERCENT_RANK 人数保护：< 5 人时跳过归一化，用原始分
-- ================================================================
CREATE OR REPLACE FUNCTION public.backfill_score_history()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_start_date    DATE;
    v_end_date      DATE;
    v_current_date  DATE;
    v_student       RECORD;
    v_week_count    INTEGER := 0;
    v_total_written INTEGER := 0;
    v_student_count INTEGER;
BEGIN
    PERFORM set_config('app.skip_score_trigger', 'on', TRUE);

    SELECT DATE_TRUNC('week', MIN(session_start))::DATE
    INTO v_start_date
    FROM public.practice_sessions
    WHERE cleaned_duration > 0;

    v_end_date     := DATE_TRUNC('week', CURRENT_DATE)::DATE;
    v_current_date := v_start_date;

    RAISE NOTICE '回溯范围：% → %', v_start_date, v_end_date;

    WHILE v_current_date <= v_end_date LOOP
        v_week_count := v_week_count + 1;
        RAISE NOTICE '[第%周] %', v_week_count, v_current_date;

        -- ① baseline（[FIX-7①] 单学生异常不中断）
        FOR v_student IN
            SELECT DISTINCT student_name FROM public.practice_sessions
            WHERE session_start < v_current_date::TIMESTAMPTZ AND cleaned_duration > 0
            ORDER BY student_name
        LOOP
            BEGIN
                PERFORM public.compute_baseline_as_of(v_student.student_name, v_current_date);
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '[backfill baseline] 学生 % 第 % 周失败：%',
                    v_student.student_name, v_current_date, SQLERRM;
            END;
        END LOOP;

        -- ② 成长分（[FIX-7①] 同上）
        FOR v_student IN
            SELECT DISTINCT student_name FROM public.practice_sessions
            WHERE session_start < v_current_date::TIMESTAMPTZ AND cleaned_duration > 0
            ORDER BY student_name
        LOOP
            BEGIN
                PERFORM public.compute_student_score_as_of(v_student.student_name, v_current_date);
                v_total_written := v_total_written + 1;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '[backfill score] 学生 % 第 % 周失败：%',
                    v_student.student_name, v_current_date, SQLERRM;
            END;
        END LOOP;

        -- ③ [FIX-7②] PERCENT_RANK 归一化：人数 < 5 时跳过，直接用原始分
        SELECT COUNT(DISTINCT student_name) INTO v_student_count
        FROM public.student_score_history
        WHERE snapshot_date = v_current_date AND raw_score IS NOT NULL;

        IF v_student_count >= 5 THEN
            UPDATE public.student_score_history h
            SET composite_score = norm.normalized
            FROM (
                SELECT student_name,
                       ROUND(PERCENT_RANK() OVER (ORDER BY raw_score) * 100)::INT AS normalized
                FROM public.student_score_history
                WHERE snapshot_date = v_current_date AND raw_score IS NOT NULL
            ) norm
            WHERE h.snapshot_date = v_current_date AND h.student_name = norm.student_name;
        ELSE
            -- 人数不足：直接用 raw_score × 100 作为 composite_score
            UPDATE public.student_score_history
            SET composite_score = ROUND(raw_score * 100)::INT
            WHERE snapshot_date = v_current_date AND raw_score IS NOT NULL;
            RAISE NOTICE '[第%周] 学生数=%，跳过归一化，使用原始分', v_week_count, v_student_count;
        END IF;

        v_current_date := v_current_date + INTERVAL '7 days';
    END LOOP;

    -- ④ 恢复 baseline 到最新状态
    FOR v_student IN
        SELECT DISTINCT student_name FROM public.practice_sessions
        WHERE cleaned_duration > 0 ORDER BY student_name
    LOOP
        BEGIN
            PERFORM public.compute_baseline_as_of(
                v_student.student_name, (CURRENT_DATE + INTERVAL '1 day')::DATE
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[backfill final baseline] 学生 % 失败：%',
                v_student.student_name, SQLERRM;
        END;
    END LOOP;

    PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
    RAISE NOTICE '✅ 回溯完成 | % 周 | % 条', v_week_count, v_total_written;
END;
$$;


-- ================================================================
-- FIX-8: run_weekly_score_update — 修复分数倒退问题
-- 原问题：周任务用"本周一"快照覆盖已包含周一到今天数据的实时分，
--         可能导致 student_baseline.composite_score 倒退。
-- 修复：周任务写入历史快照后，额外基于当前 raw_score 更新 baseline
--       的归一化分，确保 baseline 始终反映最新状态。
-- ================================================================
CREATE OR REPLACE FUNCTION public.run_weekly_score_update()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_student RECORD;
    v_monday  DATE;
    v_student_count INTEGER;
BEGIN
    PERFORM set_config('app.skip_score_trigger', 'on', TRUE);

    v_monday := DATE_TRUNC('week', CURRENT_DATE)::DATE;
    RAISE NOTICE '[%] 每周评分更新，快照日期：%', NOW(), v_monday;

    -- ① 更新所有学生 baseline（截止明天 = 包含今天）
    FOR v_student IN SELECT student_name FROM public.student_baseline ORDER BY student_name
    LOOP
        BEGIN
            PERFORM public.compute_baseline_as_of(
                v_student.student_name, (CURRENT_DATE + INTERVAL '1 day')::DATE
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[weekly baseline] 学生 % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    -- ② 计算本周成长分快照（快照日期 = 本周一）
    FOR v_student IN SELECT student_name FROM public.student_baseline ORDER BY student_name
    LOOP
        BEGIN
            PERFORM public.compute_student_score_as_of(v_student.student_name, v_monday);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[weekly score] 学生 % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    -- ③ 归一化本周历史快照（带人数保护）
    SELECT COUNT(DISTINCT student_name) INTO v_student_count
    FROM public.student_score_history
    WHERE snapshot_date = v_monday AND raw_score IS NOT NULL;

    IF v_student_count >= 5 THEN
        UPDATE public.student_score_history h
        SET composite_score = norm.normalized
        FROM (
            SELECT student_name,
                   ROUND(PERCENT_RANK() OVER (ORDER BY raw_score) * 100)::INT AS normalized
            FROM public.student_score_history
            WHERE snapshot_date = v_monday AND raw_score IS NOT NULL
        ) norm
        WHERE h.snapshot_date = v_monday AND h.student_name = norm.student_name;
    END IF;

    -- ④ [FIX-8] 基于当前最新 raw_score 归一化 student_baseline.composite_score
    -- 防止周任务历史快照覆盖实时触发器已写入的更新分数
    SELECT COUNT(*) INTO v_student_count
    FROM public.student_baseline WHERE raw_score IS NOT NULL;

    IF v_student_count >= 5 THEN
        UPDATE public.student_baseline b
        SET composite_score = norm.normalized
        FROM (
            SELECT student_name,
                   ROUND(PERCENT_RANK() OVER (ORDER BY raw_score) * 100)::INT AS normalized
            FROM public.student_baseline
            WHERE raw_score IS NOT NULL
        ) norm
        WHERE b.student_name = norm.student_name;
    END IF;

    -- ⑤ 同步 composite_score 到 baseline（历史快照中本周的归一化值）
    UPDATE public.student_baseline b
    SET composite_score = h.composite_score
    FROM public.student_score_history h
    WHERE h.student_name  = b.student_name
      AND h.snapshot_date = v_monday
      AND h.composite_score IS NOT NULL;

    PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
    RAISE NOTICE '[%] 每周更新完成', NOW();
END;
$$;


-- ================================================================
-- FIX-9: trigger_update_student_baseline — 修复触发器计数基准
-- 原问题：v_record_count 来自 student_baseline（上次计算时的值，可能过时），
--         用于决定触发间隔。动态计数部分改为查实时有效记录数。
-- ================================================================
CREATE OR REPLACE FUNCTION public.trigger_update_student_baseline()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_record_count  INTEGER;
    v_last_updated  TIMESTAMPTZ;
    v_mean          FLOAT;
    v_std           FLOAT;
    v_cv            FLOAT;
    v_interval      INTEGER;
    v_days_since    INTEGER;
    v_force_update  BOOLEAN := FALSE;
    v_live_count    INTEGER;   -- [FIX-9] 实时有效记录数
BEGIN
    -- ① 读取当前基线状态
    SELECT record_count, last_updated, mean_duration, std_duration
    INTO v_record_count, v_last_updated, v_mean, v_std
    FROM public.student_baseline
    WHERE student_name = NEW.student_name;

    -- ② 从未建立过基线 → 立即触发
    IF NOT FOUND THEN
        PERFORM public.update_student_baseline(NEW.student_name);
        RETURN NEW;
    END IF;

    -- ③ 变异系数
    v_cv := CASE
        WHEN COALESCE(v_mean, 0) > 0
            THEN COALESCE(v_std, 0) / v_mean
        ELSE 1.0
    END;

    -- ④ 距上次更新天数
    v_days_since := EXTRACT(
        DAY FROM (NOW() - COALESCE(v_last_updated, '1970-01-01'::TIMESTAMPTZ))
    )::INTEGER;

    -- ⑤ 强制触发：超过14天未更新
    IF v_days_since >= 14 THEN v_force_update := TRUE; END IF;

    -- [FIX-9] 查实时有效记录数（而非 baseline 中可能过时的 record_count）
    SELECT COUNT(*) INTO v_live_count
    FROM public.practice_sessions
    WHERE student_name = NEW.student_name AND cleaned_duration > 0;

    -- ⑥ 动态触发间隔（基于实时计数决定冷启动状态）
    v_interval := CASE
        WHEN v_live_count < 5   THEN 1
        WHEN v_live_count < 10  THEN 2
        WHEN v_cv > 0.5         THEN 3
        WHEN v_cv > 0.3         THEN 5
        ELSE 10
    END;

    -- ⑦ 长期未更新时压缩间隔
    IF v_days_since >= 7 THEN
        v_interval := GREATEST(1, v_interval / 2);
    END IF;

    -- ⑧ [FIX-9] 用实时计数做模运算
    IF v_force_update OR (v_live_count % v_interval = 0) THEN
        PERFORM public.update_student_baseline(NEW.student_name);
    END IF;

    RETURN NEW;
END;
$$;


-- ================================================================
-- FIX-10: 数据完整性约束 + 系统健康监控视图 + debug_as_of 调试函数
-- ================================================================

-- 10-A: 数据完整性约束
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_name = 'student_baseline' AND constraint_name = 'chk_alpha'
    ) THEN
        ALTER TABLE public.student_baseline
            ADD CONSTRAINT chk_alpha          CHECK (alpha BETWEEN 0.5 AND 1.0),
            ADD CONSTRAINT chk_outlier_rate   CHECK (outlier_rate BETWEEN 0.0 AND 1.0),
            ADD CONSTRAINT chk_mean_duration  CHECK (mean_duration >= 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_name = 'student_score_history' AND constraint_name = 'chk_raw_score'
    ) THEN
        ALTER TABLE public.student_score_history
            ADD CONSTRAINT chk_raw_score       CHECK (raw_score BETWEEN 0.0 AND 1.0),
            ADD CONSTRAINT chk_composite_score CHECK (composite_score BETWEEN 0 AND 100);
    END IF;
END;
$$;

-- 10-B: 系统健康监控视图
CREATE OR REPLACE VIEW public.v_baseline_health AS
SELECT
    COUNT(DISTINCT student_name)                                          AS total_students,
    COUNT(CASE WHEN is_cold_start THEN 1 END)                            AS cold_start_count,
    COUNT(CASE WHEN last_updated < NOW() - INTERVAL '14 days' THEN 1 END) AS stale_14d_count,
    COUNT(CASE WHEN last_updated < NOW() - INTERVAL '7 days'  THEN 1 END) AS stale_7d_count,
    ROUND(AVG(alpha)::NUMERIC, 3)                                         AS avg_alpha,
    ROUND(AVG(mean_duration)::NUMERIC, 1)                                 AS avg_mean_duration,
    ROUND(AVG(outlier_rate)::NUMERIC, 3)                                  AS avg_outlier_rate,
    ROUND(AVG(score_confidence)::NUMERIC, 3)                              AS avg_score_confidence,
    MIN(last_updated)                                                     AS oldest_baseline,
    MAX(last_updated)                                                     AS newest_baseline
FROM public.student_baseline;

-- 10-C: debug_weight_conf_as_of — 历史某日的置信度调试
CREATE OR REPLACE FUNCTION public.debug_weight_conf_as_of(
    p_student_name TEXT,
    p_date         DATE
)
RETURNS TABLE(
    hist_count     INTEGER,
    days_stale     FLOAT,
    data_freshness FLOAT,
    outlier_rate   FLOAT,
    factor_depth   FLOAT,
    factor_clean   FLOAT,
    weight_conf    FLOAT
)
LANGUAGE plpgsql AS $$
DECLARE
    r              RECORD;
    v_hist_count   INTEGER;
    v_days_stale   FLOAT;
    v_freshness    FLOAT;
    v_wconf        FLOAT;
BEGIN
    SELECT * INTO r FROM public.student_baseline WHERE student_name = p_student_name;

    SELECT COUNT(*)::INTEGER INTO v_hist_count
    FROM public.student_score_history
    WHERE student_name = p_student_name AND snapshot_date < p_date;

    v_days_stale := EXTRACT(
        DAY FROM (p_date::TIMESTAMPTZ
                  - COALESCE(r.last_updated, p_date::TIMESTAMPTZ - INTERVAL '999 days'))
    )::FLOAT;

    v_freshness := CASE
        WHEN v_days_stale <= 7  THEN 1.0
        WHEN v_days_stale <= 30 THEN 1.0 - 0.5 * ((v_days_stale - 7) / 23.0)
        WHEN v_days_stale <= 90 THEN 0.5 - 0.4 * ((v_days_stale - 30) / 60.0)
        ELSE 0.1
    END;

    v_wconf := GREATEST(0.0, LEAST(1.0,
        LEAST(1.0, LN(GREATEST(v_hist_count,1)::FLOAT+1.0)/LN(13.0))
        * (1.0 - COALESCE(r.outlier_rate, 0.0) * 0.5)
        * v_freshness
    ));

    RETURN QUERY SELECT
        v_hist_count,
        v_days_stale,
        v_freshness,
        COALESCE(r.outlier_rate, 0.0),
        LEAST(1.0, LN(GREATEST(v_hist_count,1)::FLOAT+1.0)/LN(13.0)),
        (1.0 - COALESCE(r.outlier_rate, 0.0) * 0.5),
        v_wconf;
END;
$$;


-- ================================================================
-- 验证查询：执行所有修复后，运行以下查询确认状态
-- ================================================================
SELECT * FROM public.v_baseline_health;

SELECT trigger_name, event_object_table, action_statement
FROM information_schema.triggers
WHERE trigger_schema = 'public'
  AND event_object_table IN ('practice_logs', 'practice_sessions', 'student_baseline')
ORDER BY event_object_table, trigger_name;
