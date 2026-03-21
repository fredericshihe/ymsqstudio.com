-- ============================================================
-- FIX-74：删除百分位归一化，composite_score 改为纯绝对分
--
-- 背景：
--   原来 composite_score 有两套计算逻辑：
--     · 实时触发时  → composite_score = raw_score × 100
--     · 每周任务时  → composite_score = PERCENT_RANK(raw_score) × 100
--   两套逻辑并存导致分数含义不一致，学生努力提升后分数反而可能下降，
--   也很难向学生解释"为什么你练得更多但分却低了"。
--
-- 改动：
--   统一为  composite_score = ROUND(raw_score × 100, 1)
--   · run_weekly_score_update()   — 删除步骤③④（PERCENT_RANK 归一化）
--   · backfill_score_history()    — 步骤③ 改为直接换算，删除 IF student_count>=5 分支
--
-- 部署后必做：
--   SELECT public.backfill_score_history();
--   -- 约 1~3 分钟，全量重算历史 composite_score，让所有历史分数统一为绝对分。
-- ============================================================


-- ================================================================
-- 1/2  run_weekly_score_update — FIX-74: 去除 PERCENT_RANK 步骤
-- ================================================================
CREATE OR REPLACE FUNCTION public.run_weekly_score_update()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_student RECORD;
    v_monday  DATE;
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
    --    compute_student_score_as_of 内部已写入 composite_score = ROUND(raw_score×100, 1)
    FOR v_student IN SELECT student_name FROM public.student_baseline ORDER BY student_name
    LOOP
        BEGIN
            PERFORM public.compute_student_score_as_of(v_student.student_name, v_monday);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[weekly score] 学生 % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    -- ③ [FIX-74 删除 PERCENT_RANK] 直接把历史快照中本周的 composite_score 同步到 student_baseline
    --    （步骤②已写入 composite_score = raw_score×100，此步仅做同步，无需再归一化）
    UPDATE public.student_baseline b
    SET composite_score = h.composite_score
    FROM public.student_score_history h
    WHERE h.student_name  = b.student_name
      AND h.snapshot_date = v_monday
      AND h.composite_score IS NOT NULL;

    PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
    RAISE NOTICE '[%] 每周更新完成（FIX-74：纯绝对分，无百分位）', NOW();
END;
$$;


-- ================================================================
-- 2/2  backfill_score_history — FIX-74: 去除 PERCENT_RANK 步骤
-- ================================================================
CREATE OR REPLACE FUNCTION public.backfill_score_history()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_start_date    DATE;
    v_end_date      DATE;
    v_current_date  DATE;
    v_next_date     DATE;
    v_student       RECORD;
    v_week_count    INTEGER := 0;
    v_active_count  INTEGER := 0;
    v_zero_count    INTEGER := 0;
BEGIN
    PERFORM set_config('app.skip_score_trigger', 'on', TRUE);

    SELECT DATE_TRUNC('week', MIN(session_start))::DATE INTO v_start_date
    FROM public.practice_sessions WHERE cleaned_duration > 0;

    v_end_date     := DATE_TRUNC('week', CURRENT_DATE)::DATE;
    v_current_date := v_start_date;
    RAISE NOTICE '回溯范围：% → %（FIX-15）', v_start_date, v_end_date;

    WHILE v_current_date <= v_end_date LOOP
        v_week_count := v_week_count + 1;
        v_next_date  := v_current_date + INTERVAL '7 days';

        -- ① baseline
        FOR v_student IN
            SELECT DISTINCT student_name FROM public.practice_sessions
            WHERE session_start < v_current_date::TIMESTAMPTZ AND cleaned_duration > 0
            ORDER BY student_name
        LOOP
            BEGIN
                PERFORM public.compute_baseline_as_of(v_student.student_name, v_current_date);
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '[backfill baseline] % @ % 失败：%', v_student.student_name, v_current_date, SQLERRM;
            END;
        END LOOP;

        -- ② 成长分：本周活跃 → 重算；本周无练 → 写 0
        FOR v_student IN
            SELECT DISTINCT student_name FROM public.practice_sessions
            WHERE session_start < v_current_date::TIMESTAMPTZ AND cleaned_duration > 0
            ORDER BY student_name
        LOOP
            BEGIN
                IF EXISTS (
                    SELECT 1 FROM public.practice_sessions
                    WHERE student_name    = v_student.student_name
                      AND cleaned_duration > 0
                      AND session_start  >= v_current_date::TIMESTAMPTZ
                      AND session_start  <  v_next_date::TIMESTAMPTZ
                ) THEN
                    PERFORM public.compute_student_score_as_of(v_student.student_name, v_current_date);
                    v_active_count := v_active_count + 1;
                ELSE
                    INSERT INTO public.student_score_history
                        (student_name, snapshot_date, raw_score, composite_score,
                         baseline_score, trend_score, momentum_score, accum_score,
                         outlier_rate, short_session_rate, mean_duration, record_count)
                    VALUES
                        (v_student.student_name, v_current_date, 0, 0,
                         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
                    ON CONFLICT (student_name, snapshot_date) DO NOTHING;
                    v_zero_count := v_zero_count + 1;
                END IF;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '[backfill score] % @ % 失败：%', v_student.student_name, v_current_date, SQLERRM;
            END;
        END LOOP;

        -- ③ [FIX-74] composite_score = ROUND(raw_score × 100, 1)，不再用 PERCENT_RANK
        --    compute_student_score_as_of 已写入此值；此步仅对"本周活跃但 raw_score 未正确写入"的行做兜底修复
        UPDATE public.student_score_history
        SET composite_score = ROUND((raw_score * 100)::NUMERIC, 1)
        WHERE snapshot_date   = v_current_date
          AND raw_score        IS NOT NULL
          AND raw_score         > 0
          AND (composite_score IS NULL OR composite_score <> ROUND((raw_score * 100)::NUMERIC, 1));

        v_current_date := v_next_date;
    END LOOP;

    -- ④ [FIX-15] 同步最新有效分数到 student_baseline
    UPDATE public.student_baseline b
    SET composite_score = latest.composite_score
    FROM (
        SELECT DISTINCT ON (student_name) student_name, composite_score
        FROM public.student_score_history
        WHERE composite_score > 0
        ORDER BY student_name, snapshot_date DESC
    ) latest
    WHERE b.student_name = latest.student_name;

    -- ⑤ FIX-62: 回溯完成后，用今天重新刷新所有学生基线
    FOR v_student IN SELECT student_name FROM public.student_baseline ORDER BY student_name LOOP
        BEGIN
            PERFORM public.compute_baseline(v_student.student_name);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[backfill rebase] % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    -- ⑥ FIX-53-F: 刷新所有学生的实时 W 分
    FOR v_student IN SELECT DISTINCT student_name FROM public.student_baseline LOOP
        BEGIN
            PERFORM public.compute_and_store_w_score(v_student.student_name);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[backfill w_score] % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
    RAISE NOTICE '回溯完成（FIX-74：纯绝对分）：共 % 周，重算 % 条，零分 % 条',
        v_week_count, v_active_count, v_zero_count;
END;
$$;
