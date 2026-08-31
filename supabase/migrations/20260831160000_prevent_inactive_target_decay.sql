BEGIN;

ALTER FUNCTION public.calculate_student_week_target(TEXT, DATE)
  RENAME TO calculate_student_week_target_core;

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
  calculated_row RECORD;
  v_previous_locked_target FLOAT8;
BEGIN
  SELECT *
  INTO calculated_row
  FROM public.calculate_student_week_target_core(p_student_name, p_week_monday);

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT swt.target_minutes::FLOAT8
  INTO v_previous_locked_target
  FROM public.student_week_targets swt
  WHERE swt.student_name = p_student_name
    AND swt.week_monday < p_week_monday
  ORDER BY swt.week_monday DESC
  LIMIT 1;

  IF v_previous_locked_target IS NOT NULL
     AND calculated_row.recent_active_weeks = 0 THEN
    RETURN QUERY
    SELECT
      v_previous_locked_target,
      v_previous_locked_target,
      calculated_row.major_floor_week,
      calculated_row.personal_week_ref,
      calculated_row.peer_week_ref,
      calculated_row.effective_mean,
      v_previous_locked_target,
      0,
      'carry_forward_no_new_week'::TEXT,
      calculated_row.score_period_start;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    calculated_row.final_target_week,
    calculated_row.personal_target_week,
    calculated_row.major_floor_week,
    calculated_row.personal_week_ref,
    calculated_row.peer_week_ref,
    calculated_row.effective_mean,
    calculated_row.prior_target_week,
    calculated_row.recent_active_weeks,
    calculated_row.target_source,
    calculated_row.score_period_start;
END;
$function$;

REVOKE ALL ON FUNCTION public.calculate_student_week_target(TEXT, DATE) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.calculate_student_week_target_core(TEXT, DATE) FROM PUBLIC, anon, authenticated;

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

CREATE OR REPLACE FUNCTION public.lock_current_week_target_for_student()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  target_row RECORD;
  v_week_monday DATE;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.name IS DISTINCT FROM NEW.name THEN
    DELETE FROM public.student_week_targets old_target
    WHERE old_target.student_name = OLD.name
      AND EXISTS (
        SELECT 1
        FROM public.student_week_targets new_target
        WHERE new_target.student_name = NEW.name
          AND new_target.week_monday = old_target.week_monday
      );

    UPDATE public.student_week_targets
    SET student_name = NEW.name
    WHERE student_name = OLD.name;
  END IF;

  IF COALESCE(NEW.archived, FALSE) IS TRUE
     OR NULLIF(BTRIM(NEW.name), '') IS NULL THEN
    RETURN NEW;
  END IF;

  v_week_monday := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;

  SELECT *
  INTO target_row
  FROM public.calculate_student_week_target(NEW.name, v_week_monday);

  IF NOT FOUND OR target_row.final_target_week IS NULL THEN
    RETURN NEW;
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
    NEW.name,
    v_week_monday,
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
  ON CONFLICT (student_name, week_monday) DO NOTHING;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.lock_current_week_target_for_student() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_lock_current_week_target_for_student ON public.student_database;
CREATE TRIGGER trg_lock_current_week_target_for_student
AFTER INSERT OR UPDATE OF name, major, grade, archived
ON public.student_database
FOR EACH ROW
EXECUTE FUNCTION public.lock_current_week_target_for_student();

NOTIFY pgrst, 'reload schema';

COMMIT;
