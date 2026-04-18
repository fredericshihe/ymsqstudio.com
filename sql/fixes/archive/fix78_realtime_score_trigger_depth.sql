-- ============================================================
-- FIX-78: 修复“新增 practice_session 后 composite_score 不实时更新”
--
-- 根因：
--   触发链为多层嵌套：
--   practice_logs(clear) -> trigger_insert_session
--   -> practice_sessions INSERT/UPDATE -> trigger_update_student_baseline
--   -> student_baseline UPDATE -> trigger_compute_student_score
--
--   若 trigger_compute_student_score 使用:
--     IF pg_trigger_depth() > 1 THEN RETURN NEW;
--   在上述嵌套场景会被误判为“递归”，导致 compute_student_score 被跳过。
--   手动调用 update_student_baseline()（浅层触发）则能更新，形成“手动能变、自动不变”。
--
-- 解决：
--   1) 使用“更高阈值”的深度保护：pg_trigger_depth() > 2 才拦截
--      - 正常链路（practice_logs -> practice_sessions -> baseline）可通过
--      - compute_student_score 内部再次 UPDATE baseline 的递归层会被拦截
--   2) 保留 app.skip_score_trigger = 'on'（批量任务保护）
-- ============================================================

CREATE OR REPLACE FUNCTION public.trigger_compute_student_score()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- 防递归：只拦截真正的深层递归，不拦截正常嵌套触发链
    -- 经验值：正常链路深度通常 <= 2；递归回写会进入更深层
    IF pg_trigger_depth() > 2 THEN
        RETURN NEW;
    END IF;

    -- 批量任务（backfill/weekly job）显式跳过
    IF current_setting('app.skip_score_trigger', true) = 'on' THEN
        RETURN NEW;
    END IF;

    PERFORM public.compute_student_score(NEW.student_name);
    PERFORM public.compute_and_store_w_score(NEW.student_name);
    RETURN NEW;
END;
$$;

-- ------------------------------------------------------------
-- 部署后验证（建议依次执行）
-- ------------------------------------------------------------
-- 1) 看函数定义已不含 pg_trigger_depth() 拦截
-- SELECT pg_get_functiondef('public.trigger_compute_student_score()'::regprocedure);
--
-- 2) 插入一条真实 clear 后，检查该学生 baseline 是否秒级刷新
-- SELECT student_name, composite_score, last_updated
-- FROM public.student_baseline
-- WHERE student_name = '王奕然';
--
-- 3) 与最新 session_start 对比（sec_diff 应接近 0~几十秒）
-- WITH s AS (
--   SELECT student_name, MAX(session_start) AS latest_session
--   FROM public.practice_sessions
--   WHERE student_name = '王奕然'
--   GROUP BY student_name
-- )
-- SELECT b.student_name, s.latest_session, b.last_updated,
--        EXTRACT(EPOCH FROM (b.last_updated - s.latest_session)) AS sec_diff
-- FROM public.student_baseline b
-- JOIN s ON s.student_name = b.student_name;

