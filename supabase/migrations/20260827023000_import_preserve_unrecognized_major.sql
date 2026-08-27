CREATE OR REPLACE FUNCTION public.import_student_profile_and_schedule(
  p_schedule_id TEXT,
  p_name TEXT,
  p_grade TEXT,
  p_major TEXT,
  p_cells JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name TEXT := public.canonical_student_name(p_name);
  v_grade TEXT := BTRIM(COALESCE(p_grade, ''));
  v_major TEXT := BTRIM(COALESCE(p_major, ''));
  v_profile_exists BOOLEAN := FALSE;
  v_profile_created BOOLEAN := FALSE;
  v_profile_reactivated BOOLEAN := FALSE;
  v_previous_grade TEXT := '';
  v_previous_major TEXT := '';
  v_previous_archived BOOLEAN := FALSE;
  saved_schedule JSONB;
BEGIN
  IF v_name IS NULL OR v_name = '' THEN
    RAISE EXCEPTION '学生姓名不能为空';
  END IF;
  IF v_grade = '' THEN
    RAISE EXCEPTION '学生年级不能为空';
  END IF;
  IF p_cells IS NULL OR jsonb_typeof(p_cells) <> 'object' THEN
    RAISE EXCEPTION '课表 cells 必须是 JSON 对象';
  END IF;

  SELECT COALESCE(sd.grade, ''), COALESCE(sd.major, ''), COALESCE(sd.archived, FALSE)
  INTO v_previous_grade, v_previous_major, v_previous_archived
  FROM public.student_database AS sd
  WHERE public.canonical_student_name(sd.name) = v_name
  ORDER BY (sd.name = v_name) DESC, sd.updated_at DESC NULLS LAST, sd.id
  LIMIT 1
  FOR UPDATE;

  v_profile_exists := FOUND;
  IF v_profile_exists THEN
    IF v_major = '' OR v_major = '未填写' THEN
      v_major := v_previous_major;
    END IF;
    IF v_major = '' THEN
      v_major := '未填写';
    END IF;
    UPDATE public.student_database
    SET name = v_name,
        grade = v_grade,
        major = v_major,
        archived = FALSE
    WHERE public.canonical_student_name(name) = v_name;
    v_profile_reactivated := v_previous_archived;
  ELSE
    IF v_major = '' THEN
      v_major := '未填写';
    END IF;
    INSERT INTO public.student_database (name, grade, major, archived)
    VALUES (v_name, v_grade, v_major, FALSE);
    v_profile_created := TRUE;
  END IF;

  saved_schedule := public.upsert_student_schedule(
    p_schedule_id, v_name, v_grade, v_major, p_cells
  );

  RETURN saved_schedule || jsonb_build_object(
    'profile_created', v_profile_created,
    'profile_reactivated', v_profile_reactivated,
    'previous_grade', v_previous_grade,
    'previous_major', v_previous_major
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.import_student_profile_and_schedule(TEXT, TEXT, TEXT, TEXT, JSONB) TO anon, authenticated;
