BEGIN;

UPDATE public.teacher_course_settings AS settings
SET rules = (
  SELECT jsonb_agg(
    (item.rule - 'teacherSource' - 'identifiesMainTeacher')
      || jsonb_build_object(
        'teacherSource', CASE WHEN item.rule->>'id' = 'performance' THEN 'main' ELSE 'cell' END,
        'identifiesMainTeacher', item.rule->>'id' = 'major'
      )
    ORDER BY item.position
  ) AS rules
  FROM jsonb_array_elements(settings.rules) WITH ORDINALITY AS item(rule, position)
),
    updated_at = NOW()
WHERE settings.singleton IS TRUE;

CREATE OR REPLACE FUNCTION public.save_teacher_course_settings(p_rules JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  normalized_rules JSONB;
BEGIN
  IF p_rules IS NULL OR jsonb_typeof(p_rules) <> 'array' THEN
    RAISE EXCEPTION '课程类别必须是数组';
  END IF;

  IF jsonb_array_length(p_rules) < 1 OR jsonb_array_length(p_rules) > 100 THEN
    RAISE EXCEPTION '课程类别数量必须在 1 到 100 之间';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_rules) AS item(rule)
    WHERE jsonb_typeof(item.rule) <> 'object'
       OR btrim(COALESCE(item.rule->>'id', '')) = ''
       OR btrim(COALESCE(item.rule->>'name', '')) = ''
       OR char_length(item.rule->>'name') > 50
       OR COALESCE(jsonb_typeof(item.rule->'aliases'), '') <> 'array'
       OR CASE
            WHEN jsonb_typeof(item.rule->'aliases') = 'array'
              THEN jsonb_array_length(item.rule->'aliases') < 1
            ELSE FALSE
          END
       OR COALESCE(item.rule->>'mode', '') NOT IN ('individual', 'group')
  ) THEN
    RAISE EXCEPTION '课程类别中存在无效字段';
  END IF;

  SELECT jsonb_agg(
    (item.rule - 'teacherSource' - 'identifiesMainTeacher')
      || jsonb_build_object(
        'teacherSource', CASE WHEN item.rule->>'id' = 'performance' THEN 'main' ELSE 'cell' END,
        'identifiesMainTeacher', item.rule->>'id' = 'major'
      )
    ORDER BY item.position
  )
  INTO normalized_rules
  FROM jsonb_array_elements(p_rules) WITH ORDINALITY AS item(rule, position);

  INSERT INTO public.teacher_course_settings (singleton, rules, updated_at)
  VALUES (TRUE, normalized_rules, NOW())
  ON CONFLICT (singleton) DO UPDATE
  SET rules = EXCLUDED.rules,
      updated_at = EXCLUDED.updated_at;

  RETURN public.get_teacher_course_settings();
END;
$function$;

REVOKE ALL ON FUNCTION public.save_teacher_course_settings(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_teacher_course_settings(JSONB) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
