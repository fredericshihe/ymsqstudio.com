-- ============================================================
-- FIX-53-F：更新 backfill_score_history 函数
--
-- ⚠️  使用说明：
--   只运行本文件，不要运行 fix15_week_aware_score.sql 全文！
--   fix15_week_aware_score.sql 包含旧版 compute_student_score（会覆盖
--   fix44_46_score_functions.sql 的所有最新修复），以及第 532 行的
--   TRUNCATE public.student_score_history（会清空所有历史数据）。
--
-- 本文件只包含 backfill_score_history 函数的最新版本（含 FIX-53-F 改动），
-- 不涉及任何其他函数，安全可独立执行。
--
-- 主要改动（FIX-53-F）：
--   步骤⑤→⑥：backfill 结束后自动调用 compute_and_store_w_score
--              刷新所有学生的实时 W 分，避免 backfill 后 W 卡片显示旧值
-- FIX-62（新增）：
--   步骤⑤：backfill 结束后先用 compute_baseline（CURRENT_DATE+1）重刷所有学生基线
--           修复 backfill 循环最后一次写入历史日基线导致本周记录被清零的 bug
-- ============================================================

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
    v_student_count INTEGER;
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

        -- ③ PERCENT_RANK（仅活跃学生）
        SELECT COUNT(DISTINCT sh.student_name) INTO v_student_count
        FROM public.student_score_history sh
        WHERE sh.snapshot_date = v_current_date
          AND sh.raw_score IS NOT NULL AND sh.raw_score > 0
          AND EXISTS (
              SELECT 1 FROM public.practice_sessions ps
              WHERE ps.student_name    = sh.student_name
                AND ps.cleaned_duration > 0
                AND ps.session_start  >= v_current_date::TIMESTAMPTZ
                AND ps.session_start  <  v_next_date::TIMESTAMPTZ);

        IF v_student_count >= 5 THEN
            UPDATE public.student_score_history h
            SET composite_score = norm.normalized
            FROM (
                SELECT sh.student_name,
                       ROUND(PERCENT_RANK() OVER (ORDER BY sh.raw_score) * 100)::INT AS normalized
                FROM public.student_score_history sh
                WHERE sh.snapshot_date = v_current_date
                  AND sh.raw_score IS NOT NULL AND sh.raw_score > 0
                  AND EXISTS (
                      SELECT 1 FROM public.practice_sessions ps
                      WHERE ps.student_name    = sh.student_name
                        AND ps.cleaned_duration > 0
                        AND ps.session_start  >= v_current_date::TIMESTAMPTZ
                        AND ps.session_start  <  v_next_date::TIMESTAMPTZ)
            ) norm
            WHERE h.snapshot_date = v_current_date AND h.student_name = norm.student_name;
        ELSE
            UPDATE public.student_score_history
            SET composite_score = ROUND((raw_score * 100)::NUMERIC, 1)
            WHERE snapshot_date = v_current_date
              AND raw_score IS NOT NULL AND raw_score > 0
              AND EXISTS (
                  SELECT 1 FROM public.practice_sessions ps
                  WHERE ps.student_name    = student_score_history.student_name
                    AND ps.cleaned_duration > 0
                    AND ps.session_start  >= v_current_date::TIMESTAMPTZ
                    AND ps.session_start  <  v_next_date::TIMESTAMPTZ);
        END IF;

        v_current_date := v_next_date;
    END LOOP;

    -- ④ [FIX-15] 同步最新有效分数到 student_baseline
    --    触发器仍处于关闭状态，防止 UPDATE 触发 compute_student_score 覆盖快照
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
    --    backfill 循环最后一次用 v_current_date（本周一）调用 compute_baseline_as_of，
    --    会把 student_baseline 覆写为"截止本周一"的历史值（本周新练琴记录丢失）。
    --    此步重新调用 compute_baseline（= CURRENT_DATE+1）确保基线恢复为最新状态。
    FOR v_student IN SELECT student_name FROM public.student_baseline ORDER BY student_name LOOP
        BEGIN
            PERFORM public.compute_baseline(v_student.student_name);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[backfill rebase] % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    -- ⑥ FIX-53-F: 刷新所有学生的实时 W 分
    --    此处调用 compute_and_store_w_score 确保 W 卡片显示最新值
    FOR v_student IN SELECT DISTINCT student_name FROM public.student_baseline LOOP
        BEGIN
            PERFORM public.compute_and_store_w_score(v_student.student_name);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[backfill w_score] % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
    RAISE NOTICE '回溯完成（FIX-62）：共 % 周，重算 % 条，零分 % 条',
        v_week_count, v_active_count, v_zero_count;
END;
$$;
