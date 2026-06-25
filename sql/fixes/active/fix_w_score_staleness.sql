-- ============================================================================
-- 修复：W 分陈旧值（stale）问题
-- 文件：fix_w_score_staleness.sql
-- 目标：
-- 1) 一次性把全体学生 W 分刷新到“当前周当前时刻”口径
-- 2) 建立定时任务，避免 W 分因 elapsed_days 变化而陈旧
-- ============================================================================

-- ---------------------------------------------------------------------------
-- A) 创建批量刷新函数（幂等）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_all_w_scores()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_rec RECORD;
  v_week_monday DATE;
  v_week_start_bjt TIMESTAMPTZ;
  v_has_current_week_session BOOLEAN;
BEGIN
  v_week_monday := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
  v_week_start_bjt := (v_week_monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';

  FOR v_rec IN
    SELECT student_name
    FROM public.student_baseline
    WHERE student_name IS NOT NULL
  LOOP
    SELECT EXISTS (
      SELECT 1
      FROM public.practice_sessions
      WHERE student_name = v_rec.student_name
        AND cleaned_duration > 0
        AND session_start >= v_week_start_bjt
        AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    )
    INTO v_has_current_week_session;

    IF v_has_current_week_session THEN
      -- 本周已练琴：完整重算当前周综合分，确保 W 变化同步进入 composite_score
      PERFORM public.compute_student_score(v_rec.student_name);
    ELSE
      -- 本周未练琴：仅刷新 W 展示值，避免无意义重写当前周零分快照
      PERFORM public.compute_and_store_w_score(v_rec.student_name);
    END IF;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION public.refresh_all_w_scores() IS
'Refresh W for all students, and fully recompute current-week composite scores for students with active workday practice this week.';


-- ---------------------------------------------------------------------------
-- B) 立即执行一次全量刷新（修复现有陈旧值）
-- ---------------------------------------------------------------------------
SELECT public.refresh_all_w_scores();


-- ---------------------------------------------------------------------------
-- C) 建立 pg_cron 任务（工作日定时刷新）
-- 说明：
-- - W 分依赖“已过工作日天数”，即使无新 session 也会变化
-- - 当前配置：工作日每天 1 次（20:05）兜底刷新
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM cron.unschedule('refresh_w_score_weekday_2h');
EXCEPTION
  WHEN OTHERS THEN NULL;
END $$;

DO $$
BEGIN
  PERFORM cron.unschedule('refresh_w_score_weekday_daily');
EXCEPTION
  WHEN OTHERS THEN NULL;
END $$;

SELECT cron.schedule(
  'refresh_w_score_weekday_daily',
  '5 20 * * 1-5',  -- 周一到周五 20:05（Asia/Shanghai）
  $$SELECT public.refresh_all_w_scores();$$
);


-- ---------------------------------------------------------------------------
-- D) 可选：每周一 00:10 再补一次（开周重置口径）
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM cron.unschedule('refresh_w_score_monday_bootstrap');
EXCEPTION
  WHEN OTHERS THEN NULL;
END $$;

SELECT cron.schedule(
  'refresh_w_score_monday_bootstrap',
  '10 0 * * 1',
  $$SELECT public.refresh_all_w_scores();$$
);


-- ---------------------------------------------------------------------------
-- E) 验证任务是否存在
-- ---------------------------------------------------------------------------
SELECT jobname, schedule, command
FROM cron.job
WHERE jobname IN ('refresh_w_score_weekday_daily', 'refresh_w_score_monday_bootstrap')
ORDER BY jobname;
