-- ============================================================
-- FIX-54：compute_and_store_w_score 周日(DOW=0)漏洞修复
--
-- 问题：独立函数 compute_and_store_w_score 的 v_elapsed_days 判断
--   旧：WHEN 0 THEN 0  → 周日时 elapsed=0 → w_score 恒为 0.5（整周数据被无视）
--   新：WHEN 0 THEN 5  → 周日视为本周已过5个工作日（与 compute_student_score 一致）
--
-- 背景：FIX-53-A 已修复 compute_student_score 内联 W 计算，
--   但独立函数（被 backfill 和手动批量调用）未同步更新，
--   导致每当周日执行 backfill_score_history() 时，
--   所有学生 w_score 被错误覆盖为 0.5。
--
-- 部署后执行（可选，若当天是周日）：
--   SELECT public.compute_and_store_w_score(student_name)
--     FROM public.student_baseline;
-- ============================================================

CREATE OR REPLACE FUNCTION public.compute_and_store_w_score(p_student_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_mean_duration   FLOAT8;
  v_weekly_minutes  FLOAT8;
  v_elapsed_days    INT;
  v_ratio           FLOAT8;
  v_w_score         FLOAT8;
  v_dow             INT;
  v_week_start      TIMESTAMPTZ;
  -- FIX-37：贝叶斯收缩变量
  v_median_mean     FLOAT8;
  v_major           TEXT;
  v_major_count     INT;
  v_shrink_alpha    FLOAT8;
  v_effective_mean  FLOAT8;
BEGIN
  SELECT mean_duration, student_major
  INTO v_mean_duration, v_major
  FROM public.student_baseline
  WHERE student_name = p_student_name;

  -- FIX-37：同专业优先计算中位数（与 compute_student_score 对齐）
  SELECT COUNT(*) INTO v_major_count
  FROM public.student_baseline
  WHERE student_major = v_major AND mean_duration > 0;

  IF v_major_count >= 5 THEN
    SELECT percentile_cont(0.50) WITHIN GROUP (ORDER BY mean_duration)
    INTO v_median_mean
    FROM public.student_baseline
    WHERE mean_duration IS NOT NULL AND mean_duration > 0
      AND student_major = v_major;
  ELSE
    SELECT percentile_cont(0.50) WITHIN GROUP (ORDER BY mean_duration)
    INTO v_median_mean
    FROM public.student_baseline
    WHERE mean_duration IS NOT NULL AND mean_duration > 0;
  END IF;

  -- FIX-37：贝叶斯收缩（与 compute_student_score 保持一致）
  SELECT record_count INTO v_shrink_alpha
  FROM public.student_baseline
  WHERE student_name = p_student_name;
  v_shrink_alpha   := LEAST(1.0, COALESCE(v_shrink_alpha, 0)::FLOAT8 / 15.0);
  v_effective_mean := v_shrink_alpha * COALESCE(v_mean_duration, 0.0)
                    + (1.0 - v_shrink_alpha) * COALESCE(v_median_mean, 30.0);
  v_effective_mean := GREATEST(v_effective_mean, 15.0);

  -- FIX-26：北京时间本周一 00:00:00
  v_week_start := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')
                    AT TIME ZONE 'Asia/Shanghai';

  -- 只统计工作日（排除周六周日）
  SELECT COALESCE(SUM(cleaned_duration), 0) INTO v_weekly_minutes
  FROM public.practice_sessions
  WHERE student_name = p_student_name
    AND session_start >= v_week_start
    AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

  v_dow := EXTRACT(DOW FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INT;
  -- FIX-53-A：周日(DOW=0)视为本周已过5个工作日，与 compute_student_score 保持一致
  v_elapsed_days := CASE v_dow
    WHEN 0 THEN 5
    WHEN 6 THEN 5
    ELSE v_dow
  END;

  IF v_elapsed_days = 0 OR v_effective_mean <= 0 THEN
    v_w_score := 0.5;
  ELSE
    -- FIX-37：分母使用贝叶斯收缩后的基准均值
    v_ratio   := v_weekly_minutes / (GREATEST(v_effective_mean, 30.0) * v_elapsed_days);
    v_w_score := 1.0 / (1.0 + EXP(-3.0 * (v_ratio - 0.5)));
  END IF;

  PERFORM set_config('app.skip_score_trigger', 'on', true);
  UPDATE public.student_baseline SET w_score = v_w_score WHERE student_name = p_student_name;
  PERFORM set_config('app.skip_score_trigger', 'off', true);
END;
$$;
