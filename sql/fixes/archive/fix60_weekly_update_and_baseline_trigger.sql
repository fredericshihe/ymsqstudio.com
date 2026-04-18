-- ============================================================
-- FIX-60：单独部署 run_weekly_score_update + trigger_update_student_baseline
--
-- 背景：baseline_fixes_v1.sql 是全量文件，包含旧版 compute_student_score
--   等函数（签名与数据库现有版本不一致），不能直接整文件执行。
--   本文件仅提取这两个需更新的函数，安全可独立执行。
--
-- 函数来源：baseline_fixes_v1.sql 第 1129、1217 行
--   run_weekly_score_update    — FIX-8：防分数倒退
--   trigger_update_student_baseline — FIX-9：实时记录数计数
-- ============================================================


-- ================================================================
-- FIX-8:  run_weekly_score_update — 修复分数倒退问题
-- FIX-74: 删除 PERCENT_RANK 归一化，composite_score 改为纯绝对分
-- FIX-75: 快照存终点分，删除覆盖 student_baseline 的步骤③
-- ================================================================
CREATE OR REPLACE FUNCTION public.run_weekly_score_update()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_student RECORD;
    v_monday  DATE;
    v_week_start_bjt TIMESTAMPTZ;
BEGIN
    PERFORM set_config('app.skip_score_trigger', 'on', TRUE);

    v_monday := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
    v_week_start_bjt := (v_monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';
    RAISE NOTICE '[%] 每周评分更新，快照日期：%', NOW(), v_monday;

    -- ① 重算所有学生基线（含本周一次未练的学生）
    FOR v_student IN SELECT student_name FROM public.student_baseline ORDER BY student_name
    LOOP
        BEGIN
            PERFORM public.compute_baseline_as_of(
                v_student.student_name, ((NOW() AT TIME ZONE 'Asia/Shanghai')::DATE + 1)
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[weekly baseline] 学生 % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    -- ② 为本周未练琴的学生补写快照
    --    已练琴的学生由实时触发器维护 student_score_history[本周一]（终点分），无需重复计算
    --    未练琴的学生触发器未触发，手动补写（体现基线衰减 / 停练惩罚）
    FOR v_student IN
        SELECT student_name FROM public.student_baseline
        WHERE student_name NOT IN (
            SELECT DISTINCT student_name
            FROM public.practice_sessions
            WHERE session_start >= v_week_start_bjt
              AND cleaned_duration > 0
              AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
        )
        ORDER BY student_name
    LOOP
        BEGIN
            PERFORM public.compute_student_score(v_student.student_name);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[weekly snapshot] 学生 % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    -- ③ [FIX-75 删除] 不再把快照分同步回 student_baseline
    --    student_baseline.composite_score 由实时触发器全权维护

    PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
    RAISE NOTICE '[%] 每周更新完成（FIX-75：快照=终点分，不覆盖实时分）', NOW();
END;
$$;


-- ================================================================
-- FIX-9: trigger_update_student_baseline — 修复触发器计数基准
-- 原问题：v_record_count 来自 student_baseline（上次计算时的值，可能过时），
--         用于决定触发间隔。动态计数部分改为查实时有效记录数。
-- ================================================================
-- FIX-71: 改为每次新增 practice_session 都立即触发基线 + 分数更新
-- 原因：动态间隔（最多每10次才触发）导致排行榜分数不够实时。
-- 每次还卡后约数秒内即可在排行榜看到最新分数（前端 60s 轮询）。
-- 代价：compute_student_score 每次练琴后都重算，计算量略增，但可接受。
CREATE OR REPLACE FUNCTION public.trigger_update_student_baseline()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER   -- FIX-22: anon 角色触发时以函数 owner 权限执行，绕过 RLS 对 student_baseline 的写限制
AS $$
BEGIN
    PERFORM public.update_student_baseline(NEW.student_name);
    RETURN NEW;
END;
$$;
