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
-- FIX-8: run_weekly_score_update — 修复分数倒退问题
-- ④ 新增：基于当前最新 raw_score 重新归一化 student_baseline.composite_score
--    防止周任务历史快照覆盖实时触发器已写入的更新分数
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
-- FIX-71: 改为每次新增 practice_session 都立即触发基线 + 分数更新
-- 原因：动态间隔（最多每10次才触发）导致排行榜分数不够实时。
-- 每次还卡后约数秒内即可在排行榜看到最新分数（前端 60s 轮询）。
-- 代价：compute_student_score 每次练琴后都重算，计算量略增，但可接受。
CREATE OR REPLACE FUNCTION public.trigger_update_student_baseline()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM public.update_student_baseline(NEW.student_name);
    RETURN NEW;
END;
$$;
