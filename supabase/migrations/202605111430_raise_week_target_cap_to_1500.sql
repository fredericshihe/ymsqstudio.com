-- ============================================================================
-- Raise FIX-86 week target cap from 660 to 1500
--
-- Scope:
-- - Only updates get_rule_v2_week_target_context()
-- - Does not touch historical coin settlement tables
-- - Does not recalculate historical snapshots by itself
-- ============================================================================

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
