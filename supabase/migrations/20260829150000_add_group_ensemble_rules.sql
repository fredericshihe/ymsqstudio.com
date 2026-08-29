BEGIN;

UPDATE public.teacher_course_settings AS settings
SET rules = settings.rules
  || CASE
       WHEN EXISTS (
         SELECT 1
         FROM jsonb_array_elements(settings.rules) AS item(rule)
         WHERE item.rule->>'id' = 'classical_guitar_ensemble'
            OR btrim(COALESCE(item.rule->>'name', '')) = '古典吉他室内乐'
            OR EXISTS (
              SELECT 1
              FROM jsonb_array_elements_text(
                CASE WHEN jsonb_typeof(item.rule->'aliases') = 'array' THEN item.rule->'aliases' ELSE '[]'::JSONB END
              ) AS alias(value)
              WHERE btrim(alias.value) IN ('古典吉他室内乐', 'Classical Guitar Ensemble')
            )
       ) THEN '[]'::JSONB
       ELSE jsonb_build_array(
         jsonb_build_object(
           'id', 'classical_guitar_ensemble',
           'name', '古典吉他室内乐',
           'aliases', jsonb_build_array('古典吉他室内乐', 'Classical Guitar Ensemble'),
           'mode', 'group',
           'teacherSource', 'cell',
           'allowMultipleTeachers', FALSE,
           'identifiesMainTeacher', FALSE,
           'enabled', TRUE
         )
       )
     END
  || CASE
       WHEN EXISTS (
         SELECT 1
         FROM jsonb_array_elements(settings.rules) AS item(rule)
         WHERE item.rule->>'id' = 'brass_ensemble'
            OR btrim(COALESCE(item.rule->>'name', '')) = '铜管室内乐'
            OR EXISTS (
              SELECT 1
              FROM jsonb_array_elements_text(
                CASE WHEN jsonb_typeof(item.rule->'aliases') = 'array' THEN item.rule->'aliases' ELSE '[]'::JSONB END
              ) AS alias(value)
              WHERE btrim(alias.value) IN ('铜管室内乐', 'Brass Ensemble')
            )
       ) THEN '[]'::JSONB
       ELSE jsonb_build_array(
         jsonb_build_object(
           'id', 'brass_ensemble',
           'name', '铜管室内乐',
           'aliases', jsonb_build_array('铜管室内乐', 'Brass Ensemble'),
           'mode', 'group',
           'teacherSource', 'cell',
           'allowMultipleTeachers', FALSE,
           'identifiesMainTeacher', FALSE,
           'enabled', TRUE
         )
       )
     END
WHERE settings.singleton IS TRUE;

NOTIFY pgrst, 'reload schema';

COMMIT;
