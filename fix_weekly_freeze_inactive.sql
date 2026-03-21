-- ================================================================
-- FIX-13: run_weekly_score_update — 停练学生分数冻结
-- 
-- 问题根因：
--   每周批量任务对所有学生重跑 PERCENT_RANK 归一化，即使某学生
--   本周没有任何新练琴记录，其百分位排名也会因其他学生分数变化
--   而随之漂移，造成"没练习却涨分/跌分"的虚假结果。
--
-- 修复逻辑：
--   ① 只对"本周内有新练琴记录"的学生重新计算成长分快照
--   ② 无新记录的学生：直接复制上次快照（composite_score 冻结），
--      不参与本周 PERCENT_RANK 重算
--   ③ >30 天未练的学生由 FIX-12 停琴检测处理（指数衰减），本补丁
--      不干预该逻辑
--
-- 注：本周"活跃"定义 = 最近练琴 session_start 在本周一 00:00 之后
-- ================================================================

CREATE OR REPLACE FUNCTION public.run_weekly_score_update()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_student       RECORD;
    v_monday        DATE;
    v_student_count INTEGER;
    v_last_session  DATE;
    v_prev_snap     RECORD;
BEGIN
    PERFORM set_config('app.skip_score_trigger', 'on', TRUE);

    v_monday := DATE_TRUNC('week', CURRENT_DATE)::DATE;
    RAISE NOTICE '[%] 每周评分更新（FIX-13），快照日期：%', NOW(), v_monday;

    -- ① 所有学生更新 baseline（截止明天，包含今天最新数据）
    FOR v_student IN SELECT student_name FROM public.student_baseline ORDER BY student_name
    LOOP
        BEGIN
            PERFORM public.compute_baseline_as_of(
                v_student.student_name,
                (CURRENT_DATE + INTERVAL '1 day')::DATE
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[weekly baseline] 学生 % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    -- ② 计算成长分快照：活跃学生重算，非活跃学生冻结
    FOR v_student IN SELECT student_name FROM public.student_baseline ORDER BY student_name
    LOOP
        BEGIN
            -- 查该学生本周一之后是否有新练琴记录
            SELECT MAX(session_start::DATE)
            INTO v_last_session
            FROM public.practice_sessions
            WHERE student_name = v_student.student_name;

            IF v_last_session >= v_monday THEN
                -- ── 本周活跃：正常重算快照 ──
                PERFORM public.compute_student_score_as_of(v_student.student_name, v_monday);

            ELSE
                -- ── 本周未练：复制上次快照，分数冻结 ──
                -- 若本周快照已存在则跳过（避免重复插入）
                IF NOT EXISTS (
                    SELECT 1 FROM public.student_score_history
                    WHERE student_name = v_student.student_name
                      AND snapshot_date = v_monday
                ) THEN
                    -- 取最近一条历史快照
                    SELECT *
                    INTO v_prev_snap
                    FROM public.student_score_history
                    WHERE student_name = v_student.student_name
                      AND snapshot_date < v_monday
                    ORDER BY snapshot_date DESC
                    LIMIT 1;

                    -- 有历史快照才复制（新生第一周跳过）
                    IF FOUND THEN
                        INSERT INTO public.student_score_history (
                            student_name, snapshot_date,
                            raw_score, composite_score,
                            baseline_score, trend_score, momentum_score, accum_score,
                            outlier_rate, short_session_rate, mean_duration, record_count
                        ) VALUES (
                            v_student.student_name, v_monday,
                            v_prev_snap.raw_score,       -- raw_score 同样冻结
                            v_prev_snap.composite_score, -- 百分位分数冻结
                            v_prev_snap.baseline_score,
                            v_prev_snap.trend_score,
                            v_prev_snap.momentum_score,
                            v_prev_snap.accum_score,
                            v_prev_snap.outlier_rate,
                            v_prev_snap.short_session_rate,
                            v_prev_snap.mean_duration,
                            v_prev_snap.record_count
                        );

                        RAISE NOTICE '[weekly freeze] 学生 % 本周无新记录，冻结分数 %',
                            v_student.student_name, v_prev_snap.composite_score;
                    END IF;
                END IF;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[weekly score] 学生 % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    -- ③ PERCENT_RANK 归一化：只对本周活跃学生重新计算百分位
    --    非活跃学生已复制上周分数，不参与本轮排名，避免分数随他人变化漂移
    SELECT COUNT(DISTINCT sh.student_name) INTO v_student_count
    FROM public.student_score_history sh
    WHERE sh.snapshot_date = v_monday
      AND sh.raw_score IS NOT NULL
      AND EXISTS (
          SELECT 1 FROM public.practice_sessions ps
          WHERE ps.student_name = sh.student_name
            AND ps.session_start::DATE >= v_monday
      );

    IF v_student_count >= 5 THEN
        UPDATE public.student_score_history h
        SET composite_score = norm.normalized
        FROM (
            SELECT sh.student_name,
                   ROUND(PERCENT_RANK() OVER (ORDER BY sh.raw_score) * 100)::INT AS normalized
            FROM public.student_score_history sh
            WHERE sh.snapshot_date = v_monday
              AND sh.raw_score IS NOT NULL
              AND EXISTS (
                  SELECT 1 FROM public.practice_sessions ps
                  WHERE ps.student_name = sh.student_name
                    AND ps.session_start::DATE >= v_monday
              )
        ) norm
        WHERE h.snapshot_date = v_monday
          AND h.student_name  = norm.student_name;

        RAISE NOTICE '[weekly PERCENT_RANK] 参与归一化的活跃学生数：%', v_student_count;
    ELSE
        RAISE NOTICE '[weekly PERCENT_RANK] 活跃学生不足 5 人（%），跳过归一化', v_student_count;
    END IF;

    -- ④ [FIX-8 保留] 基于当前最新 raw_score 更新 student_baseline.composite_score
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

    -- ⑤ 将本周历史快照的 composite_score 同步回 student_baseline
    UPDATE public.student_baseline b
    SET composite_score = h.composite_score
    FROM public.student_score_history h
    WHERE h.student_name  = b.student_name
      AND h.snapshot_date = v_monday
      AND h.composite_score IS NOT NULL;

    PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
    RAISE NOTICE '[%] 每周更新完成（FIX-13）', NOW();
END;
$$;

-- ================================================================
-- 验证查询（部署后可用于检查效果）
-- ================================================================

-- 查看本周哪些学生被冻结、哪些被重算
/*
WITH this_monday AS (SELECT DATE_TRUNC('week', CURRENT_DATE)::DATE AS d)
SELECT
    sh.student_name,
    sh.snapshot_date,
    sh.composite_score,
    CASE
        WHEN MAX(ps.session_start::DATE) >= (SELECT d FROM this_monday)
        THEN '本周活跃（重算）'
        ELSE '本周未练（冻结）'
    END AS status,
    MAX(ps.session_start::DATE) AS last_session
FROM public.student_score_history sh
LEFT JOIN public.practice_sessions ps USING (student_name)
WHERE sh.snapshot_date = (SELECT d FROM this_monday)
GROUP BY sh.student_name, sh.snapshot_date, sh.composite_score
ORDER BY status, sh.student_name;
*/
