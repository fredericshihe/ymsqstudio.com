-- ============================================================
-- FIX-72：修正饭点检测时区 Bug 导致的误判 meal_break 历史数据
--
-- 问题根源：trigger_insert_session 旧版时区转换有误
--   旧：v_assign_time AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Shanghai'
--       → 对 TIMESTAMPTZ 输入产生双重偏移，UTC 服务器上 ::TIME 取到 UTC 小时
--       → 实际效果：BJT 时间 +8h（08:05 BJT 变成 16:05，10:11 BJT 变成 18:11）
--   新：(v_assign_time AT TIME ZONE 'Asia/Shanghai')::TIME → 直接得到北京时间
--
-- 影响范围（误判为 dinner meal_break 的 session 模式）：
--   BJT 开始时间 < 10:10 AND 10:11 ≤ BJT 结束时间 ≤ 15:59
--   即：早上/上午开始、中午或下午结束的正常练琴会话
--
-- 本脚本：
--   ① 预览受影响记录
--   ② 将误判的 meal_break 修正为正确状态（capped_120 或 NULL）
--   ③ 重算受影响学生的分数
-- ============================================================

-- ① 预览：所有被误判为 meal_break 的 session
--    条件：outlier_reason = 'meal_break'
--          但北京时间实际上并未跨过 12:10（午）或 18:10（晚）
SELECT
    student_name,
    session_start AT TIME ZONE 'Asia/Shanghai' AS start_bjt,
    session_end   AT TIME ZONE 'Asia/Shanghai' AS end_bjt,
    (session_start AT TIME ZONE 'Asia/Shanghai')::TIME AS start_time_bjt,
    (session_end   AT TIME ZONE 'Asia/Shanghai')::TIME AS end_time_bjt,
    raw_duration,
    cleaned_duration,
    outlier_reason
FROM public.practice_sessions
WHERE outlier_reason = 'meal_break'
  AND NOT (
    -- 真正跨午饭（北京时间）
    (EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') BETWEEN 1 AND 5
     AND (session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '12:10:00'
     AND (session_end   AT TIME ZONE 'Asia/Shanghai')::TIME > '12:10:00')
    OR
    -- 真正跨晚饭（北京时间，周一/二/四/五）
    (EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') IN (1, 2, 4, 5)
     AND (session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '18:10:00'
     AND (session_end   AT TIME ZONE 'Asia/Shanghai')::TIME > '18:10:00')
  )
ORDER BY session_start DESC;


-- ② 修复：将误判的 meal_break 改回正确状态
--    - raw_duration > 120 → capped_120（is_outlier=FALSE，已被截断但非异常）
--    - raw_duration ≤ 120 → outlier_reason=NULL，is_outlier=FALSE（完全正常）
UPDATE public.practice_sessions
SET
    is_outlier     = FALSE,
    outlier_reason = CASE
                       WHEN raw_duration > 120 THEN 'capped_120'
                       ELSE NULL
                     END
WHERE outlier_reason = 'meal_break'
  AND NOT (
    (EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') BETWEEN 1 AND 5
     AND (session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '12:10:00'
     AND (session_end   AT TIME ZONE 'Asia/Shanghai')::TIME > '12:10:00')
    OR
    (EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') IN (1, 2, 4, 5)
     AND (session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '18:10:00'
     AND (session_end   AT TIME ZONE 'Asia/Shanghai')::TIME > '18:10:00')
  );

-- ③ 查看受影响学生（在步骤②之前运行，用于后续重算）
SELECT DISTINCT student_name
FROM public.practice_sessions
WHERE outlier_reason = 'meal_break'
  AND NOT (
    (EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') BETWEEN 1 AND 5
     AND (session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '12:10:00'
     AND (session_end   AT TIME ZONE 'Asia/Shanghai')::TIME > '12:10:00')
    OR
    (EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') IN (1, 2, 4, 5)
     AND (session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '18:10:00'
     AND (session_end   AT TIME ZONE 'Asia/Shanghai')::TIME > '18:10:00')
  )
ORDER BY student_name;

-- ④ 全量重算（步骤②执行完后运行）
-- SELECT public.backfill_score_history();
