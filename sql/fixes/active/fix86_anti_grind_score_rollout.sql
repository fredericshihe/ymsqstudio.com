-- ============================================================================
-- FIX-86: 综合榜规则优化（反无限卷时长版）正式切换
--
-- 目标：
-- 1) 直接覆盖评分派生链：student_score_history / student_baseline
-- 2) 从现在开始，最新排行榜与本周五发币都按新规则运行
-- 3) 明确不改历史事实：
--    - weekly_leaderboard_history
--    - student_coins
--    - coin_transactions
--    - weekly_coin_reward_log
--    - weekly_coin_reward_detail
--
-- 设计原则：
-- - W：本周完成度封顶，不再鼓励无上限堆时长
-- - B/T：改为“目标完成率变化/趋势”，不是裸分钟持续加量
-- - M：最近4活跃周的稳定达标与波动控制
-- - A：同专业长期周量水平 + 长期活跃稳定度
-- - 移除旧版 peak_decay 的隐性高峰衰退惩罚，避免“够练也提不上去”
--
-- 使用顺序：
--   1) 先执行本文件
--   2) 再执行：SELECT public.backfill_score_history();
--   3) 如需一键完整执行：SELECT public.apply_fix86_score_rollout();
--
-- 注意：
-- - 本文件允许覆盖 student_score_history / student_baseline 的派生分
-- - 本文件不会写入任何音符币相关表，也不会改写 weekly_leaderboard_history
-- ============================================================================

