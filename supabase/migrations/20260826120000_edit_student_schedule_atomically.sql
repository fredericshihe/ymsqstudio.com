ALTER TABLE public.student_schedules
  ADD COLUMN IF NOT EXISTS revision BIGINT NOT NULL DEFAULT 1;

CREATE OR REPLACE FUNCTION public._rebuild_student_schedule_slots(
  p_student_name TEXT,
  p_cells JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  DELETE FROM public.student_time_slots
  WHERE student_name = p_student_name
    AND weekday BETWEEN 1 AND 5;

  INSERT INTO public.student_time_slots (
    student_name,
    weekday,
    start_time,
    end_time,
    duration_minutes
  )
  SELECT
    p_student_name,
    (cell->>'day')::INTEGER + 1,
    parsed.start_time,
    parsed.end_time,
    EXTRACT(EPOCH FROM (parsed.end_time - parsed.start_time))::INTEGER / 60
  FROM jsonb_each(COALESCE(p_cells, '{}'::JSONB)) AS item(cell_key, cell)
  CROSS JOIN LATERAL (
    SELECT
      split_part(cell->>'time', '-', 1)::TIME AS start_time,
      split_part(cell->>'time', '-', 2)::TIME AS end_time
  ) AS parsed
  WHERE LOWER(COALESCE(cell->>'practice', 'false')) = 'true'
    AND (cell->>'day') ~ '^[0-4]$'
    AND (cell->>'time') ~ '^[0-9]{1,2}:[0-9]{2}-[0-9]{1,2}:[0-9]{2}$'
    AND parsed.start_time < parsed.end_time;
END;
$function$;

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
      USING ERRCODE = '40001';
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

CREATE OR REPLACE FUNCTION public.upsert_student_schedule(
  p_schedule_id TEXT,
  p_name TEXT,
  p_grade TEXT,
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
    s.revision
  INTO current_row
  FROM public.student_schedules AS s
  WHERE s.id::TEXT = p_schedule_id
     OR s.name = p_name
  ORDER BY (s.id::TEXT = p_schedule_id) DESC
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    IF current_row.name IS DISTINCT FROM p_name THEN
      UPDATE public.student_time_slots
      SET student_name = p_name
      WHERE student_name = current_row.name;
    END IF;

    UPDATE public.student_schedules
    SET name = p_name,
        grade = COALESCE(p_grade, ''),
        cells = p_cells,
        revision = current_row.revision + 1,
        updated_at = NOW()
    WHERE id::TEXT = current_row.id;
  ELSE
    INSERT INTO public.student_schedules (id, name, grade, cells, revision, updated_at)
    VALUES (p_schedule_id, p_name, COALESCE(p_grade, ''), p_cells, 1, NOW());
  END IF;

  SELECT
    s.id::TEXT AS id,
    s.name,
    s.grade,
    s.cells,
    s.revision,
    s.updated_at
  INTO saved_row
  FROM public.student_schedules AS s
  WHERE s.name = p_name
  ORDER BY s.updated_at DESC
  LIMIT 1;

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
GRANT EXECUTE ON FUNCTION public.upsert_student_schedule(TEXT, TEXT, TEXT, JSONB) TO anon, authenticated;
REVOKE ALL ON FUNCTION public._rebuild_student_schedule_slots(TEXT, JSONB) FROM PUBLIC;
