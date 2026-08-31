BEGIN;

CREATE TABLE IF NOT EXISTS public.student_week_targets (
  student_name         TEXT NOT NULL,
  week_monday          DATE NOT NULL,
  target_minutes       NUMERIC(8, 2) NOT NULL CHECK (target_minutes BETWEEN 270 AND 1500),
  personal_target      NUMERIC(8, 2) NOT NULL,
  peer_floor           NUMERIC(8, 2) NOT NULL,
  personal_week_ref    NUMERIC(8, 2),
  peer_week_ref        NUMERIC(8, 2) NOT NULL,
  effective_daily_mean NUMERIC(8, 2) NOT NULL,
  prior_target         NUMERIC(8, 2),
  active_week_count    INTEGER NOT NULL DEFAULT 0 CHECK (active_week_count BETWEEN 0 AND 8),
  score_period_start   TIMESTAMPTZ,
  calculation_source   TEXT NOT NULL,
  computed_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (student_name, week_monday)
);

CREATE INDEX IF NOT EXISTS idx_student_week_targets_week
  ON public.student_week_targets (week_monday, student_name);

ALTER TABLE public.student_week_targets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.student_week_targets FROM anon, authenticated;

COMMENT ON TABLE public.student_week_targets IS
'Immutable weekly practice targets. Each Monday target uses records strictly before that week and remains fixed through Sunday.';

CREATE OR REPLACE FUNCTION public.get_student_school_stage(p_grade TEXT)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
PARALLEL SAFE
AS $function$
  SELECT CASE
    WHEN COALESCE(NULLIF(SUBSTRING(BTRIM(COALESCE(p_grade, '')) FROM '[0-9]+'), ''), '99')::INTEGER <= 6
      THEN 'primary'
    WHEN COALESCE(NULLIF(SUBSTRING(BTRIM(COALESCE(p_grade, '')) FROM '[0-9]+'), ''), '99')::INTEGER <= 9
      THEN 'middle'
    ELSE 'high'
  END;
$function$;

