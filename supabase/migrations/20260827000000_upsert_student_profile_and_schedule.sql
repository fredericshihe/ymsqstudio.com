CREATE OR REPLACE FUNCTION public.upsert_student_profile_and_schedule(
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
  saved_schedule JSONB;
BEGIN
  IF v_name IS NULL OR v_name = '' THEN
    RAISE EXCEPTION '学生姓名不能为空';
  END IF;

  IF v_grade = '' THEN
    RAISE EXCEPTION '学生年级不能为空';
  END IF;

  IF v_major = '' THEN
    RAISE EXCEPTION '学生专业不能为空';
  END IF;

  IF p_cells IS NULL OR jsonb_typeof(p_cells) <> 'object' THEN
    RAISE EXCEPTION '课表 cells 必须是 JSON 对象';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.student_database AS sd
    WHERE sd.name = v_name
  ) THEN
    RAISE EXCEPTION '学生库中已经存在学生“%”，请直接编辑已有学生', v_name;
  END IF;

  BEGIN
    INSERT INTO public.student_database (name, grade, major, archived)
    VALUES (v_name, v_grade, v_major, FALSE);
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION '学生库中已经存在学生“%”，请刷新后编辑已有学生', v_name;
  END;

  saved_schedule := public.upsert_student_schedule(
    p_schedule_id,
    v_name,
    v_grade,
    v_major,
    p_cells
  );

  RETURN saved_schedule || jsonb_build_object('profile_created', TRUE);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.upsert_student_profile_and_schedule(TEXT, TEXT, TEXT, TEXT, JSONB) TO anon, authenticated;
