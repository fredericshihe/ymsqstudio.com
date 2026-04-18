-- ============================================================
-- FIX-75：修复 run_weekly_score_update 快照逻辑
--
-- 问题（FIX-74 遗留设计缺陷）：
--   步骤② 调用 compute_student_score_as_of(student, 本周一)
--          → 算出"本周一起点分"（不含本周练习）
--          → 覆盖 student_score_history[本周一]（实时触发器写的终点分）
--   步骤③ 把"起点分"同步回 student_baseline
--          → 排行榜显示分数骤降
--
--   后果：进步榜基准 = 上周起点分（偏低），
--         本周只需超过上周周一的分就能上进步榜，
--         即使本周实际表现不如上周也可能上榜。
--
-- 修复：
--   步骤② 只给"本周未练琴的学生"补写快照（调用实时版 compute_student_score）
--          已练琴学生由实时触发器全程维护 student_score_history[本周一]，
--          存的是"周五终点分"（含全周练习），无需重复计算。
--   删除步骤③，student_baseline 完全交由触发器维护，不再在周任务中覆盖。
--
-- 效果：
--   student_score_history[本周一] = 周五终点分（真实努力成果）
--   下周进步榜基准 = 上周周五终点分  → 进步榜更准确公平
--   student_baseline 不被周任务覆盖  → 排行榜分数不再骤降
-- ============================================================

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
    --    实时触发器只在有练琴时触发，长期未练学生的基线可能停留在旧值
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
    --    已练琴的学生：实时触发器每次打卡后同步写入 student_score_history[本周一]
    --                  存的是累积到当时的终点分，不需要再算
    --    未练琴的学生：触发器本周未触发，手动补写（体现基线衰减 / 停练惩罚）
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
    --    原步骤③ 把"起点分"写回 student_baseline，导致排行榜分数骤降
    --    student_baseline.composite_score 由实时触发器全权维护

    PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
    RAISE NOTICE '[%] 每周更新完成（FIX-75：快照=终点分，不覆盖实时分）', NOW();
END;
$$;
