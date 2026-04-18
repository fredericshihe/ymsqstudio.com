-- ============================================================
-- FIX-80: 触发链稳定化修复（基于真实报错栈）
--
-- 已知证据（来自线上报错）：
--   trigger_compute_student_score() -> compute_student_score()
--   -> UPDATE student_baseline
--   -> trigger_compute_student_score() 再次触发
--   循环直到 stack depth limit exceeded
--
-- 结论：
--   不是“权限问题”，而是第3环触发器的递归保护条件不稳：
--   - 需要同时识别 app.skip_score_trigger / app.computing_score 两种事务标记
--   - 需要允许正常链路深度（practice_logs -> sessions -> baseline -> score）
--     但阻断更深层递归（score 内部 UPDATE baseline 再触发 score）
--
-- 目标：
--   1) 保留实时：新增 session 后自动更新分数
--   2) 防递归：不再出现 stack depth exceeded
--   3) 兼容历史代码中 set_config 使用 'on' / 'true' 两种写法
-- ============================================================


-- ------------------------------------------------------------
-- A. 恢复第2环为“纯 baseline 更新”
--    （若你执行过 fix79，这一步会覆盖掉“强制二次重算”版本）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trigger_update_student_baseline()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    PERFORM public.update_student_baseline(NEW.student_name);
    RETURN NEW;
END;
$$;


-- ------------------------------------------------------------
-- B. 稳定化第3环：trigger_compute_student_score
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trigger_compute_student_score()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_skip TEXT := LOWER(COALESCE(current_setting('app.skip_score_trigger', true), ''));
    v_busy TEXT := LOWER(COALESCE(current_setting('app.computing_score', true), ''));
BEGIN
    -- 1) 批量任务保护（backfill / weekly）
    IF v_skip IN ('on', 'true', '1') THEN
        RETURN NEW;
    END IF;

    -- 2) 递归重入保护（compute_student_score 内部回写 baseline 时生效）
    IF v_busy IN ('on', 'true', '1') THEN
        RETURN NEW;
    END IF;

    -- 3) 深度保护：允许正常链路（通常<=2），阻断更深递归
    IF pg_trigger_depth() > 2 THEN
        RETURN NEW;
    END IF;

    PERFORM public.compute_student_score(NEW.student_name);
    PERFORM public.compute_and_store_w_score(NEW.student_name);
    RETURN NEW;
END;
$$;


-- ------------------------------------------------------------
-- C. 部署后验证（替换学生名）
-- ------------------------------------------------------------
-- 1) 看函数定义已包含：
--    - app.skip_score_trigger
--    - app.computing_score
--    - pg_trigger_depth() > 2
-- SELECT pg_get_functiondef('public.trigger_compute_student_score()'::regprocedure);
--
-- 2) 新增一条 clear 后，检查 sec_diff 不再卡几千秒：
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
-- 3) 若仍异常，再检查当前触发链绑定是否正确：
-- SELECT c.relname AS table_name, tg.tgname AS trigger_name, p.proname AS func_name, tg.tgenabled
-- FROM pg_trigger tg
-- JOIN pg_class c ON c.oid = tg.tgrelid
-- JOIN pg_proc p ON p.oid = tg.tgfoid
-- JOIN pg_namespace n ON n.oid = c.relnamespace
-- WHERE n.nspname='public' AND NOT tg.tgisinternal
--   AND c.relname IN ('practice_logs','practice_sessions','student_baseline')
-- ORDER BY c.relname, tg.tgname;

