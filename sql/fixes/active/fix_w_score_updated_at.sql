-- ============================================================================
-- FIX: W 分刷新时间可观测性（w_score_updated_at）
-- 文件：fix_w_score_updated_at.sql
-- 目标：
-- 1) 新增 student_baseline.w_score_updated_at
-- 2) compute_and_store_w_score 每次刷新都写入该时间
-- 3) compute_student_score 路径下也能自动同步该时间（触发器）
-- ============================================================================

-- ---------------------------------------------------------------------------
-- A) 新增列（幂等）
-- ---------------------------------------------------------------------------
ALTER TABLE public.student_baseline
  ADD COLUMN IF NOT EXISTS w_score_updated_at TIMESTAMPTZ;

COMMENT ON COLUMN public.student_baseline.w_score_updated_at IS
'Last refresh timestamp for w_score.';

-- 先回填一次，避免历史空值
UPDATE public.student_baseline
SET w_score_updated_at = COALESCE(last_updated, NOW())
WHERE w_score IS NOT NULL
  AND w_score_updated_at IS NULL;


-- ---------------------------------------------------------------------------
-- B) 重建 compute_and_store_w_score（与现网逻辑一致，仅补写 w_score_updated_at）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_and_store_w_score(p_student_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
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
  UPDATE public.student_baseline
  SET
    w_score = v_w_score,
    w_score_updated_at = NOW()
  WHERE student_name = p_student_name;
  PERFORM set_config('app.skip_score_trigger', 'off', true);
END;
$function$;


-- ---------------------------------------------------------------------------
-- C) 触发器：compute_student_score 路径（会改 last_updated）也同步 W 刷新时间
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_sync_w_score_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- 如果 W 分数被直接改动，优先记录当前时刻
  IF NEW.w_score IS DISTINCT FROM OLD.w_score THEN
    NEW.w_score_updated_at := NOW();
    RETURN NEW;
  END IF;

  -- 如果是综合重算路径（last_updated 变化），且携带了 w_score，则同步更新时间
  IF NEW.last_updated IS DISTINCT FROM OLD.last_updated
     AND NEW.w_score IS NOT NULL THEN
    NEW.w_score_updated_at := COALESCE(NEW.last_updated, NOW());
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_w_score_updated_at ON public.student_baseline;
CREATE TRIGGER trg_sync_w_score_updated_at
BEFORE UPDATE ON public.student_baseline
FOR EACH ROW
EXECUTE FUNCTION public.tg_sync_w_score_updated_at();


-- ---------------------------------------------------------------------------
-- D) 验证
-- ---------------------------------------------------------------------------
SELECT
  column_name,
  data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'student_baseline'
  AND column_name = 'w_score_updated_at';

