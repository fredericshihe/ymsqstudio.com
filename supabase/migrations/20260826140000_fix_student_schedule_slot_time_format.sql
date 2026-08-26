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
    to_char(parsed.start_time, 'HH24:MI'),
    to_char(parsed.end_time, 'HH24:MI'),
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
