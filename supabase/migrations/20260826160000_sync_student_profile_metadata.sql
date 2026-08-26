CREATE OR REPLACE FUNCTION public.sync_student_profile_metadata()
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
     OR (OLD.name IS NOT DISTINCT FROM NEW.name
         AND OLD.major IS NOT DISTINCT FROM NEW.major
         AND OLD.grade IS NOT DISTINCT FROM NEW.grade) THEN
    RETURN NEW;
  END IF;

  PERFORM set_config('app.skip_score_trigger', 'on', true);

  UPDATE public.practice_sessions
  SET student_major = NEW.major,
      student_grade = NEW.grade
  WHERE student_name IN (v_old_name, v_new_name);

  UPDATE public.practice_logs
  SET student_major = NEW.major,
      student_grade = NEW.grade
  WHERE student_name IN (v_old_name, v_new_name);

  PERFORM set_config('app.skip_score_trigger', 'off', true);

  UPDATE public.student_baseline
  SET student_major = NEW.major,
      student_grade = NEW.grade
  WHERE student_name IN (v_old_name, v_new_name);

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_sync_student_profile_metadata ON public.student_database;
CREATE TRIGGER trg_sync_student_profile_metadata
AFTER UPDATE OF name, major, grade ON public.student_database
FOR EACH ROW
WHEN (
  OLD.name IS DISTINCT FROM NEW.name
  OR OLD.major IS DISTINCT FROM NEW.major
  OR OLD.grade IS DISTINCT FROM NEW.grade
)
EXECUTE FUNCTION public.sync_student_profile_metadata();

DO $migration$
BEGIN
  PERFORM set_config('app.skip_score_trigger', 'on', true);

  UPDATE public.practice_sessions ps
  SET student_major = sd.major,
      student_grade = sd.grade
  FROM public.student_database sd
  WHERE ps.student_name = sd.name
    AND (ps.student_major IS DISTINCT FROM sd.major
         OR ps.student_grade IS DISTINCT FROM sd.grade);

  UPDATE public.practice_logs pl
  SET student_major = sd.major,
      student_grade = sd.grade
  FROM public.student_database sd
  WHERE pl.student_name = sd.name
    AND (pl.student_major IS DISTINCT FROM sd.major
         OR pl.student_grade IS DISTINCT FROM sd.grade);

  PERFORM set_config('app.skip_score_trigger', 'off', true);

  UPDATE public.student_baseline sb
  SET student_major = sd.major,
      student_grade = sd.grade
  FROM public.student_database sd
  WHERE sb.student_name = sd.name
    AND (sb.student_major IS DISTINCT FROM sd.major
         OR sb.student_grade IS DISTINCT FROM sd.grade);
END;
$migration$;
