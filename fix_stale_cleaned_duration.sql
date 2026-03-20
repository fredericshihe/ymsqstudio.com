-- ============================================================
-- FIX-51：修复 FIX-41 遗留的 cleaned_duration 污染记录
-- 问题：FIX-41 把 raw_duration 从时间戳重算，但 cleaned_duration
--       没有同步更新，导致 raw=2min 但 cleaned=45min 的矛盾记录
-- 影响：这些记录被计入基线均值、不被标记为 too_short，评分偏高
-- ============================================================

-- ── 步骤 0：预览受影响记录数 ──────────────────────────────────────────
-- 情况A：raw_duration < 5（不应存在于 practice_sessions）
SELECT
    COUNT(*) AS too_short_records,
    COUNT(DISTINCT student_name) AS affected_students,
    AVG(cleaned_duration)::NUMERIC(6,1) AS avg_stale_cleaned
FROM public.practice_sessions
WHERE raw_duration < 5;

-- 情况B：cleaned_duration > raw_duration（逻辑矛盾，不可能正常生成）
SELECT
    COUNT(*) AS inverted_records,
    COUNT(DISTINCT student_name) AS affected_students,
    SUM(cleaned_duration - raw_duration)::INTEGER AS total_inflated_minutes
FROM public.practice_sessions
WHERE cleaned_duration > raw_duration;

-- ══════════════════════════════════════════════════════════════
-- ⚠️  重要：批量修正前先关闭评分触发器
-- 不关闭会导致每行 UPDATE 都触发全链路重算，产生大量中间状态快照
-- ══════════════════════════════════════════════════════════════
SELECT set_config('app.skip_score_trigger', 'on', false);

-- ── 步骤 1：删除 raw_duration < 5 的记录（too_short，不应存在）──────
-- 这些是 FIX-41 修正 raw_duration 后留下的僵尸记录，2分钟的记录根本不应写入
DELETE FROM public.practice_sessions
WHERE raw_duration < 5;

-- ── 步骤 2：修复 cleaned_duration > raw_duration 的矛盾记录 ──────────
-- 按当前触发器规则重新计算 cleaned_duration 和 outlier 状态
UPDATE public.practice_sessions
SET
    cleaned_duration = CASE
        WHEN raw_duration > 180 THEN 120          -- too_long：截断 120
        WHEN raw_duration > 120 THEN 120          -- capped_120：截断 120
        ELSE raw_duration                          -- 正常：与 raw 相同
    END,
    is_outlier = CASE
        WHEN raw_duration > 180 THEN TRUE          -- too_long
        ELSE is_outlier                            -- 保持原有异常标记（meal_break 等）
    END,
    outlier_reason = CASE
        WHEN raw_duration > 180 THEN 'too_long'
        WHEN raw_duration > 120 THEN 'capped_120'
        ELSE outlier_reason                        -- 保持（如 meal_break）
    END
WHERE cleaned_duration > raw_duration;

-- ── 步骤 2 完成后恢复触发器 ──────────────────────────────────────────
SELECT set_config('app.skip_score_trigger', 'off', false);

-- ── 步骤 3：重新计算受影响学生的基线 ─────────────────────────────────
-- 找出受影响的学生名单，触发基线重算
-- （在执行完 1、2 步后，对受影响学生调用 compute_baseline）
-- 这一步在 Supabase Dashboard 执行或通过 cron 触发

-- 预览：找出受影响的学生
SELECT DISTINCT student_name
FROM public.practice_sessions
WHERE raw_duration < 5
   OR cleaned_duration > raw_duration
ORDER BY student_name;

-- ── 步骤 4（可选）：重新计算所有学生历史快照 ─────────────────────────
-- 如果受影响学生较多，可运行全量历史重建
-- SELECT public.backfill_score_history();


-- ============================================================
-- FIX-51B：加固触发器——< 5分钟时主动清除已有的错误记录
-- 旧行为：RETURN NEW 早退，不写也不清理，留下历史脏数据
-- 新行为：先 DELETE 该 (student, session_start) 的记录（如有），再 RETURN NEW
-- ============================================================
CREATE OR REPLACE FUNCTION public.trigger_insert_session()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_assign           RECORD;
    v_duration_seconds INTEGER;
    v_assign_time      TIMESTAMPTZ;
    v_clear_time       TIMESTAMPTZ;
    v_cleaned_duration INTEGER;
    v_is_outlier       BOOLEAN;
    v_outlier_reason   TEXT;
    v_start_time       TIME;
    v_end_time         TIME;
    v_dow              INTEGER;
    v_spans_meal_break BOOLEAN;
