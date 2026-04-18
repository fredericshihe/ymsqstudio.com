-- ============================================================
-- FIX-53-H：更新 clean_duration 函数（停练归来降级检测）
--
-- ⚠️  使用说明：
--   只运行本文件，不要运行 baseline_fixes_v1.sql 全文！
--   baseline_fixes_v1.sql 包含多个旧版函数（compute_student_score
--   第345行、compute_student_score_as_of 第729行等），运行全文会
--   覆盖 fix44_46_score_functions.sql 的所有最新修复。
--
-- 本文件只包含 clean_duration 函数的最新版本，安全可独立执行。
--
-- 主要改动（FIX-53-H，相比数据库现有版本）：
--   1. 新增 record_count 冷启动保护（record_count >= 10 才用个人检测）
--   2. 新增停练归来检测：最近30天内无练琴 → 降级为全局上限检测
--      避免旧 baseline 均值误判恢复练习的正常时长
--   3. 新增 outlier_reason = 'global_cap_returning' 标记，
--      与冷启动 'global_cap_cold_start' 区分
-- ============================================================

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

    -- FIX-53-H: 停练归来检测——查最近一次有效练琴时间间隔
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
    -- ③ 近期有持续练琴（30天内）—— FIX-53-H 新增
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
