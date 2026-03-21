-- ============================================================
-- FIX-77：修复 backfill 后 raw_score 与 composite_score 漂移
--
-- 问题：
--   backfill_score_history 旧逻辑仅回写 student_baseline.composite_score，
--   未同步 raw_score，导致 baseline 出现：
--     composite_score != ROUND(raw_score * 100, 1)
--
-- 修复：
--   1) 更新 backfill_score_history 函数：回写 baseline 时同时写 raw_score + composite_score
--   2) 立刻执行一次一次性对齐 SQL，修复当前库中已漂移学生
--
-- 使用：
--   先执行本文件
--   再执行：SELECT public.backfill_score_history();
-- ============================================================

CREATE OR REPLACE FUNCTION public.backfill_score_history()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_start_date     DATE;
    v_end_date       DATE;
    v_current_date   DATE;
    v_next_date      DATE;
    v_week_start_bjt TIMESTAMPTZ;
    v_week_next_bjt  TIMESTAMPTZ;
    v_student        RECORD;
    v_week_count     INTEGER := 0;
    v_active_count   INTEGER := 0;
    v_zero_count     INTEGER := 0;
BEGIN
    PERFORM set_config('app.skip_score_trigger', 'on', TRUE);

    SELECT DATE_TRUNC('week', MIN(session_start))::DATE INTO v_start_date
    FROM public.practice_sessions
    WHERE cleaned_duration > 0;

    v_end_date     := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
    v_current_date := v_start_date;

    RAISE NOTICE '回溯范围：% → %（FIX-77）', v_start_date, v_end_date;

    WHILE v_current_date <= v_end_date LOOP
        v_week_count := v_week_count + 1;
        v_next_date  := v_current_date + INTERVAL '7 days';
        v_week_start_bjt := (v_current_date::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';
        v_week_next_bjt  := (v_next_date::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';

        FOR v_student IN
            SELECT DISTINCT student_name
            FROM public.practice_sessions
            WHERE session_start < v_week_start_bjt
              AND cleaned_duration > 0
            ORDER BY student_name
        LOOP
            BEGIN
                PERFORM public.compute_baseline_as_of(v_student.student_name, v_current_date);
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '[backfill baseline] % @ % 失败：%', v_student.student_name, v_current_date, SQLERRM;
            END;
        END LOOP;

        FOR v_student IN
            SELECT DISTINCT student_name
            FROM public.practice_sessions
            WHERE session_start < v_week_start_bjt
              AND cleaned_duration > 0
            ORDER BY student_name
        LOOP
            BEGIN
                IF EXISTS (
                    SELECT 1
                    FROM public.practice_sessions
                    WHERE student_name     = v_student.student_name
                      AND cleaned_duration > 0
                      AND session_start   >= v_week_start_bjt
                      AND session_start   <  v_week_next_bjt
                ) THEN
                    PERFORM public.compute_student_score_as_of(v_student.student_name, v_current_date);
                    v_active_count := v_active_count + 1;
                ELSE
                    INSERT INTO public.student_score_history (
                        student_name, snapshot_date, raw_score, composite_score,
                        baseline_score, trend_score, momentum_score, accum_score,
                        outlier_rate, short_session_rate, mean_duration, record_count
                    ) VALUES (
                        v_student.student_name, v_current_date, 0, 0,
                        NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
                    )
                    ON CONFLICT (student_name, snapshot_date) DO NOTHING;
                    v_zero_count := v_zero_count + 1;
                END IF;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '[backfill score] % @ % 失败：%', v_student.student_name, v_current_date, SQLERRM;
            END;
        END LOOP;

        UPDATE public.student_score_history
        SET composite_score = ROUND((raw_score * 100)::NUMERIC, 1)
        WHERE snapshot_date   = v_current_date
          AND raw_score       IS NOT NULL
          AND raw_score        > 0
          AND (composite_score IS NULL OR composite_score <> ROUND((raw_score * 100)::NUMERIC, 1));

        v_current_date := v_next_date;
    END LOOP;

    -- FIX-77：同步 baseline 时 raw + composite 一起写
    UPDATE public.student_baseline b
    SET raw_score       = latest.raw_score,
        composite_score = ROUND((latest.raw_score * 100)::NUMERIC, 1)
    FROM (
        SELECT DISTINCT ON (student_name) student_name, raw_score
        FROM public.student_score_history
        WHERE raw_score IS NOT NULL
        ORDER BY student_name, snapshot_date DESC
    ) latest
    WHERE b.student_name = latest.student_name;

    FOR v_student IN
        SELECT student_name
        FROM public.student_baseline
        ORDER BY student_name
    LOOP
        BEGIN
            PERFORM public.compute_baseline(v_student.student_name);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[backfill rebase] % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    FOR v_student IN
        SELECT DISTINCT student_name
        FROM public.student_baseline
    LOOP
        BEGIN
            PERFORM public.compute_and_store_w_score(v_student.student_name);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[backfill w_score] % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
    RAISE NOTICE '回溯完成（FIX-77）：共 % 周，重算 % 条，零分 % 条',
        v_week_count, v_active_count, v_zero_count;
END;
$$;


-- 一次性修复：立即把 baseline 对齐到最新历史快照
WITH latest AS (
  SELECT DISTINCT ON (student_name)
      student_name,
      raw_score
  FROM public.student_score_history
  WHERE raw_score IS NOT NULL
  ORDER BY student_name, snapshot_date DESC
)
UPDATE public.student_baseline b
SET raw_score       = latest.raw_score,
    composite_score = ROUND((latest.raw_score * 100)::NUMERIC, 1)
FROM latest
WHERE b.student_name = latest.student_name;