-- ---------------------------------------------------------------------------
-- A) 统一目标周计算：双锚目标（个人参考 + 同专业地板）
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_rule_v2_week_target_context(
  p_student_name TEXT,
  p_week_monday  DATE DEFAULT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
)
RETURNS TABLE (
  final_target_week    FLOAT8,
  personal_target_week FLOAT8,
  major_floor_week     FLOAT8,
  personal_week_ref    FLOAT8,
  peer_week_ref        FLOAT8,
  effective_mean       FLOAT8
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_major            TEXT;
  v_mean_duration    FLOAT8;
  v_record_count     INTEGER;
  v_week_start_bjt   TIMESTAMPTZ;
  v_median_mean      FLOAT8;
  v_self_p50         FLOAT8;
  v_self_p70         FLOAT8;
  v_self_avg         FLOAT8;
  v_personal_ref     FLOAT8;
  v_peer_ref         FLOAT8;
  v_shrink_alpha     FLOAT8;
  v_effective_mean   FLOAT8;
  v_personal_target  FLOAT8;
  v_major_floor      FLOAT8;
  v_final_target     FLOAT8;
BEGIN
  SELECT
    student_major,
    mean_duration,
    record_count
  INTO
    v_major,
    v_mean_duration,
    v_record_count
  FROM public.student_baseline
  WHERE student_name = p_student_name;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_week_start_bjt := (p_week_monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';

  SELECT percentile_cont(0.50) WITHIN GROUP (ORDER BY mean_duration)
  INTO v_median_mean
  FROM public.student_baseline
  WHERE mean_duration IS NOT NULL
    AND mean_duration > 0
    AND (
      (v_major IS NOT NULL AND student_major = v_major)
      OR v_major IS NULL
    );

  v_shrink_alpha := LEAST(1.0, COALESCE(v_record_count, 0)::FLOAT8 / 15.0);
  v_effective_mean := v_shrink_alpha * COALESCE(v_mean_duration, 0.0)
                    + (1.0 - v_shrink_alpha) * COALESCE(v_median_mean, 30.0);
  v_effective_mean := GREATEST(v_effective_mean, 15.0);

  WITH self_weekly AS (
    SELECT
      DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE AS week_start,
      SUM(ps.cleaned_duration)::FLOAT8 AS weekly_mins
    FROM public.practice_sessions ps
    WHERE ps.student_name     = p_student_name
      AND ps.cleaned_duration > 0
      AND ps.session_start    < v_week_start_bjt
      AND ps.session_start   >= v_week_start_bjt - INTERVAL '16 weeks'
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    GROUP BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE
    HAVING SUM(ps.cleaned_duration) > 0
  ),
  self_recent AS (
    SELECT
      weekly_mins,
      ROW_NUMBER() OVER (ORDER BY week_start DESC) AS rn
    FROM self_weekly
  )
  SELECT
    percentile_cont(0.50) WITHIN GROUP (ORDER BY weekly_mins),
    percentile_cont(0.70) WITHIN GROUP (ORDER BY weekly_mins),
    AVG(weekly_mins)
  INTO
    v_self_p50,
    v_self_p70,
    v_self_avg
  FROM self_recent
  WHERE rn <= 8;

  v_personal_ref := GREATEST(
    COALESCE(0.50 * v_self_p50 + 0.30 * v_self_p70 + 0.20 * v_self_avg, 0.0),
    GREATEST(v_effective_mean, 30.0) * 5.0
  );

  WITH peer_weekly AS (
    SELECT
      SUM(ps.cleaned_duration)::FLOAT8 AS weekly_mins
    FROM public.practice_sessions ps
    JOIN public.student_baseline sb
      ON sb.student_name = ps.student_name
    WHERE ps.cleaned_duration > 0
      AND ps.session_start    < v_week_start_bjt
      AND ps.session_start   >= v_week_start_bjt - INTERVAL '16 weeks'
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
      AND (
        (v_major IS NOT NULL AND sb.student_major = v_major)
        OR v_major IS NULL
      )
    GROUP BY ps.student_name, DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE
    HAVING SUM(ps.cleaned_duration) > 0
  )
  SELECT percentile_cont(0.50) WITHIN GROUP (ORDER BY weekly_mins)
  INTO v_peer_ref
  FROM peer_weekly;

  v_peer_ref := GREATEST(COALESCE(v_peer_ref, v_personal_ref, 300.0), 240.0);
  v_personal_target := LEAST(1500.0, GREATEST(270.0, COALESCE(v_personal_ref, 300.0)));
  v_major_floor     := LEAST(1500.0, GREATEST(240.0, v_peer_ref * 0.80));
  v_final_target    := GREATEST(v_personal_target, v_major_floor);

  RETURN QUERY
  SELECT
    v_final_target,
    v_personal_target,
    v_major_floor,
    v_personal_ref,
    v_peer_ref,
    v_effective_mean;
END;
$$;


-- ---------------------------------------------------------------------------
-- B) 新规则核心计算：返回五维与总分，不直接写表
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_student_score_rule_v2_core(
  p_student_name  TEXT,
  p_snapshot_date DATE
)
RETURNS TABLE (
  composite_score    NUMERIC,
  raw_score          FLOAT8,
  baseline_score     FLOAT8,
  trend_score        FLOAT8,
  momentum_score     FLOAT8,
  accum_score        FLOAT8,
  w_score            FLOAT8,
  score_confidence   FLOAT8,
  growth_velocity    FLOAT8,
  weeks_improving    INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  r                    RECORD;
  ctx                  RECORD;
  v_week_monday        DATE;
  v_current_monday     DATE;
  v_week_start_bjt     TIMESTAMPTZ;
  v_week_next_bjt      TIMESTAMPTZ;
  v_hist_count         INTEGER := 0;
  v_b_score            FLOAT8  := 0.5;
  v_t_score            FLOAT8  := 0.5;
  v_m_score            FLOAT8  := 0.5;
  v_a_score            FLOAT8  := 0.5;
  v_w_score            FLOAT8  := 0.5;
  v_score_conf         FLOAT8  := 0.5;
  v_growth_velocity    FLOAT8  := 0.0;
  v_weeks_met          INTEGER := 0;
  v_outlier_penalty    FLOAT8  := 1.0;
  v_weight_b           FLOAT8;
  v_weight_t           FLOAT8;
  v_weight_m           FLOAT8;
  v_weight_a           FLOAT8;
  v_weight_w           FLOAT8;
  v_elapsed_days       INTEGER := 5;
  v_week_minutes       FLOAT8  := 0.0;
  v_week_completion    FLOAT8  := 0.0;
  v_target_week        FLOAT8  := 300.0;
  v_recent_avg         FLOAT8;
  v_older_avg          FLOAT8;
  v_recent_completion  FLOAT8;
  v_older_completion   FLOAT8;
  v_b_change           FLOAT8  := 0.5;
  v_t_change           FLOAT8  := 0.5;
  v_b_level            FLOAT8  := 0.5;
  v_t_level            FLOAT8  := 0.5;
  v_b_delta            FLOAT8  := 0.0;
  v_t_delta            FLOAT8  := 0.0;
  v_w1_mins            FLOAT8;
  v_w2_mins            FLOAT8;
  v_comp1              FLOAT8;
  v_comp2              FLOAT8;
  v_long_median        FLOAT8;
  v_long_active_ratio  FLOAT8  := 0.5;
  v_long_quality       FLOAT8  := 0.5;
  v_peer_level         FLOAT8  := 0.5;
  v_completion_sd      FLOAT8  := 0.0;
  v_weighted_completion FLOAT8 := 0.0;
  vel_rec              RECORD;
  v_vel_cnt4           INT     := 0;
  v_vel_sum4           FLOAT8  := 0.0;
  v_vel_cnt8           INT     := 0;
  v_vel_sum8           FLOAT8  := 0.0;
BEGIN
  v_week_monday    := p_snapshot_date;
  v_current_monday := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
  v_week_start_bjt := (v_week_monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';
  v_week_next_bjt  := v_week_start_bjt + INTERVAL '7 days';

  SELECT * INTO r
  FROM public.student_baseline
  WHERE student_name = p_student_name;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT * INTO ctx
  FROM public.get_rule_v2_week_target_context(p_student_name, p_snapshot_date);

  v_target_week := COALESCE(ctx.final_target_week, 300.0);

  SELECT COUNT(*)
  INTO v_hist_count
  FROM public.student_score_history sh
  WHERE sh.student_name    = p_student_name
    AND sh.composite_score > 0
    AND sh.snapshot_date   < v_week_monday;

  WITH recent_active AS (
    SELECT
      week_start,
      weekly_mins,
      ROW_NUMBER() OVER (ORDER BY week_start DESC) AS rn
    FROM (
      SELECT
        DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE AS week_start,
        SUM(ps.cleaned_duration)::FLOAT8 AS weekly_mins
      FROM public.practice_sessions ps
      WHERE ps.student_name     = p_student_name
        AND ps.cleaned_duration > 0
        AND ps.session_start    < v_week_start_bjt
        AND ps.session_start   >= v_week_start_bjt - INTERVAL '20 weeks'
        AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
      GROUP BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE
      HAVING SUM(ps.cleaned_duration) > 0
    ) w
  )
  SELECT
    MAX(CASE WHEN rn = 1 THEN weekly_mins END),
    MAX(CASE WHEN rn = 2 THEN weekly_mins END),
    AVG(CASE WHEN rn <= 2 THEN weekly_mins END),
    AVG(CASE WHEN rn > 2 AND rn <= 4 THEN weekly_mins END)
  INTO
    v_w1_mins,
    v_w2_mins,
    v_recent_avg,
    v_older_avg
  FROM recent_active
  WHERE rn <= 4;

  v_comp1 := LEAST(1.10, COALESCE(v_w1_mins, 0.0) / NULLIF(v_target_week, 0.0));
  v_comp2 := LEAST(1.10, COALESCE(v_w2_mins, 0.0) / NULLIF(v_target_week, 0.0));
  v_b_delta := COALESCE(v_comp1, 0.0) - COALESCE(v_comp2, 0.0);

  IF COALESCE(v_w1_mins, 0.0) > 0 THEN
    IF COALESCE(v_w2_mins, 0.0) > 0 THEN
      IF v_comp1 >= 0.92 AND v_comp2 >= 0.92 THEN
        v_b_change := GREATEST(0.68, LEAST(0.82, 0.72 + v_b_delta * 0.60));
      ELSIF ABS(v_b_delta) <= 0.06 THEN
        v_b_change := 0.5;
      ELSE
        v_b_change := 1.0 / (1.0 + EXP(-8.0 * v_b_delta));
      END IF;
    ELSE
      v_b_change := CASE
        WHEN v_comp1 >= 0.92 THEN 0.70
        WHEN v_comp1 >= 0.75 THEN 0.60
        WHEN v_comp1 >= 0.50 THEN 0.50
        ELSE 0.35
      END;
    END IF;

    v_b_level := CASE
      WHEN v_comp1 >= 1.00 THEN 0.85
      WHEN v_comp1 >= 0.92 THEN 0.75
      WHEN v_comp1 >= 0.75 THEN 0.62
      WHEN v_comp1 >= 0.50 THEN 0.48
      ELSE 0.32
    END;

    v_b_score := 0.70 * v_b_change + 0.30 * v_b_level;
  END IF;

  v_recent_completion := LEAST(1.10, COALESCE(v_recent_avg, 0.0) / NULLIF(v_target_week, 0.0));
  v_older_completion  := LEAST(1.10, COALESCE(v_older_avg, 0.0) / NULLIF(v_target_week, 0.0));
  v_t_delta := COALESCE(v_recent_completion, 0.0) - COALESCE(v_older_completion, 0.0);

  IF v_recent_avg IS NOT NULL THEN
    IF v_older_avg IS NOT NULL THEN
      IF v_recent_completion BETWEEN 0.92 AND 1.08
         AND v_older_completion BETWEEN 0.92 AND 1.08 THEN
        v_t_change := GREATEST(0.68, LEAST(0.82, 0.72 + v_t_delta * 0.50));
      ELSIF ABS(v_t_delta) <= 0.06 THEN
        v_t_change := 0.5;
      ELSE
        v_t_change := 1.0 / (1.0 + EXP(-8.0 * v_t_delta));
      END IF;
    ELSE
      v_t_change := 0.5;
    END IF;

    v_t_level := CASE
      WHEN v_recent_completion >= 1.00 THEN 0.82
      WHEN v_recent_completion >= 0.92 THEN 0.74
      WHEN v_recent_completion >= 0.75 THEN 0.62
      WHEN v_recent_completion >= 0.50 THEN 0.48
      ELSE 0.34
    END;

    v_t_score := 0.65 * v_t_change + 0.35 * v_t_level;
  END IF;

  WITH m_weeks AS (
    SELECT
      week_start,
      LEAST(1.10, weekly_mins / NULLIF(v_target_week, 0.0)) AS completion,
      ROW_NUMBER() OVER (ORDER BY week_start DESC) AS rn
    FROM (
      SELECT
        DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE AS week_start,
        SUM(ps.cleaned_duration)::FLOAT8 AS weekly_mins
      FROM public.practice_sessions ps
      WHERE ps.student_name     = p_student_name
        AND ps.cleaned_duration > 0
        AND ps.session_start    < v_week_start_bjt
        AND ps.session_start   >= v_week_start_bjt - INTERVAL '12 weeks'
        AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
      GROUP BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE
      HAVING SUM(ps.cleaned_duration) > 0
    ) q
  ),
  m_recent AS (
    SELECT
      rn,
      completion,
      CASE rn
        WHEN 1 THEN 0.35
        WHEN 2 THEN 0.30
        WHEN 3 THEN 0.20
        WHEN 4 THEN 0.15
        ELSE 0.0
      END AS weight
    FROM m_weeks
    WHERE rn <= 4
  )
  SELECT
    COALESCE(SUM(weight * LEAST(1.0, completion)), 0.0),
    COALESCE(STDDEV_POP(completion), 0.0),
    COALESCE(COUNT(*) FILTER (WHERE completion >= 0.92), 0)
  INTO
    v_weighted_completion,
    v_completion_sd,
    v_weeks_met
  FROM m_recent;

  IF v_hist_count < 2 THEN
    v_m_score := 0.5;
  ELSE
    v_m_score := GREATEST(0.0, LEAST(1.0,
      0.78 * v_weighted_completion
      + 0.22 * GREATEST(0.0, LEAST(1.0, 1.0 - COALESCE(v_completion_sd, 0.0) / 0.35))
    ));
  END IF;

  WITH self_long AS (
    SELECT
      DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE AS week_start,
      SUM(ps.cleaned_duration)::FLOAT8 AS weekly_mins
    FROM public.practice_sessions ps
    WHERE ps.student_name     = p_student_name
      AND ps.cleaned_duration > 0
      AND ps.session_start    < v_week_start_bjt
      AND ps.session_start   >= v_week_start_bjt - INTERVAL '20 weeks'
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    GROUP BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE
    HAVING SUM(ps.cleaned_duration) > 0
  ),
  self_long_recent AS (
    SELECT
      weekly_mins,
      ROW_NUMBER() OVER (ORDER BY week_start DESC) AS rn
    FROM self_long
  )
  SELECT
    percentile_cont(0.50) WITHIN GROUP (ORDER BY weekly_mins),
    LEAST(1.0, COUNT(*)::FLOAT8 / 8.0)
  INTO
    v_long_median,
    v_long_active_ratio
  FROM self_long_recent
  WHERE rn <= 12;

  v_long_median := COALESCE(v_long_median, v_target_week * 0.70);

  WITH peer_long AS (
    SELECT
      SUM(ps.cleaned_duration)::FLOAT8 AS weekly_mins
    FROM public.practice_sessions ps
    JOIN public.student_baseline sb
      ON sb.student_name = ps.student_name
    WHERE ps.cleaned_duration > 0
      AND ps.session_start    < v_week_start_bjt
      AND ps.session_start   >= v_week_start_bjt - INTERVAL '20 weeks'
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
      AND (
        (r.student_major IS NOT NULL AND sb.student_major = r.student_major)
        OR r.student_major IS NULL
      )
    GROUP BY ps.student_name, DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE
    HAVING SUM(ps.cleaned_duration) > 0
  )
  SELECT
    COALESCE(AVG(CASE WHEN weekly_mins <= v_long_median THEN 1.0 ELSE 0.0 END), 0.5)
  INTO v_peer_level
  FROM peer_long;

  v_long_quality := GREATEST(
    0.0,
    LEAST(
      1.0,
      v_long_active_ratio
      * (1.0 - 0.50 * COALESCE(r.outlier_rate, 0.0))
      * (1.0 - 0.30 * COALESCE(r.short_session_rate, 0.0))
    )
  );

  v_a_score := GREATEST(0.0, LEAST(1.0, 0.75 * v_peer_level + 0.25 * v_long_quality));

  IF v_week_monday = v_current_monday THEN
    SELECT COALESCE(SUM(cleaned_duration), 0.0)
    INTO v_week_minutes
    FROM public.practice_sessions
    WHERE student_name  = p_student_name
      AND session_start >= v_week_start_bjt
      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

    v_elapsed_days := CASE EXTRACT(DOW FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INT
      WHEN 0 THEN 5
      WHEN 6 THEN 5
      ELSE EXTRACT(DOW FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INT
    END;
  ELSE
    SELECT COALESCE(SUM(cleaned_duration), 0.0)
    INTO v_week_minutes
    FROM public.practice_sessions
    WHERE student_name   = p_student_name
      AND session_start >= v_week_start_bjt
      AND session_start <  v_week_next_bjt
      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

    v_elapsed_days := 5;
  END IF;

  IF v_elapsed_days > 0 THEN
    v_week_completion := v_week_minutes
                      / NULLIF(v_target_week * (v_elapsed_days::FLOAT8 / 5.0), 0.0);
  ELSE
    v_week_completion := 0.0;
  END IF;

  v_w_score := CASE
    WHEN v_week_completion <= 0.0 THEN 0.0
    WHEN v_week_completion < 0.50 THEN 0.20 + 0.50 * (v_week_completion / 0.50)
    WHEN v_week_completion < 1.00 THEN 0.70 + 0.20 * ((v_week_completion - 0.50) / 0.50)
    WHEN v_week_completion < 1.10 THEN 0.90 + 0.05 * ((v_week_completion - 1.00) / 0.10)
    ELSE 0.95
  END;
  v_w_score := GREATEST(0.0, LEAST(0.95, v_w_score));

  IF v_hist_count < 4 THEN
    v_weight_b := 0.08; v_weight_t := 0.05; v_weight_m := 0.15; v_weight_a := 0.30; v_weight_w := 0.42;
  ELSIF v_hist_count < 12 THEN
    v_weight_b := 0.12; v_weight_t := 0.10; v_weight_m := 0.20; v_weight_a := 0.30; v_weight_w := 0.28;
  ELSE
    v_weight_b := 0.12; v_weight_t := 0.12; v_weight_m := 0.24; v_weight_a := 0.30; v_weight_w := 0.22;
  END IF;

  v_outlier_penalty := CASE
    WHEN COALESCE(r.outlier_rate, 0.0) <= 0.10
      THEN 1.0 - 0.4 * COALESCE(r.outlier_rate, 0.0)
    WHEN COALESCE(r.outlier_rate, 0.0) <= 0.20
      THEN 0.96 - 1.1 * (COALESCE(r.outlier_rate, 0.0) - 0.10)
    WHEN COALESCE(r.outlier_rate, 0.0) <= 0.30
      THEN 0.85 - 1.8 * (COALESCE(r.outlier_rate, 0.0) - 0.20)
    WHEN COALESCE(r.outlier_rate, 0.0) <= 0.60
      THEN 0.67 - 1.4 * (COALESCE(r.outlier_rate, 0.0) - 0.30)
    ELSE 0.25 * EXP(-3.0 * (COALESCE(r.outlier_rate, 0.0) - 0.60))
  END;

  composite_score := ROUND((
      GREATEST(0.0, LEAST(1.0,
        v_weight_b * v_b_score
      + v_weight_t * v_t_score
      + v_weight_m * v_m_score
      + v_weight_a * v_a_score
      + v_weight_w * v_w_score
      )) * v_outlier_penalty
    )::NUMERIC * 100.0, 1);

  raw_score      := composite_score / 100.0;
  baseline_score := v_b_score;
  trend_score    := v_t_score;
  momentum_score := v_m_score;
  accum_score    := v_a_score;
  w_score        := v_w_score;

  v_score_conf := GREATEST(0.0, LEAST(1.0,
      LEAST(1.0, v_hist_count::FLOAT8 / 12.0) * 0.55
    + (1.0 - COALESCE(r.outlier_rate, 0.0)) * 0.20
    + (1.0 - COALESCE(r.short_session_rate, 0.0)) * 0.10
    + CASE
        WHEN v_week_monday = v_current_monday THEN 0.15
        ELSE 0.10
      END
  ));
  score_confidence := v_score_conf;

  FOR vel_rec IN
    SELECT sh.composite_score::FLOAT8 AS sc
    FROM public.student_score_history sh
    WHERE sh.student_name    = p_student_name
      AND sh.composite_score > 0
      AND sh.snapshot_date   < v_week_monday
    ORDER BY sh.snapshot_date DESC
    LIMIT 8
  LOOP
    v_vel_cnt8 := v_vel_cnt8 + 1;
    v_vel_sum8 := v_vel_sum8 + vel_rec.sc;
    IF v_vel_cnt8 <= 4 THEN
      v_vel_cnt4 := v_vel_cnt4 + 1;
      v_vel_sum4 := v_vel_sum4 + vel_rec.sc;
    END IF;
  END LOOP;

  IF v_vel_cnt4 > 0 AND v_vel_cnt8 > 4 THEN
    v_growth_velocity :=
      (v_vel_sum4 / v_vel_cnt4
      - (v_vel_sum8 - v_vel_sum4) / NULLIF(v_vel_cnt8 - v_vel_cnt4, 0))
      / 100.0;
  END IF;

  growth_velocity := COALESCE(v_growth_velocity, 0.0);
  weeks_improving := COALESCE(v_weeks_met, 0);

  RETURN NEXT;
END;
$$;


-- ---------------------------------------------------------------------------
-- C) 实时函数：当前周实时写入 score_history + baseline
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_student_score(p_student_name TEXT)
RETURNS TABLE(composite_score NUMERIC, raw_score FLOAT8)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  r                RECORD;
  calc             RECORD;
  v_week_monday    DATE;
  v_week_start_bjt TIMESTAMPTZ;
  v_has_session    BOOLEAN;
  v_last_bjt       TIMESTAMPTZ;
  v_days_inactive  INTEGER := 0;
BEGIN
  v_week_monday    := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
  v_week_start_bjt := (v_week_monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';

  SELECT * INTO r
  FROM public.student_baseline
  WHERE student_name = p_student_name;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT MAX(session_start) INTO v_last_bjt
  FROM public.practice_sessions
  WHERE student_name = p_student_name
    AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

  v_days_inactive := EXTRACT(DAYS FROM (NOW() - COALESCE(v_last_bjt, NOW() - INTERVAL '999 days')))::INT;

  IF v_days_inactive > 30 THEN
    INSERT INTO public.student_score_history (
      student_name, snapshot_date,
      composite_score, raw_score,
      baseline_score, trend_score, momentum_score, accum_score,
      outlier_rate, short_session_rate, mean_duration, record_count
    ) VALUES (
      p_student_name, v_week_monday,
      COALESCE(r.composite_score, 0), COALESCE(r.raw_score, 0.0),
      COALESCE(r.baseline_score, 0.5), COALESCE(r.trend_score, 0.5),
      COALESCE(r.momentum_score, 0.5), COALESCE(r.accum_score, 0.5),
      r.outlier_rate, r.short_session_rate, r.mean_duration, r.record_count
    )
    ON CONFLICT (student_name, snapshot_date) DO UPDATE SET
      composite_score    = EXCLUDED.composite_score,
      raw_score          = EXCLUDED.raw_score,
      baseline_score     = EXCLUDED.baseline_score,
      trend_score        = EXCLUDED.trend_score,
      momentum_score     = EXCLUDED.momentum_score,
      accum_score        = EXCLUDED.accum_score,
      outlier_rate       = EXCLUDED.outlier_rate,
      short_session_rate = EXCLUDED.short_session_rate,
      mean_duration      = EXCLUDED.mean_duration,
      record_count       = EXCLUDED.record_count;

    RETURN QUERY
    SELECT COALESCE(r.composite_score, 0::NUMERIC), COALESCE(r.raw_score, 0.0)::FLOAT8;
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.practice_sessions
    WHERE student_name     = p_student_name
      AND cleaned_duration > 0
      AND session_start   >= v_week_start_bjt
      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  ) INTO v_has_session;

  IF NOT v_has_session THEN
    INSERT INTO public.student_score_history (
      student_name, snapshot_date,
      composite_score, raw_score,
      baseline_score, trend_score, momentum_score, accum_score,
      outlier_rate, short_session_rate, mean_duration, record_count
    ) VALUES (
      p_student_name, v_week_monday,
      0, 0.0,
      NULL, NULL, NULL, NULL,
      r.outlier_rate, r.short_session_rate, r.mean_duration, r.record_count
    )
    ON CONFLICT (student_name, snapshot_date) DO UPDATE SET
      composite_score    = 0,
      raw_score          = 0.0,
      baseline_score     = NULL,
      trend_score        = NULL,
      momentum_score     = NULL,
      accum_score        = NULL,
      outlier_rate       = EXCLUDED.outlier_rate,
      short_session_rate = EXCLUDED.short_session_rate,
      mean_duration      = EXCLUDED.mean_duration,
      record_count       = EXCLUDED.record_count;

    RETURN QUERY SELECT 0::NUMERIC, 0.0::FLOAT8;
    RETURN;
  END IF;

  SELECT * INTO calc
  FROM public.compute_student_score_rule_v2_core(p_student_name, v_week_monday);

  PERFORM set_config('app.computing_score', 'true', true);

  INSERT INTO public.student_score_history (
    student_name, snapshot_date,
    composite_score, raw_score,
    baseline_score, trend_score, momentum_score, accum_score,
    outlier_rate, short_session_rate, mean_duration, record_count
  ) VALUES (
    p_student_name, v_week_monday,
    calc.composite_score, calc.raw_score,
    calc.baseline_score, calc.trend_score, calc.momentum_score, calc.accum_score,
    r.outlier_rate, r.short_session_rate, r.mean_duration, r.record_count
  )
  ON CONFLICT (student_name, snapshot_date) DO UPDATE SET
    composite_score    = EXCLUDED.composite_score,
    raw_score          = EXCLUDED.raw_score,
    baseline_score     = EXCLUDED.baseline_score,
    trend_score        = EXCLUDED.trend_score,
    momentum_score     = EXCLUDED.momentum_score,
    accum_score        = EXCLUDED.accum_score,
    outlier_rate       = EXCLUDED.outlier_rate,
    short_session_rate = EXCLUDED.short_session_rate,
    mean_duration      = EXCLUDED.mean_duration,
    record_count       = EXCLUDED.record_count;

  UPDATE public.student_baseline
  SET
    composite_score  = calc.composite_score,
    raw_score        = calc.raw_score,
    baseline_score   = calc.baseline_score,
    trend_score      = calc.trend_score,
    momentum_score   = calc.momentum_score,
    accum_score      = calc.accum_score,
    w_score          = calc.w_score,
    score_confidence = calc.score_confidence,
    growth_velocity  = calc.growth_velocity,
    weeks_improving  = calc.weeks_improving,
    last_updated     = NOW()
  WHERE student_name = p_student_name;

  PERFORM set_config('app.computing_score', 'false', true);

  RETURN QUERY
  SELECT calc.composite_score, calc.raw_score;
END;
$$;


-- ---------------------------------------------------------------------------
-- D) 历史回填函数：只写 student_score_history，不改历史发币/历史榜单快照
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_student_score_as_of(
  p_student_name  TEXT,
  p_snapshot_date DATE
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  r                RECORD;
  calc             RECORD;
  v_week_start_bjt TIMESTAMPTZ;
  v_week_next_bjt  TIMESTAMPTZ;
  v_has_session    BOOLEAN;
  v_last_bjt       TIMESTAMPTZ;
  v_days_inactive  INTEGER := 0;
BEGIN
  v_week_start_bjt := (p_snapshot_date::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';
  v_week_next_bjt  := v_week_start_bjt + INTERVAL '7 days';

  SELECT * INTO r
  FROM public.student_baseline
  WHERE student_name = p_student_name;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT MAX(session_start) INTO v_last_bjt
  FROM public.practice_sessions
  WHERE student_name = p_student_name
    AND session_start < v_week_start_bjt
    AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

  v_days_inactive := EXTRACT(DAYS FROM
    (v_week_start_bjt - COALESCE(v_last_bjt, v_week_start_bjt - INTERVAL '999 days')))::INT;

  IF v_days_inactive > 30 THEN
    INSERT INTO public.student_score_history (
      student_name, snapshot_date,
      composite_score, raw_score,
      baseline_score, trend_score, momentum_score, accum_score,
      outlier_rate, short_session_rate, mean_duration, record_count
    ) VALUES (
      p_student_name, p_snapshot_date,
      COALESCE(r.composite_score, 0), COALESCE(r.raw_score, 0.0),
      COALESCE(r.baseline_score, 0.5), COALESCE(r.trend_score, 0.5),
      COALESCE(r.momentum_score, 0.5), COALESCE(r.accum_score, 0.5),
      r.outlier_rate, r.short_session_rate, r.mean_duration, r.record_count
    )
    ON CONFLICT (student_name, snapshot_date) DO UPDATE SET
      composite_score    = EXCLUDED.composite_score,
      raw_score          = EXCLUDED.raw_score,
      baseline_score     = EXCLUDED.baseline_score,
      trend_score        = EXCLUDED.trend_score,
      momentum_score     = EXCLUDED.momentum_score,
      accum_score        = EXCLUDED.accum_score,
      outlier_rate       = EXCLUDED.outlier_rate,
      short_session_rate = EXCLUDED.short_session_rate,
      mean_duration      = EXCLUDED.mean_duration,
      record_count       = EXCLUDED.record_count;
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.practice_sessions
    WHERE student_name     = p_student_name
      AND cleaned_duration > 0
      AND session_start   >= v_week_start_bjt
      AND session_start   <  v_week_next_bjt
      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  ) INTO v_has_session;

  IF NOT v_has_session THEN
    INSERT INTO public.student_score_history (
      student_name, snapshot_date,
      composite_score, raw_score,
      baseline_score, trend_score, momentum_score, accum_score,
      outlier_rate, short_session_rate, mean_duration, record_count
    ) VALUES (
      p_student_name, p_snapshot_date,
      0, 0.0,
      NULL, NULL, NULL, NULL,
      r.outlier_rate, r.short_session_rate, r.mean_duration, r.record_count
    )
    ON CONFLICT (student_name, snapshot_date) DO UPDATE SET
      composite_score    = 0,
      raw_score          = 0.0,
      baseline_score     = NULL,
      trend_score        = NULL,
      momentum_score     = NULL,
      accum_score        = NULL,
      outlier_rate       = EXCLUDED.outlier_rate,
      short_session_rate = EXCLUDED.short_session_rate,
      mean_duration      = EXCLUDED.mean_duration,
      record_count       = EXCLUDED.record_count;
    RETURN;
  END IF;

  SELECT * INTO calc
  FROM public.compute_student_score_rule_v2_core(p_student_name, p_snapshot_date);

  INSERT INTO public.student_score_history (
    student_name, snapshot_date,
    composite_score, raw_score,
    baseline_score, trend_score, momentum_score, accum_score,
    outlier_rate, short_session_rate, mean_duration, record_count
  ) VALUES (
    p_student_name, p_snapshot_date,
    calc.composite_score, calc.raw_score,
    calc.baseline_score, calc.trend_score, calc.momentum_score, calc.accum_score,
    r.outlier_rate, r.short_session_rate, r.mean_duration, r.record_count
  )
  ON CONFLICT (student_name, snapshot_date) DO UPDATE SET
    composite_score    = EXCLUDED.composite_score,
    raw_score          = EXCLUDED.raw_score,
    baseline_score     = EXCLUDED.baseline_score,
    trend_score        = EXCLUDED.trend_score,
    momentum_score     = EXCLUDED.momentum_score,
    accum_score        = EXCLUDED.accum_score,
    outlier_rate       = EXCLUDED.outlier_rate,
    short_session_rate = EXCLUDED.short_session_rate,
    mean_duration      = EXCLUDED.mean_duration,
    record_count       = EXCLUDED.record_count;
END;
$$;


-- ---------------------------------------------------------------------------
-- E) W 分独立刷新：与新综合榜 W 维度保持一致
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_and_store_w_score(p_student_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_monday         DATE;
  v_week_start_bjt TIMESTAMPTZ;
  ctx              RECORD;
  v_week_minutes   FLOAT8 := 0.0;
  v_elapsed_days   INTEGER := 0;
  v_completion     FLOAT8 := 0.0;
  v_w_score        FLOAT8 := 0.0;
BEGIN
  v_monday         := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
  v_week_start_bjt := (v_monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';

  SELECT * INTO ctx
  FROM public.get_rule_v2_week_target_context(p_student_name, v_monday);

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT COALESCE(SUM(cleaned_duration), 0.0)
  INTO v_week_minutes
  FROM public.practice_sessions
  WHERE student_name  = p_student_name
    AND session_start >= v_week_start_bjt
    AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

  v_elapsed_days := CASE EXTRACT(DOW FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INT
    WHEN 0 THEN 5
    WHEN 6 THEN 5
    ELSE EXTRACT(DOW FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INT
  END;

  IF v_elapsed_days > 0 THEN
    v_completion := v_week_minutes
                 / NULLIF(ctx.final_target_week * (v_elapsed_days::FLOAT8 / 5.0), 0.0);
  END IF;

  v_w_score := CASE
    WHEN v_completion <= 0.0 THEN 0.0
    WHEN v_completion < 0.50 THEN 0.20 + 0.50 * (v_completion / 0.50)
    WHEN v_completion < 1.00 THEN 0.70 + 0.20 * ((v_completion - 0.50) / 0.50)
    WHEN v_completion < 1.10 THEN 0.90 + 0.05 * ((v_completion - 1.00) / 0.10)
    ELSE 0.95
  END;
  v_w_score := GREATEST(0.0, LEAST(0.95, v_w_score));

  PERFORM set_config('app.skip_score_trigger', 'on', true);
  UPDATE public.student_baseline
  SET
    w_score = v_w_score,
    w_score_updated_at = NOW()
  WHERE student_name = p_student_name;
  PERFORM set_config('app.skip_score_trigger', 'off', true);
END;
$$;


-- ---------------------------------------------------------------------------
-- F) 全历史重算：允许覆盖 student_score_history / student_baseline 的派生分
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.backfill_score_history()
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_start_date     DATE;
  v_end_date       DATE;
  v_current_date   DATE;
  v_next_date      DATE;
  v_week_start_bjt TIMESTAMPTZ;
  v_student        RECORD;
  v_week_count     INTEGER := 0;
  v_active_count   INTEGER := 0;
  v_zero_count     INTEGER := 0;
BEGIN
  PERFORM set_config('app.skip_score_trigger', 'on', TRUE);

  SELECT DATE_TRUNC('week', MIN(session_start))::DATE
  INTO v_start_date
  FROM public.practice_sessions
  WHERE cleaned_duration > 0;

  v_end_date     := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
  v_current_date := v_start_date;

  IF v_start_date IS NULL THEN
    RAISE NOTICE '无 practice_sessions 数据，跳过 backfill';
    PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
    RETURN;
  END IF;

  -- 允许覆盖整个评分历史表，但不碰任何音符币表与 weekly_leaderboard_history
  DELETE FROM public.student_score_history;

  RAISE NOTICE 'FIX-86 回溯范围：% → %', v_start_date, v_end_date;

  WHILE v_current_date <= v_end_date LOOP
    v_week_count := v_week_count + 1;
    v_next_date  := v_current_date + INTERVAL '7 days';
    v_week_start_bjt := (v_current_date::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';

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
        RAISE WARNING '[fix86 backfill baseline] % @ % 失败：%', v_student.student_name, v_current_date, SQLERRM;
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
        PERFORM public.compute_student_score_as_of(v_student.student_name, v_current_date);
        IF EXISTS (
          SELECT 1
          FROM public.student_score_history
          WHERE student_name = v_student.student_name
            AND snapshot_date = v_current_date
            AND composite_score > 0
        ) THEN
          v_active_count := v_active_count + 1;
        ELSE
          v_zero_count := v_zero_count + 1;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING '[fix86 backfill score] % @ % 失败：%', v_student.student_name, v_current_date, SQLERRM;
      END;
    END LOOP;

    v_current_date := v_next_date;
  END LOOP;

  -- baseline 同步到“最新一周的新规则派生分”
  UPDATE public.student_baseline b
  SET
    raw_score        = latest.raw_score,
    composite_score  = latest.composite_score,
    baseline_score   = latest.baseline_score,
    trend_score      = latest.trend_score,
    momentum_score   = latest.momentum_score,
    accum_score      = latest.accum_score
  FROM (
    SELECT DISTINCT ON (student_name)
      student_name,
      raw_score,
      composite_score,
      baseline_score,
      trend_score,
      momentum_score,
      accum_score
    FROM public.student_score_history
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
      RAISE WARNING '[fix86 backfill rebase] % 失败：%', v_student.student_name, SQLERRM;
    END;
  END LOOP;

  -- 本周已练琴学生：完整刷新当前 baseline 五维 / confidence / growth / W
  FOR v_student IN
    SELECT DISTINCT student_name
    FROM public.practice_sessions
    WHERE cleaned_duration > 0
      AND session_start >= (((DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE)::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    ORDER BY student_name
  LOOP
    BEGIN
      PERFORM public.compute_student_score(v_student.student_name);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[fix86 backfill current score] % 失败：%', v_student.student_name, SQLERRM;
    END;
  END LOOP;

  -- 全员刷新 W
  FOR v_student IN
    SELECT student_name
    FROM public.student_baseline
    ORDER BY student_name
  LOOP
    BEGIN
      PERFORM public.compute_and_store_w_score(v_student.student_name);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[fix86 backfill w_score] % 失败：%', v_student.student_name, SQLERRM;
    END;
  END LOOP;

  PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
  RAISE NOTICE 'FIX-86 回溯完成：共 % 周，活跃快照 % 条，零分/冻结快照 % 条',
    v_week_count, v_active_count, v_zero_count;
END;
$$;


-- ---------------------------------------------------------------------------
-- G) 一键执行入口：仅覆盖评分派生链，不碰发币与历史榜单事实
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_fix86_score_rollout()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  PERFORM public.backfill_score_history();

  RETURN jsonb_build_object(
    'ok', true,
    'updated_tables', jsonb_build_array('student_score_history', 'student_baseline'),
    'untouched_tables', jsonb_build_array(
      'weekly_leaderboard_history',
      'student_coins',
      'coin_transactions',
      'weekly_coin_reward_log',
      'weekly_coin_reward_detail'
    ),
    'note', '综合榜规则已切到 FIX-86；历史发币与历史周榜快照未改写'
  );
END;
$$;


-- ---------------------------------------------------------------------------
-- H) 验证提示
-- ---------------------------------------------------------------------------
-- 1) 只重算评分派生链（推荐）
-- SELECT public.apply_fix86_score_rollout();
--
-- 2) 重算后抽查
-- SELECT student_name, composite_score, baseline_score, trend_score, momentum_score, accum_score, w_score
-- FROM public.student_baseline
-- ORDER BY composite_score DESC NULLS LAST
-- LIMIT 30;
--
-- 3) 历史事实确认（应保持完全不动）
-- SELECT COUNT(*) FROM public.weekly_leaderboard_history;
-- SELECT COUNT(*) FROM public.coin_transactions;
