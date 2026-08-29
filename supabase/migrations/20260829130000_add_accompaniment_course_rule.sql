BEGIN;

UPDATE public.teacher_course_settings AS settings
SET rules = settings.rules || jsonb_build_array(
      jsonb_build_object(
        'id', 'accompaniment_lesson',
        'name', '陪练课',
        'aliases', jsonb_build_array('陪练课', '陪练'),
        'mode', 'individual',
        'teacherSource', 'cell',
        'allowMultipleTeachers', FALSE,
        'identifiesMainTeacher', FALSE,
        'enabled', TRUE
      )
    ),
    updated_at = NOW()
WHERE settings.singleton IS TRUE
  AND NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(settings.rules) AS item(rule)
    WHERE item.rule->>'id' = 'accompaniment_lesson'
       OR btrim(COALESCE(item.rule->>'name', '')) = '陪练课'
       OR EXISTS (
         SELECT 1
         FROM jsonb_array_elements_text(
           CASE
             WHEN jsonb_typeof(item.rule->'aliases') = 'array' THEN item.rule->'aliases'
             ELSE '[]'::JSONB
           END
         ) AS alias(value)
         WHERE btrim(alias.value) IN ('陪练课', '陪练')
       )
  );

NOTIFY pgrst, 'reload schema';

COMMIT;
