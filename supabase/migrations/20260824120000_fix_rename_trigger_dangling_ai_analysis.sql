-- 20260822090100_remove_ai_practice_analysis.sql dropped public.student_ai_analysis
-- but never updated the student-rename cascade trigger (trg_sync_student_name_references,
-- added in 20260616133000_sync_student_name_references.sql), which still referenced it.
-- Result: ANY rename of student_database.name (via the app's "编辑学生" rename flow, or a
-- direct UPDATE) fails with `relation "public.student_ai_analysis" does not exist`.
-- This migration re-creates the trigger function with the dead student_ai_analysis
-- statements removed; everything else is unchanged from the original definition.

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
