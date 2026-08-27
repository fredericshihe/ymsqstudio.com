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
  WHERE occupant_student_name IN (v_name, v_canonical_name)
     OR public.canonical_student_name(occupant_student_name) = v_canonical_name;

  DELETE FROM public.practice_alerts
  WHERE student_name = v_name
     OR public.canonical_student_name(student_name) = v_canonical_name;
  DELETE FROM public.practice_logs
  WHERE student_name = v_name
     OR public.canonical_student_name(student_name) = v_canonical_name;
  DELETE FROM public.practice_sessions
  WHERE student_name = v_name
     OR public.canonical_student_name(student_name) = v_canonical_name;
  DELETE FROM public.student_time_slots
  WHERE student_name = v_name
     OR public.canonical_student_name(student_name) = v_canonical_name;
  DELETE FROM public.student_schedules
  WHERE name = v_name
     OR public.canonical_student_name(name) = v_canonical_name;
  DELETE FROM public.student_time_slots_backup
  WHERE student_name = v_name
     OR public.canonical_student_name(student_name) = v_canonical_name;
  DELETE FROM public.student_score_history
  WHERE student_name = v_name
     OR public.canonical_student_name(student_name) = v_canonical_name;
  DELETE FROM public.student_baseline
  WHERE student_name = v_name
     OR public.canonical_student_name(student_name) = v_canonical_name;
  DELETE FROM public.student_coins
  WHERE student_name = v_name
     OR public.canonical_student_name(student_name) = v_canonical_name;
  DELETE FROM public.coin_transactions
  WHERE student_name = v_name
     OR public.canonical_student_name(student_name) = v_canonical_name;
  DELETE FROM public.weekly_coin_reward_detail
  WHERE student_name = v_name
     OR public.canonical_student_name(student_name) = v_canonical_name;
  DELETE FROM public.weekly_leaderboard_history
  WHERE student_name = v_name
     OR public.canonical_student_name(student_name) = v_canonical_name;

  PERFORM set_config('app.skip_score_trigger', 'off', true);
  RETURN OLD;
END;
$function$;

DROP TRIGGER IF EXISTS trg_delete_student_related_records ON public.student_database;
CREATE TRIGGER trg_delete_student_related_records
AFTER DELETE ON public.student_database
FOR EACH ROW
EXECUTE FUNCTION public.delete_student_related_records();
