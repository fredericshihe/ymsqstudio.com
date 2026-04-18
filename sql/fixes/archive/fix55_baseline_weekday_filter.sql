-- ============================================================
-- FIX-55：compute_baseline_as_of 全面过滤周末数据（明确备档）
--
-- 背景：
--   fix47_alpha_outlier_penalty.sql（FIX-47）已包含全部 6 处 DOW 过滤
--   及 FIX-47 分段 alpha 公式。本文件作为独立备档，确保任何时候单独
--   重新部署 compute_baseline_as_of 都能得到完全正确的版本。
--
-- 修复点（相对 baseline_fixes_v1.sql 原始版本）：
--   ① meta 查询：加工作日过滤（防止周末练琴伪造专业/年级信息）
--   ② recent_valid CTE：仅统计工作日 → mean_duration / std / record_count 准确
--   ③ 异常率 & 短时率：仅统计工作日
--   ④ recent_dow 星期分布 CTE：仅工作日
--   ⑤ 冷启动同专业同年级参照：仅工作日
--   ⑥ 冷启动同专业降级参照：仅工作日
--   ⑦ alpha 异常率惩罚（FIX-47 分段加速）：
--        rate ≤ 30%: 0.08 × rate
--        rate  > 30%: 0.024 + 0.40 × (rate - 0.30)
--
-- 部署后需重算：
--   SELECT public.backfill_score_history();
-- ============================================================

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

    -- [FIX-19] 周末过滤宏：EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0,6)
    --   DOW: 0=周日, 1=周一 ... 5=周五, 6=周六
    --   所有统计仅使用工作日（周一~周五）的练琴数据

    -- ① meta 信息（截止日期前最近一条工作日练琴）
    SELECT student_major, student_grade
    INTO v_student_major, v_student_grade
    FROM public.practice_sessions
    WHERE student_name  = p_student_name
      AND session_start < v_asof_bjt
      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    ORDER BY session_start DESC
    LIMIT 1;

    IF NOT FOUND THEN RETURN; END IF;

    -- ② 有效记录：截止日期前最近30条工作日记录
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

    -- [FIX-2①] std 保护：< 2 条时保留 NULL；过小时设最小值 1.0
    v_std := CASE
        WHEN v_count < 2               THEN NULL
        WHEN COALESCE(v_std, 0) < 1.0  THEN 1.0
        ELSE v_std
    END;

    -- [FIX-2①] CV（变异系数）= std / mean
    v_cv := CASE
        WHEN COALESCE(v_mean, 0) > 0 AND v_std IS NOT NULL
            THEN v_std / v_mean
        ELSE 0.5
    END;

    -- ③ 异常率 & 短时率（仅工作日记录）
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

    -- ④ 星期分布（仅工作日记录）
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

    -- ⑤ [FIX-2② + FIX-47] alpha 计算
    --   FIX-47：异常率惩罚分段加速，解决高异常率因 cleaned_duration 截断 CV≈0 导致 alpha 虚高
    v_alpha := 1.0
        -- 低均值风险惩罚
        - CASE
            WHEN COALESCE(v_mean, 0) > 0 THEN LEAST(0.15, 5.0 / v_mean)
            ELSE 0.15
          END
        -- 波动惩罚（CV）
        - LEAST(0.20, v_cv * 0.15)
        -- [FIX-47] 异常率惩罚（分段加速）
        - CASE
            WHEN COALESCE(v_outlier_rate, 0) <= 0.30
                THEN 0.08 * COALESCE(v_outlier_rate, 0)
            ELSE
                0.024 + 0.40 * (COALESCE(v_outlier_rate, 0) - 0.30)
          END
        -- 短时率惩罚
        - 0.05 * COALESCE(v_short_rate, 0);

    -- ⑥ 冷启动混合（群体参照也只用工作日数据）
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
            SELECT
                1.0
                - LEAST(0.15, 5.0 / NULLIF(grp.mean_dur, 0))
                - LEAST(0.20, CASE WHEN NULLIF(grp.mean_dur, 0) IS NOT NULL
                                   THEN (10.0 / grp.mean_dur) * 0.15
                                   ELSE 0.5 * 0.15 END)
                AS mean_alpha
        ) calc;

        -- 降级：按专业匹配（不含年级）
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

    -- ⑦ 硬截断 [0.5, 1.0]
    v_alpha := GREATEST(0.5, LEAST(1.0, v_alpha));

    -- [FIX-2③] last_updated：未来日期写 NOW()，历史日期写原日期
    v_last_updated := CASE
        WHEN p_as_of_date > (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE THEN NOW()
        ELSE v_asof_bjt
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
