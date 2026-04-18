-- ============================================================
-- FIX-79: 强制保障“每次新增 practice_session 后实时重算分数”
--
-- 现象：
--   practice_sessions 已新增，但 student_baseline.last_updated / composite_score
--   未立即刷新，需手动触发才变化。
--
-- 根因（实战高频）：
--   现有链路依赖：
--     trigger_update_student_baseline -> update_student_baseline
--     -> (若 baseline 行发生 UPDATE) -> trigger_compute_student_score
--   若 baseline 计算本次判定“无需写回”（或值未变化），则不会触发 student_baseline UPDATE，
--   后续分数重算就被跳过，表现为“新增记录后分数不动”。
--
-- 修复策略：
--   在 trigger_update_student_baseline() 内显式补执行：
--     compute_student_score(NEW.student_name)
--     compute_and_store_w_score(NEW.student_name)
--   这样每次 practice_sessions 的 INSERT/UPDATE 都能保证分数链路落地，
--   不再依赖 baseline 是否实际更新行值。
-- ============================================================

CREATE OR REPLACE FUNCTION public.trigger_update_student_baseline()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- 1) 先按现有逻辑更新基线（保持原口径）
    PERFORM public.update_student_baseline(NEW.student_name);

    -- 2) 强制补一遍分数与W刷新，避免“基线无写回时后续链路不触发”
    PERFORM public.compute_student_score(NEW.student_name);
    PERFORM public.compute_and_store_w_score(NEW.student_name);

    RETURN NEW;
END;
$$;

-- ------------------------------------------------------------
-- 部署后验证（替换学生姓名）
-- ------------------------------------------------------------
-- WITH s AS (
--   SELECT student_name, MAX(session_start) AS latest_session
--   FROM public.practice_sessions
--   WHERE student_name = '陈思烨'
--   GROUP BY student_name
-- )
-- SELECT
--   b.student_name,
--   s.latest_session,
--   b.last_updated,
--   EXTRACT(EPOCH FROM (b.last_updated - s.latest_session)) AS sec_diff,
--   b.raw_score,
--   b.composite_score
-- FROM public.student_baseline b
-- JOIN s ON s.student_name = b.student_name;
--
-- 预期：
--   新增clear后，sec_diff 不再长期维持几千秒，last_updated 会自动追平。

