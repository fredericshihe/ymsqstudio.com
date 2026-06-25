-- Keep student identity references in sync when student_database.name changes.
-- The app treats student name as the cross-table identity key, so a rename must
-- cascade to practice, ranking, AI analysis, coin, schedule, and history tables.

CREATE OR REPLACE FUNCTION public.trigger_update_student_baseline()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_skip TEXT := LOWER(COALESCE(current_setting('app.skip_score_trigger', true), ''));
BEGIN
  IF v_skip IN ('on', 'true', '1') THEN
    RETURN NEW;
  END IF;

  PERFORM public.update_student_baseline(NEW.student_name);
  RETURN NEW;
END;
$function$;
CREATE OR REPLACE FUNCTION public.tg_refresh_w_after_session()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_skip TEXT := LOWER(COALESCE(current_setting('app.skip_score_trigger', true), ''));
BEGIN
  IF v_skip IN ('on', 'true', '1') THEN
    RETURN NEW;
  END IF;

  IF NEW.student_name IS NOT NULL THEN
    PERFORM public.compute_and_store_w_score(NEW.student_name);
  END IF;

  RETURN NEW;
END;
$function$;
CREATE OR REPLACE FUNCTION public.sync_student_name_references()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_old_name TEXT := NULLIF(BTRIM(OLD.name), '');
  v_new_name TEXT := NULLIF(BTRIM(NEW.name), '');
BEGIN
  IF TG_OP <> 'UPDATE'
     OR v_old_name IS NULL
     OR v_new_name IS NULL
     OR v_old_name = v_new_name THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.student_database sd
    WHERE sd.id <> NEW.id
      AND sd.name = v_new_name
  ) THEN
    RAISE EXCEPTION '学生姓名已存在，不能将 % 改名为 %', v_old_name, v_new_name;
  END IF;

  PERFORM set_config('app.skip_score_trigger', 'on', true);

  UPDATE public.rooms
  SET occupant_student_name = v_new_name
  WHERE occupant_student_name = v_old_name;

  UPDATE public.practice_logs
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  DELETE FROM public.practice_sessions ps
  USING public.practice_sessions old_ps
  WHERE ps.student_name = v_new_name
    AND old_ps.student_name = v_old_name
    AND ps.session_start = old_ps.session_start;

  UPDATE public.practice_sessions
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  DELETE FROM public.student_baseline
  WHERE student_name = v_new_name;

  UPDATE public.student_baseline
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  DELETE FROM public.student_score_history h
  USING public.student_score_history old_h
  WHERE h.student_name = v_new_name
    AND old_h.student_name = v_old_name
    AND h.snapshot_date = old_h.snapshot_date;

  UPDATE public.student_score_history
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  DELETE FROM public.student_ai_analysis
  WHERE student_name = v_new_name;

  UPDATE public.student_ai_analysis
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  DELETE FROM public.student_coins
  WHERE student_name = v_new_name;

  UPDATE public.student_coins
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  UPDATE public.coin_transactions
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  UPDATE public.weekly_coin_reward_detail
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  UPDATE public.weekly_leaderboard_history
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  UPDATE public.weekly_coin_reward_log
  SET summary = REPLACE(summary::TEXT, v_old_name, v_new_name)::jsonb
  WHERE summary::TEXT LIKE '%' || v_old_name || '%';

  UPDATE public.student_time_slots
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  UPDATE public.student_schedules
  SET name = v_new_name
  WHERE name = v_old_name;

  RETURN NEW;
END;
$function$;
DROP TRIGGER IF EXISTS trg_sync_student_name_references ON public.student_database;
CREATE TRIGGER trg_sync_student_name_references
AFTER UPDATE OF name ON public.student_database
FOR EACH ROW
WHEN (OLD.name IS DISTINCT FROM NEW.name)
EXECUTE FUNCTION public.sync_student_name_references();