BEGIN
    IF NEW.action != 'clear' THEN
        RETURN NEW;
    END IF;

    v_clear_time := NEW.created_at;

    -- 第一步：找最近的 assign（16小时内，同学生+同琴房）
    SELECT pl.*
    INTO v_assign
    FROM public.practice_logs pl
    WHERE pl.student_name = NEW.student_name
      AND pl.room_name    = NEW.room_name
      AND pl.action       = 'assign'
      AND pl.created_at   < v_clear_time
      AND pl.created_at   > v_clear_time - INTERVAL '16 hours'
    ORDER BY pl.created_at DESC
    LIMIT 1;

    IF v_assign IS NULL THEN
        RETURN NEW;
    END IF;

    v_assign_time := v_assign.created_at;

    -- 第二步：检查中间断点（防止重复消费同一个 assign）
    IF EXISTS (
        SELECT 1
        FROM public.practice_logs mid
        WHERE mid.student_name = NEW.student_name
          AND mid.room_name    = NEW.room_name
          AND mid.action       = 'clear'
          AND mid.created_at   > v_assign_time
          AND mid.created_at   < v_clear_time
          AND mid.id           != NEW.id
    ) THEN
        RETURN NEW;
    END IF;

    -- FIX-41：始终从时间戳计算，废弃 practice_duration 字段
    v_duration_seconds := EXTRACT(EPOCH FROM (v_clear_time - v_assign_time))::INTEGER;

    -- FIX-51B：不足 5 分钟时，主动删除已有的错误记录（旧数据污染修复）
    -- 旧行为是静默返回，遗留历史脏数据；新行为主动清理再返回
    IF v_duration_seconds < 300 THEN
        DELETE FROM public.practice_sessions
        WHERE student_name = NEW.student_name
          AND session_start = v_assign_time;
        RETURN NEW;
    END IF;

    -- 时长分级处理（FIX-24 规则）
    IF v_duration_seconds > 10800 THEN        -- > 180 分钟
        v_cleaned_duration := 120;
        v_is_outlier       := TRUE;
        v_outlier_reason   := 'too_long';
    ELSIF v_duration_seconds > 7200 THEN      -- 120~180 分钟
        v_cleaned_duration := 120;
        v_is_outlier       := FALSE;
        v_outlier_reason   := 'capped_120';
    ELSE
        v_cleaned_duration := ROUND(v_duration_seconds / 60.0)::INTEGER;
        v_is_outlier       := FALSE;
        v_outlier_reason   := NULL;
    END IF;

    -- FIX-50：饭点峰值时刻检测
    -- FIX-72：修正时区转换 Bug
    --   旧写法：AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Shanghai' 对 TIMESTAMPTZ 输入产生双重偏移，
    --           导致 v_start_bjt::TIME 在 UTC 服务器上取到 UTC 小时而非北京时间，
    --           实际效果是 BJT 时间 +8h，使 BJT 08:05–10:11 被误判为 16:05–18:11（跨晚饭峰值）
    --   新写法：TIMESTAMPTZ AT TIME ZONE 'Asia/Shanghai' 直接返回北京时间的 TIMESTAMP，
    --           ::TIME 取出的就是正确的北京时间，不依赖服务器时区设置
    v_start_time := (v_assign_time AT TIME ZONE 'Asia/Shanghai')::TIME;
    v_end_time   := (v_clear_time  AT TIME ZONE 'Asia/Shanghai')::TIME;
    v_dow        := EXTRACT(DOW FROM (v_assign_time AT TIME ZONE 'Asia/Shanghai'))::INTEGER;

    v_spans_meal_break := (
        -- 午饭峰值时刻 12:10（周一至周五，DOW 1-5）
        (v_dow BETWEEN 1 AND 5
            AND v_start_time < '12:10:00'::TIME
            AND v_end_time   > '12:10:00'::TIME)
        OR
        -- 晚饭峰值时刻 18:10（周一/二/四/五，周三不判定，DOW 1,2,4,5）
        (v_dow IN (1, 2, 4, 5)
            AND v_start_time < '18:10:00'::TIME
            AND v_end_time   > '18:10:00'::TIME)
    );

    -- 饭点升级逻辑（too_long 最高优先级，不被降级）
    IF v_spans_meal_break AND v_outlier_reason != 'too_long' THEN
        v_is_outlier     := TRUE;
        v_outlier_reason := 'meal_break';
        -- capped_120 升级为 meal_break 时 cleaned_duration 不变（仍为120）
    END IF;

    INSERT INTO public.practice_sessions (
        student_name, student_major, student_grade,
        room_name, piano_type,
        session_start, session_end,
        raw_duration, cleaned_duration,
        is_outlier, outlier_reason, created_at
    ) VALUES (
        NEW.student_name, NEW.student_major, NEW.student_grade,
        NEW.room_name, NEW.piano_type,
        v_assign_time, v_clear_time,
        ROUND(v_duration_seconds / 60.0)::INTEGER,
        v_cleaned_duration,
        v_is_outlier,
        v_outlier_reason,
        NOW()
    )
    ON CONFLICT (student_name, session_start) DO UPDATE SET
        session_end      = EXCLUDED.session_end,
        raw_duration     = EXCLUDED.raw_duration,
        cleaned_duration = EXCLUDED.cleaned_duration,
        is_outlier       = EXCLUDED.is_outlier,
        outlier_reason   = EXCLUDED.outlier_reason;

    RETURN NEW;
END;
$$;
