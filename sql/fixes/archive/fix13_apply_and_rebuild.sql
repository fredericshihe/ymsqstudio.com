-- ================================================================
-- FIX-13 完整部署 + 历史数据重算
--
-- 核心规则（v2 — 零分制）：
--   · 本周有练琴记录 → 正常重算成长分，参与 PERCENT_RANK
--   · 本周无练琴记录 → composite_score = 0，不参与排名
--   · 练琴恢复后    → 正常重算，分数从实际表现重新起算
--
-- 执行方式：在 Supabase SQL Editor 全选粘贴，一次性 Run
-- 预计耗时：30 秒 ~ 3 分钟
-- ================================================================


-- ================================================================
-- STEP 1: 新版 run_weekly_score_update
-- ================================================================
CREATE OR REPLACE FUNCTION public.run_weekly_score_update()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_student       RECORD;
    v_monday        DATE;
    v_student_count INTEGER;
    v_last_session  DATE;
BEGIN
    PERFORM set_config('app.skip_score_trigger', 'on', TRUE);
    v_monday := DATE_TRUNC('week', CURRENT_DATE)::DATE;
    RAISE NOTICE '[%] 每周评分更新（FIX-13 v2），快照日期：%', NOW(), v_monday;

    -- ① 所有学生更新 baseline
    FOR v_student IN SELECT student_name FROM public.student_baseline ORDER BY student_name LOOP
        BEGIN
            PERFORM public.compute_baseline_as_of(
                v_student.student_name, (CURRENT_DATE + INTERVAL '1 day')::DATE);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[weekly baseline] 学生 % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    -- ② 成长分：活跃 → 重算；未练 → 写入 0 分快照
    FOR v_student IN SELECT student_name FROM public.student_baseline ORDER BY student_name LOOP
        BEGIN
            SELECT MAX(session_start::DATE) INTO v_last_session
            FROM public.practice_sessions WHERE student_name = v_student.student_name;

            IF v_last_session >= v_monday THEN
                -- 本周有练琴：正常计算
                PERFORM public.compute_student_score_as_of(v_student.student_name, v_monday);
            ELSE
                -- 本周无练琴：写入 0 分（若本周快照已存在则跳过）
                INSERT INTO public.student_score_history
                    (student_name, snapshot_date, raw_score, composite_score,
                     baseline_score, trend_score, momentum_score, accum_score,
                     outlier_rate, short_session_rate, mean_duration, record_count)
                VALUES
                    (v_student.student_name, v_monday, 0, 0,
                     NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
                ON CONFLICT (student_name, snapshot_date) DO NOTHING;

                RAISE NOTICE '[weekly] 学生 % 本周无练琴，写入 0 分', v_student.student_name;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[weekly score] 学生 % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    -- ③ PERCENT_RANK：只对本周活跃学生（人数 < 5 时跳过）
    SELECT COUNT(DISTINCT sh.student_name) INTO v_student_count
    FROM public.student_score_history sh
    WHERE sh.snapshot_date = v_monday
      AND sh.raw_score IS NOT NULL AND sh.raw_score > 0
      AND EXISTS (
          SELECT 1 FROM public.practice_sessions ps
          WHERE ps.student_name = sh.student_name
            AND ps.session_start::DATE >= v_monday);

    IF v_student_count >= 5 THEN
        UPDATE public.student_score_history h
        SET composite_score = norm.normalized
        FROM (
            SELECT sh.student_name,
                   ROUND(PERCENT_RANK() OVER (ORDER BY sh.raw_score) * 100)::INT AS normalized
            FROM public.student_score_history sh
            WHERE sh.snapshot_date = v_monday
              AND sh.raw_score IS NOT NULL AND sh.raw_score > 0
              AND EXISTS (
                  SELECT 1 FROM public.practice_sessions ps
                  WHERE ps.student_name = sh.student_name
                    AND ps.session_start::DATE >= v_monday)
        ) norm
        WHERE h.snapshot_date = v_monday AND h.student_name = norm.student_name;
        RAISE NOTICE '[PERCENT_RANK] 本周活跃学生：%', v_student_count;
    END IF;

    -- ④ 同步最新 composite_score 到 student_baseline
    --    未练琴学生 baseline 保留上次有效分（不被 0 覆盖）
    UPDATE public.student_baseline b
    SET composite_score = h.composite_score
    FROM public.student_score_history h
    WHERE h.student_name  = b.student_name
      AND h.snapshot_date = v_monday
      AND h.composite_score > 0;   -- 只用正常分数同步，0 不回写 baseline

    PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
    RAISE NOTICE '[%] 每周更新完成（FIX-13 v2）', NOW();
END;
$$;


-- ================================================================
-- STEP 2: 新版 backfill_score_history（历史回溯同样用零分制）
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
    v_student_count INTEGER;
BEGIN
    PERFORM set_config('app.skip_score_trigger', 'on', TRUE);

    SELECT DATE_TRUNC('week', MIN(session_start))::DATE INTO v_start_date
    FROM public.practice_sessions WHERE cleaned_duration > 0;

    v_end_date     := DATE_TRUNC('week', CURRENT_DATE)::DATE;
    v_current_date := v_start_date;
    RAISE NOTICE '回溯范围：% → %（零分制 FIX-13 v2）', v_start_date, v_end_date;

    WHILE v_current_date <= v_end_date LOOP
        v_week_count := v_week_count + 1;
        v_next_date  := v_current_date + INTERVAL '7 days';

        -- ① baseline：对截止本周一有历史数据的所有学生
        FOR v_student IN
            SELECT DISTINCT student_name FROM public.practice_sessions
            WHERE session_start < v_current_date::TIMESTAMPTZ AND cleaned_duration > 0
            ORDER BY student_name
        LOOP
            BEGIN
                PERFORM public.compute_baseline_as_of(v_student.student_name, v_current_date);
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '[backfill baseline] 学生 % 第 % 周失败：%',
                    v_student.student_name, v_current_date, SQLERRM;
            END;
        END LOOP;

        -- ② 成长分：本周有练琴 → 重算；本周无练琴 → 写 0
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
                    -- 本周活跃：正常计算
                    PERFORM public.compute_student_score_as_of(v_student.student_name, v_current_date);
                    v_active_count := v_active_count + 1;
                ELSE
                    -- 本周未练：写入 0 分（有唯一约束则跳过）
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
                RAISE WARNING '[backfill score] 学生 % 第 % 周失败：%',
                    v_student.student_name, v_current_date, SQLERRM;
            END;
        END LOOP;

        -- ③ PERCENT_RANK：只对本周活跃学生（人数 < 5 时跳过）
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
            -- 活跃人数不足：用 raw_score × 100 作为 composite_score
            UPDATE public.student_score_history
            SET composite_score = ROUND(raw_score * 100)::INT
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

    PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
    RAISE NOTICE '回溯完成：共 % 周，重算 % 条，零分 % 条',
        v_week_count, v_active_count, v_zero_count;
END;
$$;


-- ================================================================
-- STEP 3: 清空历史快照
-- ================================================================
TRUNCATE public.student_score_history;


-- ================================================================
-- STEP 4: 全量重算历史
-- ================================================================
SELECT public.backfill_score_history();


-- ================================================================
-- STEP 5: 同步最新有效分数到 student_baseline
--         （取最近一条 composite_score > 0 的快照）
-- ================================================================
UPDATE public.student_baseline b
SET composite_score = latest.composite_score
FROM (
    SELECT DISTINCT ON (student_name)
        student_name, composite_score
    FROM public.student_score_history
    WHERE composite_score > 0
    ORDER BY student_name, snapshot_date DESC
) latest
WHERE b.student_name = latest.student_name;


-- ================================================================
-- 验证（去掉 -- 后执行）
-- ================================================================
-- 查看某学生历史，确认无练琴周是否正确显示 0：
-- SELECT student_name, snapshot_date, composite_score
-- FROM public.student_score_history
-- WHERE student_name = '你的学生名'
-- ORDER BY snapshot_date DESC LIMIT 20;
--
-- 统计各周有多少学生是 0 分（无练琴）vs 正常分：
-- SELECT snapshot_date,
--        COUNT(*) FILTER (WHERE composite_score = 0)  AS no_practice,
--        COUNT(*) FILTER (WHERE composite_score > 0)  AS active
-- FROM public.student_score_history
-- GROUP BY snapshot_date
-- ORDER BY snapshot_date DESC LIMIT 10;