REVOKE ALL ON FUNCTION public.get_student_school_stage(TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.calculate_student_week_target(
  p_student_name TEXT,
  p_week_monday  DATE
)
RETURNS TABLE (
  final_target_week     FLOAT8,
  personal_target_week  FLOAT8,
  major_floor_week      FLOAT8,
  personal_week_ref     FLOAT8,
  peer_week_ref         FLOAT8,
  effective_mean        FLOAT8,
  prior_target_week     FLOAT8,
  recent_active_weeks   INTEGER,
  target_source         TEXT,
  score_period_start    TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_major                 TEXT;
  v_grade                 TEXT;
  v_stage                 TEXT;
  v_week_start_bjt        TIMESTAMPTZ;
  v_week_end_bjt          TIMESTAMPTZ;
  v_semester_cutoff       TIMESTAMPTZ;
  v_period_start          TIMESTAMPTZ;
  v_semester_snapshot     JSONB;
  v_semester_target       FLOAT8;
  v_previous_week_target  FLOAT8;
  v_anchor_target         FLOAT8;
  v_last_session          TIMESTAMPTZ;
  v_is_returning          BOOLEAN := FALSE;
  v_personal_p50          FLOAT8;
  v_personal_p70          FLOAT8;
  v_personal_weighted_avg FLOAT8;
  v_personal_ref          FLOAT8;
  v_peer_practice_ref     FLOAT8;
  v_peer_snapshot_ref     FLOAT8;
  v_peer_ref              FLOAT8;
  v_reliability           FLOAT8 := 0.0;
  v_anchor_weight         FLOAT8 := 0.0;
  v_candidate             FLOAT8;
  v_personal_target       FLOAT8;
  v_major_floor           FLOAT8;
  v_final_target          FLOAT8;
  v_lower_limit           FLOAT8;
  v_upper_limit           FLOAT8;
  v_active_week_count     INTEGER := 0;
  v_source                TEXT;
BEGIN
  SELECT profile.major, profile.grade
  INTO v_major, v_grade
  FROM (
    SELECT DISTINCT ON (sd.name)
      sd.name,
      NULLIF(BTRIM(sd.major), '') AS major,
      NULLIF(BTRIM(sd.grade), '') AS grade
    FROM public.student_database sd
    WHERE sd.name = p_student_name
    ORDER BY
      sd.name,
      COALESCE(sd.archived, FALSE) ASC,
      sd.updated_at DESC NULLS LAST,
      sd.id DESC
  ) profile;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_stage := public.get_student_school_stage(v_grade);
  v_week_start_bjt := (p_week_monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';
  v_week_end_bjt := v_week_start_bjt + INTERVAL '7 days';
  v_semester_cutoff := CASE
    WHEN p_week_monday <= DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
      THEN LEAST(NOW(), v_week_end_bjt)
    ELSE v_week_start_bjt
  END;

  v_period_start := COALESCE(
    public.get_student_score_period_start(p_student_name, p_week_monday),
    v_week_start_bjt - INTERVAL '20 weeks'
  );

  SELECT ss.week_target_snapshot
  INTO v_semester_snapshot
  FROM public.score_semesters ss
  WHERE ss.started_at < v_semester_cutoff
  ORDER BY ss.started_at DESC
  LIMIT 1;

  v_semester_target := NULLIF(v_semester_snapshot ->> p_student_name, '')::FLOAT8;

  SELECT swt.target_minutes::FLOAT8
  INTO v_previous_week_target
  FROM public.student_week_targets swt
  WHERE swt.student_name = p_student_name
    AND swt.week_monday < p_week_monday
  ORDER BY swt.week_monday DESC
  LIMIT 1;

  v_anchor_target := COALESCE(v_previous_week_target, v_semester_target);

  SELECT MAX(ps.session_start)
  INTO v_last_session
  FROM public.practice_sessions ps
  WHERE ps.student_name = p_student_name
    AND ps.cleaned_duration > 0
    AND ps.session_start < v_week_start_bjt
    AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

  v_is_returning := v_last_session IS NULL
    OR v_last_session < v_week_start_bjt - INTERVAL '28 days';

  WITH personal_weekly AS (
    SELECT
      DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE AS week_start,
      SUM(ps.cleaned_duration)::FLOAT8 AS weekly_minutes
    FROM public.practice_sessions ps
    WHERE ps.student_name = p_student_name
      AND ps.cleaned_duration > 0
      AND ps.session_start >= GREATEST(v_period_start, v_week_start_bjt - INTERVAL '20 weeks')
      AND ps.session_start < v_week_start_bjt
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    GROUP BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE
    HAVING SUM(ps.cleaned_duration) > 0
  ),
  recent_personal AS (
    SELECT
      pw.weekly_minutes,
      ROW_NUMBER() OVER (ORDER BY pw.week_start DESC) AS recency_rank
    FROM personal_weekly pw
  )
  SELECT
    percentile_cont(0.50) WITHIN GROUP (ORDER BY rp.weekly_minutes),
    percentile_cont(0.70) WITHIN GROUP (ORDER BY rp.weekly_minutes),
    SUM(rp.weekly_minutes * POWER(0.82::FLOAT8, rp.recency_rank - 1))
      / NULLIF(SUM(POWER(0.82::FLOAT8, rp.recency_rank - 1)), 0),
    COUNT(*)::INTEGER
  INTO
    v_personal_p50,
    v_personal_p70,
    v_personal_weighted_avg,
    v_active_week_count
  FROM recent_personal rp
  WHERE rp.recency_rank <= 8;

  IF v_active_week_count > 0 THEN
    v_personal_ref := 0.45 * v_personal_p50
                    + 0.35 * v_personal_p70
                    + 0.20 * v_personal_weighted_avg;
  END IF;

  WITH profiles AS (
    SELECT DISTINCT ON (sd.name)
      sd.name,
      NULLIF(BTRIM(sd.major), '') AS major,
      public.get_student_school_stage(sd.grade) AS school_stage
    FROM public.student_database sd
    WHERE COALESCE(sd.archived, FALSE) IS FALSE
      AND NULLIF(BTRIM(sd.name), '') IS NOT NULL
    ORDER BY sd.name, sd.updated_at DESC NULLS LAST, sd.id DESC
  ),
  peer_weekly AS (
    SELECT
      ps.student_name,
      DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE AS week_start,
      SUM(ps.cleaned_duration)::FLOAT8 AS weekly_minutes
    FROM public.practice_sessions ps
    JOIN profiles profile ON profile.name = ps.student_name
    WHERE ps.cleaned_duration > 0
      AND ps.session_start >= v_week_start_bjt - INTERVAL '20 weeks'
      AND ps.session_start < v_week_start_bjt
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    GROUP BY
      ps.student_name,
      DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE
    HAVING SUM(ps.cleaned_duration) > 0
  ),
  ranked_peer_weeks AS (
    SELECT
      pw.student_name,
      pw.weekly_minutes,
      ROW_NUMBER() OVER (PARTITION BY pw.student_name ORDER BY pw.week_start DESC) AS recency_rank
    FROM peer_weekly pw
  ),
  peer_student_refs AS (
    SELECT
      rpw.student_name,
      0.45 * percentile_cont(0.50) WITHIN GROUP (ORDER BY rpw.weekly_minutes)
        + 0.35 * percentile_cont(0.70) WITHIN GROUP (ORDER BY rpw.weekly_minutes)
        + 0.20 * (
          SUM(rpw.weekly_minutes * POWER(0.82::FLOAT8, rpw.recency_rank - 1))
          / NULLIF(SUM(POWER(0.82::FLOAT8, rpw.recency_rank - 1)), 0)
        ) AS student_week_ref
    FROM ranked_peer_weeks rpw
    WHERE rpw.recency_rank <= 8
    GROUP BY rpw.student_name
  ),
  cohort_options AS (
    SELECT
      1 AS priority,
      COUNT(*)::INTEGER AS cohort_size,
      percentile_cont(0.50) WITHIN GROUP (ORDER BY psr.student_week_ref)::FLOAT8 AS cohort_ref
    FROM peer_student_refs psr
    JOIN profiles profile ON profile.name = psr.student_name
    WHERE profile.major IS NOT DISTINCT FROM v_major
      AND profile.school_stage = v_stage
    UNION ALL
    SELECT
      2,
      COUNT(*)::INTEGER,
      percentile_cont(0.50) WITHIN GROUP (ORDER BY psr.student_week_ref)::FLOAT8
    FROM peer_student_refs psr
    JOIN profiles profile ON profile.name = psr.student_name
    WHERE profile.major IS NOT DISTINCT FROM v_major
    UNION ALL
    SELECT
      3,
      COUNT(*)::INTEGER,
      percentile_cont(0.50) WITHIN GROUP (ORDER BY psr.student_week_ref)::FLOAT8
    FROM peer_student_refs psr
    JOIN profiles profile ON profile.name = psr.student_name
    WHERE profile.school_stage = v_stage
    UNION ALL
    SELECT
      4,
      COUNT(*)::INTEGER,
      percentile_cont(0.50) WITHIN GROUP (ORDER BY psr.student_week_ref)::FLOAT8
    FROM peer_student_refs psr
  )
  SELECT option.cohort_ref
  INTO v_peer_practice_ref
  FROM cohort_options option
  WHERE option.cohort_ref IS NOT NULL
    AND CASE option.priority
      WHEN 1 THEN option.cohort_size >= 5
      WHEN 2 THEN option.cohort_size >= 5
      WHEN 3 THEN option.cohort_size >= 10
      ELSE option.cohort_size >= 1
    END
  ORDER BY option.priority
  LIMIT 1;

  WITH profiles AS (
    SELECT DISTINCT ON (sd.name)
      sd.name,
      NULLIF(BTRIM(sd.major), '') AS major,
      public.get_student_school_stage(sd.grade) AS school_stage
    FROM public.student_database sd
    WHERE COALESCE(sd.archived, FALSE) IS FALSE
      AND NULLIF(BTRIM(sd.name), '') IS NOT NULL
    ORDER BY sd.name, sd.updated_at DESC NULLS LAST, sd.id DESC
  ),
  snapshot_refs AS (
    SELECT profile.name, profile.major, profile.school_stage, snapshot.value::FLOAT8 AS target
    FROM jsonb_each_text(COALESCE(v_semester_snapshot, '{}'::JSONB)) snapshot
    JOIN profiles profile ON profile.name = snapshot.key
    WHERE NULLIF(snapshot.value, '') IS NOT NULL
  ),
  cohort_options AS (
    SELECT
      1 AS priority,
      COUNT(*)::INTEGER AS cohort_size,
      percentile_cont(0.50) WITHIN GROUP (ORDER BY sr.target)::FLOAT8 AS cohort_ref
    FROM snapshot_refs sr
    WHERE sr.major IS NOT DISTINCT FROM v_major
      AND sr.school_stage = v_stage
    UNION ALL
    SELECT
      2,
      COUNT(*)::INTEGER,
      percentile_cont(0.50) WITHIN GROUP (ORDER BY sr.target)::FLOAT8
    FROM snapshot_refs sr
    WHERE sr.major IS NOT DISTINCT FROM v_major
    UNION ALL
    SELECT
      3,
      COUNT(*)::INTEGER,
      percentile_cont(0.50) WITHIN GROUP (ORDER BY sr.target)::FLOAT8
    FROM snapshot_refs sr
    WHERE sr.school_stage = v_stage
    UNION ALL
    SELECT
      4,
      COUNT(*)::INTEGER,
      percentile_cont(0.50) WITHIN GROUP (ORDER BY sr.target)::FLOAT8
    FROM snapshot_refs sr
  )
  SELECT option.cohort_ref
  INTO v_peer_snapshot_ref
  FROM cohort_options option
  WHERE option.cohort_ref IS NOT NULL
    AND CASE option.priority
      WHEN 1 THEN option.cohort_size >= 5
      WHEN 2 THEN option.cohort_size >= 5
      WHEN 3 THEN option.cohort_size >= 10
      ELSE option.cohort_size >= 1
    END
  ORDER BY option.priority
  LIMIT 1;

  v_peer_ref := LEAST(
    1500.0,
    GREATEST(270.0, COALESCE(v_peer_practice_ref, v_peer_snapshot_ref, 300.0))
  );

  IF v_active_week_count = 0 THEN
    IF v_anchor_target IS NULL THEN
      v_candidate := v_peer_ref;
      v_source := 'cold_start_peer';
    ELSIF v_is_returning THEN
      v_candidate := 0.35 * v_anchor_target + 0.65 * v_peer_ref;
      v_source := 'returning_peer_anchor';
    ELSE
      v_candidate := v_anchor_target;
      v_source := 'carry_forward';
    END IF;
  ELSE
    v_reliability := LEAST(1.0, v_active_week_count::FLOAT8 / 6.0);
    v_candidate := v_reliability * v_personal_ref
                 + (1.0 - v_reliability) * v_peer_ref;
    v_anchor_weight := GREATEST(0.0, 0.45 - 0.075 * v_active_week_count);
    IF v_anchor_target IS NOT NULL THEN
      v_candidate := v_anchor_weight * v_anchor_target
                   + (1.0 - v_anchor_weight) * v_candidate;
    END IF;
    v_source := 'recent_active_weeks';
  END IF;

  v_personal_target := LEAST(1500.0, GREATEST(270.0, v_candidate));
  v_major_floor := LEAST(1500.0, GREATEST(270.0, v_peer_ref * 0.80));
  v_candidate := GREATEST(v_personal_target, v_major_floor);

  IF v_anchor_target IS NOT NULL THEN
    v_upper_limit := LEAST(v_anchor_target * 1.12, v_anchor_target + 90.0);
    v_lower_limit := CASE
      WHEN v_is_returning AND v_active_week_count = 0
        THEN GREATEST(v_anchor_target * 0.88, v_anchor_target - 120.0)
      ELSE GREATEST(v_anchor_target * 0.94, v_anchor_target - 45.0)
    END;
    v_candidate := LEAST(v_upper_limit, GREATEST(v_lower_limit, v_candidate));
  END IF;

  v_final_target := ROUND(
    LEAST(1500.0, GREATEST(270.0, v_candidate)) / 5.0
  ) * 5.0;
  v_personal_target := ROUND(v_personal_target / 5.0) * 5.0;
  v_major_floor := ROUND(v_major_floor / 5.0) * 5.0;

  RETURN QUERY
  SELECT
    v_final_target,
    v_personal_target,
    v_major_floor,
    v_personal_ref,
    v_peer_ref,
    COALESCE(v_personal_ref, v_peer_ref, v_final_target) / 5.0,
    v_anchor_target,
    v_active_week_count,
    v_source,
    v_period_start;
END;
$function$;

REVOKE ALL ON FUNCTION public.calculate_student_week_target(TEXT, DATE) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.refresh_student_week_targets(
  p_week_monday DATE DEFAULT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE,
  p_force       BOOLEAN DEFAULT FALSE
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  student_row RECORD;
  target_row  RECORD;
  v_affected  INTEGER;
  v_count     INTEGER := 0;
BEGIN
  FOR student_row IN
    SELECT DISTINCT ON (sd.name) sd.name
    FROM public.student_database sd
    WHERE COALESCE(sd.archived, FALSE) IS FALSE
      AND NULLIF(BTRIM(sd.name), '') IS NOT NULL
    ORDER BY sd.name, sd.updated_at DESC NULLS LAST, sd.id DESC
  LOOP
    SELECT *
    INTO target_row
    FROM public.calculate_student_week_target(student_row.name, p_week_monday);

    IF NOT FOUND OR target_row.final_target_week IS NULL THEN
      CONTINUE;
    END IF;

    INSERT INTO public.student_week_targets (
      student_name,
      week_monday,
      target_minutes,
      personal_target,
      peer_floor,
      personal_week_ref,
      peer_week_ref,
      effective_daily_mean,
      prior_target,
      active_week_count,
      score_period_start,
      calculation_source,
      computed_at
    ) VALUES (
      student_row.name,
      p_week_monday,
      target_row.final_target_week,
      target_row.personal_target_week,
      target_row.major_floor_week,
      target_row.personal_week_ref,
      target_row.peer_week_ref,
      target_row.effective_mean,
      target_row.prior_target_week,
      target_row.recent_active_weeks,
      target_row.score_period_start,
      target_row.target_source,
      NOW()
    )
    ON CONFLICT (student_name, week_monday) DO UPDATE SET
      target_minutes = EXCLUDED.target_minutes,
      personal_target = EXCLUDED.personal_target,
      peer_floor = EXCLUDED.peer_floor,
      personal_week_ref = EXCLUDED.personal_week_ref,
      peer_week_ref = EXCLUDED.peer_week_ref,
      effective_daily_mean = EXCLUDED.effective_daily_mean,
      prior_target = EXCLUDED.prior_target,
      active_week_count = EXCLUDED.active_week_count,
      score_period_start = EXCLUDED.score_period_start,
      calculation_source = EXCLUDED.calculation_source,
      computed_at = EXCLUDED.computed_at
    WHERE p_force;

    GET DIAGNOSTICS v_affected = ROW_COUNT;
    v_count := v_count + v_affected;
  END LOOP;

  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.refresh_student_week_targets(DATE, BOOLEAN) FROM PUBLIC, anon, authenticated;

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
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    swt.target_minutes::FLOAT8,
    swt.personal_target::FLOAT8,
    swt.peer_floor::FLOAT8,
    swt.personal_week_ref::FLOAT8,
    swt.peer_week_ref::FLOAT8,
    swt.effective_daily_mean::FLOAT8
  FROM public.student_week_targets swt
  WHERE swt.student_name = p_student_name
    AND swt.week_monday = p_week_monday;

  IF FOUND THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    calculated.final_target_week,
    calculated.personal_target_week,
    calculated.major_floor_week,
    calculated.personal_week_ref,
    calculated.peer_week_ref,
    calculated.effective_mean
  FROM public.calculate_student_week_target(p_student_name, p_week_monday) calculated;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_rule_v2_week_target_context(TEXT, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_rule_v2_week_target_context(TEXT, DATE) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.refresh_all_w_scores()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  student_row RECORD;
  v_week_monday DATE;
  v_week_start_bjt TIMESTAMPTZ;
  v_has_current_week_session BOOLEAN;
BEGIN
  v_week_monday := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
  v_week_start_bjt := (v_week_monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';

  FOR student_row IN
    SELECT DISTINCT ON (sd.name) sb.student_name
    FROM public.student_database sd
    JOIN public.student_baseline sb ON sb.student_name = sd.name
    WHERE COALESCE(sd.archived, FALSE) IS FALSE
      AND NULLIF(BTRIM(sd.name), '') IS NOT NULL
    ORDER BY sd.name, sd.updated_at DESC NULLS LAST, sd.id DESC
  LOOP
    SELECT EXISTS (
      SELECT 1
      FROM public.practice_sessions ps
      WHERE ps.student_name = student_row.student_name
        AND ps.cleaned_duration > 0
        AND ps.session_start >= v_week_start_bjt
        AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    )
    INTO v_has_current_week_session;

    IF v_has_current_week_session THEN
      PERFORM public.compute_student_score(student_row.student_name);
    ELSE
      PERFORM public.compute_and_store_w_score(student_row.student_name);
    END IF;
  END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public.refresh_all_w_scores() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.delete_student_related_records()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name TEXT := NULLIF(BTRIM(OLD.name), '');
  v_canonical_name TEXT := public.canonical_student_name(OLD.name);
BEGIN
  IF v_name IS NULL THEN
    RETURN OLD;
  END IF;

  v_canonical_name := COALESCE(v_canonical_name, v_name);
  PERFORM set_config('app.skip_score_trigger', 'on', true);

  UPDATE public.rooms
  SET occupant_student_name = NULL,
      register_time = NULL
  WHERE occupant_student_name IN (v_name, v_canonical_name);

  DELETE FROM public.practice_alerts WHERE student_name IN (v_name, v_canonical_name);
  DELETE FROM public.practice_logs WHERE student_name IN (v_name, v_canonical_name);
  DELETE FROM public.practice_sessions WHERE student_name IN (v_name, v_canonical_name);
  DELETE FROM public.student_time_slots WHERE student_name IN (v_name, v_canonical_name);
  DELETE FROM public.student_schedules WHERE name IN (v_name, v_canonical_name);
  DELETE FROM public.student_time_slots_backup WHERE student_name IN (v_name, v_canonical_name);
  DELETE FROM public.student_score_history WHERE student_name IN (v_name, v_canonical_name);
  DELETE FROM public.student_baseline WHERE student_name IN (v_name, v_canonical_name);
  DELETE FROM public.student_coins WHERE student_name IN (v_name, v_canonical_name);
  DELETE FROM public.coin_transactions WHERE student_name IN (v_name, v_canonical_name);
  DELETE FROM public.weekly_coin_reward_detail WHERE student_name IN (v_name, v_canonical_name);
  DELETE FROM public.weekly_leaderboard_history WHERE student_name IN (v_name, v_canonical_name);
  DELETE FROM public.student_week_targets WHERE student_name IN (v_name, v_canonical_name);

  PERFORM set_config('app.skip_score_trigger', 'off', true);
  RETURN OLD;
END;
$function$;

SELECT public.refresh_student_week_targets(
  DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE,
  FALSE
);

DO $block$
BEGIN
  PERFORM cron.unschedule('refresh_student_week_targets_monday');
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$block$;

SELECT cron.schedule(
  'refresh_student_week_targets_monday',
  '5 16 * * 0',
  $$SELECT public.refresh_student_week_targets();$$
);

DO $block$
BEGIN
  PERFORM cron.unschedule('refresh_w_score_weekday_daily');
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$block$;

SELECT cron.schedule(
  'refresh_w_score_weekday_daily',
  '5 12 * * 1-5',
  $$SELECT public.refresh_all_w_scores();$$
);

DO $block$
BEGIN
  PERFORM cron.unschedule('refresh_w_score_monday_bootstrap');
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$block$;

SELECT cron.schedule(
  'refresh_w_score_monday_bootstrap',
  '10 16 * * 0',
  $$SELECT public.refresh_all_w_scores();$$
);

SELECT public.refresh_all_w_scores();

NOTIFY pgrst, 'reload schema';

COMMIT;
