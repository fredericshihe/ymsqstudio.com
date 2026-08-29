BEGIN;

REVOKE ALL ON FUNCTION public.save_teacher_course_settings(JSONB) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_teacher_course_settings() FROM PUBLIC, anon, authenticated;

DROP FUNCTION IF EXISTS public.save_teacher_course_settings(JSONB);
DROP FUNCTION IF EXISTS public.get_teacher_course_settings();
DROP FUNCTION IF EXISTS public.normalize_teacher_course_departments(JSONB);
DROP TABLE IF EXISTS public.teacher_course_settings;

NOTIFY pgrst, 'reload schema';

COMMIT;
