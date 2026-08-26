CREATE OR REPLACE FUNCTION public.save_student_schedule(
  p_schedule_id TEXT,
  p_expected_revision BIGINT,
  p_cells JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  current_row RECORD;
  saved_row RECORD;
BEGIN
  IF p_cells IS NULL OR jsonb_typeof(p_cells) <> 'object' THEN
    RAISE EXCEPTION '课表 cells 必须是 JSON 对象';
  END IF;

  SELECT
    s.id::TEXT AS id,
    s.name,
    s.grade,
    s.revision,
    s.updated_at
  INTO current_row
  FROM public.student_schedules AS s
  WHERE s.id::TEXT = p_schedule_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到学生课表: %', p_schedule_id;
  END IF;

  IF p_expected_revision IS NOT NULL
     AND current_row.revision <> p_expected_revision THEN
    RAISE EXCEPTION '课表已被其他人修改，请刷新后重试'
      USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.student_schedules
  SET cells = p_cells,
      revision = current_row.revision + 1,
      updated_at = NOW()
  WHERE id::TEXT = current_row.id
  RETURNING
    id::TEXT AS id,
    name,
    grade,
    cells,
    revision,
    updated_at
  INTO saved_row;

  PERFORM public._rebuild_student_schedule_slots(saved_row.name, saved_row.cells);

  RETURN jsonb_build_object(
    'id', saved_row.id,
    'name', saved_row.name,
    'grade', saved_row.grade,
    'cells', saved_row.cells,
    'revision', saved_row.revision,
    'updated_at', saved_row.updated_at
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.save_student_schedule(TEXT, BIGINT, JSONB) TO anon, authenticated;
