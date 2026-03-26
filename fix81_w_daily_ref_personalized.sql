-- ============================================================================
-- FIX-81: W 日均基准个性化升级（在不推翻现有框架下提升区分度）
--
-- 目标：
-- 1) 让 w_daily_ref 更贴合“学生自身工作日练琴习惯”（按天总分钟，而非单次均值）
-- 2) 保留贝叶斯收缩与同专业兜底，避免新生样本不足时失真
-- 3) 与现有 W 计算主框架兼容（ratio -> sigmoid）
--
-- 说明：
-- - 本补丁重点升级 compute_and_store_w_score 的日均基准建模
-- - 不改动排行榜口径与其他维度（B/T/M/A）
-- ============================================================================

-- ----------------------------------------------------------------------------
-- A) 计算“个性化 W 日均基准”的函数
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_personalized_w_daily_ref(p_student_name TEXT)
RETURNS TABLE (
  w_daily_ref        FLOAT8,
  personal_ref       FLOAT8,
  peer_ref           FLOAT8,
  effective_days     INTEGER,
  alpha_days         FLOAT8,
  active_days_per_wk FLOAT8,
  cv_daily           FLOAT8
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_major TEXT;
BEGIN
  SELECT student_major INTO v_major
  FROM public.student_baseline
  WHERE student_name = p_student_name;

  RETURN QUERY
  WITH daily AS (
    SELECT
      DATE(ps.session_start AT TIME ZONE 'Asia/Shanghai') AS d,
      SUM(ps.cleaned_duration)::FLOAT8 AS day_mins
    FROM public.practice_sessions ps
    WHERE ps.student_name = p_student_name
      AND ps.cleaned_duration > 0
      AND ps.session_start >= NOW() - INTERVAL '12 weeks'
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    GROUP BY DATE(ps.session_start AT TIME ZONE 'Asia/Shanghai')
  ),
  personal_stats AS (
    SELECT
      COUNT(*)::INT AS n_days,
      COALESCE(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY day_mins), 0)::FLOAT8 AS d50,
      COALESCE(PERCENTILE_CONT(0.70) WITHIN GROUP (ORDER BY day_mins), 0)::FLOAT8 AS d70,
      COALESCE(AVG(day_mins), 0)::FLOAT8 AS d_avg,
      COALESCE(STDDEV_POP(day_mins), 0)::FLOAT8 AS d_std
    FROM daily
  ),
  active_weeks AS (
    SELECT
      COALESCE(COUNT(DISTINCT DATE_TRUNC('week', d))::FLOAT8, 0) AS wk_cnt
    FROM daily
  ),
  personal_ref_calc AS (
    SELECT
      ps.n_days,
      ps.d50,
      ps.d70,
      ps.d_avg,
      ps.d_std,
      CASE WHEN ps.d_avg > 0 THEN ps.d_std / ps.d_avg ELSE 0 END::FLOAT8 AS cv,
      CASE WHEN aw.wk_cnt > 0 THEN ps.n_days / aw.wk_cnt ELSE 0 END::FLOAT8 AS active_days_per_wk,
      -- 核心：稳健统计组合，强调“日总分钟习惯”
      (0.50 * ps.d50 + 0.30 * ps.d70 + 0.20 * ps.d_avg)::FLOAT8 AS personal_ref_raw
    FROM personal_stats ps
    CROSS JOIN active_weeks aw
  ),
  adjusted_personal AS (
    SELECT
      prc.n_days,
      prc.cv,
      prc.active_days_per_wk,
      prc.personal_ref_raw,
      GREATEST(0.85, LEAST(1.10, 0.85 + 0.25 * LEAST(prc.active_days_per_wk / 5.0, 1.0)))::FLOAT8 AS freq_factor,
      GREATEST(0.85, LEAST(1.05, 1.10 - 0.25 * prc.cv))::FLOAT8 AS stability_factor
    FROM personal_ref_calc prc
  ),
  peer_daily AS (
    SELECT
      ps.student_name,
      DATE(ps.session_start AT TIME ZONE 'Asia/Shanghai') AS d,
      SUM(ps.cleaned_duration)::FLOAT8 AS day_mins
    FROM public.practice_sessions ps
    JOIN public.student_baseline sb ON sb.student_name = ps.student_name
    WHERE ps.cleaned_duration > 0
      AND ps.session_start >= NOW() - INTERVAL '12 weeks'
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
      AND (
        (v_major IS NOT NULL AND sb.student_major = v_major)
        OR (v_major IS NULL)
      )
    GROUP BY ps.student_name, DATE(ps.session_start AT TIME ZONE 'Asia/Shanghai')
  ),
  peer_ref_calc AS (
    SELECT
      COALESCE(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY day_mins), 60)::FLOAT8 AS peer_daily_median
    FROM peer_daily
  ),
  recent4 AS (
    SELECT
      COALESCE(SUM(ps.cleaned_duration), 0)::FLOAT8 AS mins_4w,
      GREATEST(
        1.0,
        (
          COUNT(DISTINCT DATE(ps.session_start AT TIME ZONE 'Asia/Shanghai')) FILTER (
            WHERE EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
          )
        )::FLOAT8
      ) AS active_days_4w
    FROM public.practice_sessions ps
    WHERE ps.student_name = p_student_name
      AND ps.cleaned_duration > 0
      AND ps.session_start >= NOW() - INTERVAL '4 weeks'
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  ),
  final_ref AS (
    SELECT
      ap.n_days AS effective_days,
      ap.cv AS cv_daily,
      ap.active_days_per_wk,
      (ap.personal_ref_raw * ap.freq_factor * ap.stability_factor)::FLOAT8 AS personal_ref,
      pr.peer_daily_median::FLOAT8 AS peer_ref,
      LEAST(1.0, ap.n_days / 30.0)::FLOAT8 AS alpha_days,
      (r4.mins_4w / r4.active_days_4w)::FLOAT8 AS recent4_active_day_avg
    FROM adjusted_personal ap
    CROSS JOIN peer_ref_calc pr
    CROSS JOIN recent4 r4
  )
  SELECT
    -- 最终基准：个体优先 + 样本不足时向群体收缩 + 最近4周下限保护（防止偏低）
    GREATEST(
      30.0,
      LEAST(
        240.0,
        CASE
          -- 仅当样本与频率都足够时，才启用 peer 下限，避免新生/稀疏样本被“同专业中位数”硬抬高
          WHEN fr.effective_days >= 12 AND fr.active_days_per_wk >= 3.0 THEN
            GREATEST(
              (fr.alpha_days * fr.personal_ref + (1.0 - fr.alpha_days) * fr.peer_ref),
              0.85 * fr.recent4_active_day_avg,
              0.70 * fr.peer_ref
            )
          ELSE
            GREATEST(
              (fr.alpha_days * fr.personal_ref + (1.0 - fr.alpha_days) * fr.peer_ref),
              0.85 * fr.recent4_active_day_avg
            )
        END
      )
    )::FLOAT8 AS w_daily_ref,
    fr.personal_ref,
    fr.peer_ref,
    fr.effective_days,
    fr.alpha_days,
    fr.active_days_per_wk,
    fr.cv_daily
  FROM final_ref fr;
