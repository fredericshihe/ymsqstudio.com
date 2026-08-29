BEGIN;

CREATE TABLE IF NOT EXISTS public.teacher_course_settings (
  singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton IS TRUE),
  rules JSONB NOT NULL CHECK (jsonb_typeof(rules) = 'array'),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.teacher_course_settings (singleton, rules)
VALUES (
  TRUE,
  '[
    {"id":"major","name":"主修课","aliases":["主修课","主修课程","主修","专业课","专业课程","1to1 major","1 to 1 major","major"],"mode":"individual","teacherSource":"cell","allowMultipleTeachers":false,"identifiesMainTeacher":true,"enabled":true},
    {"id":"performance","name":"表演课","aliases":["表演课"],"mode":"group","teacherSource":"main","allowMultipleTeachers":false,"identifiesMainTeacher":false,"enabled":true},
    {"id":"practice_lesson","name":"练琴课","aliases":["练琴课"],"mode":"individual","teacherSource":"cell","allowMultipleTeachers":false,"identifiesMainTeacher":false,"enabled":true},
    {"id":"accompaniment_lesson","name":"陪练课","aliases":["陪练课","陪练"],"mode":"individual","teacherSource":"cell","allowMultipleTeachers":false,"identifiesMainTeacher":false,"enabled":true},
    {"id":"secondary_major","name":"二专","aliases":["二专","第二专业","二专业"],"mode":"individual","teacherSource":"cell","allowMultipleTeachers":false,"identifiesMainTeacher":false,"enabled":true},
    {"id":"classical_guitar_ensemble","name":"古典吉他室内乐","aliases":["古典吉他室内乐","Classical Guitar Ensemble"],"mode":"group","teacherSource":"cell","allowMultipleTeachers":false,"identifiesMainTeacher":false,"enabled":true},
    {"id":"brass_ensemble","name":"铜管室内乐","aliases":["铜管室内乐","Brass Ensemble"],"mode":"group","teacherSource":"cell","allowMultipleTeachers":false,"identifiesMainTeacher":false,"enabled":true},
    {"id":"chamber_music","name":"室内乐","aliases":["室内乐"],"mode":"individual","teacherSource":"cell","allowMultipleTeachers":true,"identifiesMainTeacher":false,"enabled":true},
    {"id":"core_musicianship","name":"核心音乐素养","aliases":["核心音乐素养"],"mode":"group","teacherSource":"cell","allowMultipleTeachers":false,"identifiesMainTeacher":false,"enabled":true},
    {"id":"piano_skills","name":"钢琴技巧课","aliases":["钢琴技巧课","钢琴技巧"],"mode":"group","teacherSource":"cell","allowMultipleTeachers":false,"identifiesMainTeacher":false,"enabled":true},
    {"id":"electone","name":"双排键","aliases":["双排键"],"mode":"individual","teacherSource":"cell","allowMultipleTeachers":false,"identifiesMainTeacher":false,"enabled":true},
    {"id":"four_hands","name":"四手联弹","aliases":["四手联弹"],"mode":"individual","teacherSource":"cell","allowMultipleTeachers":false,"identifiesMainTeacher":false,"enabled":true},
    {"id":"two_pianos","name":"双钢琴","aliases":["双钢琴"],"mode":"individual","teacherSource":"cell","allowMultipleTeachers":false,"identifiesMainTeacher":false,"enabled":true},
    {"id":"vocal","name":"声乐","aliases":["声乐"],"mode":"individual","teacherSource":"cell","allowMultipleTeachers":false,"identifiesMainTeacher":false,"enabled":true},
    {"id":"composition","name":"作曲","aliases":["作曲"],"mode":"individual","teacherSource":"cell","allowMultipleTeachers":false,"identifiesMainTeacher":false,"enabled":true},
    {"id":"arranging","name":"编曲","aliases":["编曲"],"mode":"individual","teacherSource":"cell","allowMultipleTeachers":false,"identifiesMainTeacher":false,"enabled":true},
    {"id":"choir","name":"合唱课","aliases":["合唱课","合唱"],"mode":"group","teacherSource":"cell","allowMultipleTeachers":false,"identifiesMainTeacher":false,"enabled":true}
  ]'::JSONB
)
ON CONFLICT (singleton) DO NOTHING;

CREATE OR REPLACE FUNCTION public.get_teacher_course_settings()
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT jsonb_build_object(
    'rules', COALESCE(
      (SELECT settings.rules FROM public.teacher_course_settings settings WHERE settings.singleton IS TRUE),
      '[]'::JSONB
    ),
    'updated_at', (
      SELECT settings.updated_at FROM public.teacher_course_settings settings WHERE settings.singleton IS TRUE
    )
  );
$function$;

CREATE OR REPLACE FUNCTION public.save_teacher_course_settings(p_rules JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
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
       OR COALESCE(item.rule->>'teacherSource', '') NOT IN ('cell', 'main')
  ) THEN
    RAISE EXCEPTION '课程类别中存在无效字段';
  END IF;

  INSERT INTO public.teacher_course_settings (singleton, rules, updated_at)
  VALUES (TRUE, p_rules, NOW())
  ON CONFLICT (singleton) DO UPDATE
  SET rules = EXCLUDED.rules,
      updated_at = EXCLUDED.updated_at;

  RETURN public.get_teacher_course_settings();
END;
$function$;

ALTER TABLE public.teacher_course_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS teacher_course_settings_read
  ON public.teacher_course_settings;

CREATE POLICY teacher_course_settings_read
  ON public.teacher_course_settings
  FOR SELECT
  TO anon, authenticated
  USING (singleton IS TRUE);

REVOKE ALL ON TABLE public.teacher_course_settings FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.teacher_course_settings
  FROM anon, authenticated;
GRANT SELECT ON TABLE public.teacher_course_settings TO anon, authenticated;

REVOKE ALL ON FUNCTION public.get_teacher_course_settings() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_teacher_course_settings(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_teacher_course_settings() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_teacher_course_settings(JSONB) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