END;
$$;


-- ----------------------------------------------------------------------------
-- B) 重建 compute_and_store_w_score：改用个性化日均基准
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_and_store_w_score(p_student_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_weekly_minutes  FLOAT8;
  v_elapsed_days    INT;
  v_ratio           FLOAT8;
  v_w_score         FLOAT8;
  v_dow             INT;
  v_week_start      TIMESTAMPTZ;
  v_w_daily_ref     FLOAT8;
BEGIN
  SELECT w_daily_ref
  INTO v_w_daily_ref
  FROM public.get_personalized_w_daily_ref(p_student_name);

  IF v_w_daily_ref IS NULL OR v_w_daily_ref <= 0 THEN
    v_w_daily_ref := 60.0; -- 安全兜底
  END IF;

  v_week_start := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')
                    AT TIME ZONE 'Asia/Shanghai';

  SELECT COALESCE(SUM(cleaned_duration), 0) INTO v_weekly_minutes
  FROM public.practice_sessions
  WHERE student_name = p_student_name
    AND session_start >= v_week_start
    AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

  v_dow := EXTRACT(DOW FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INT;
  v_elapsed_days := CASE v_dow
    WHEN 0 THEN 5
    WHEN 6 THEN 5
    ELSE v_dow
  END;

  IF v_elapsed_days = 0 THEN
    v_w_score := 0.5;
  ELSE
    v_ratio   := v_weekly_minutes / (v_w_daily_ref * v_elapsed_days);
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


-- ----------------------------------------------------------------------------
-- C) 可选：批量刷新全体学生 W 分（上线后建议跑一次）
-- ----------------------------------------------------------------------------
-- SELECT public.compute_and_store_w_score(student_name)
-- FROM public.student_baseline;

