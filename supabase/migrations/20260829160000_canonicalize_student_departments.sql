BEGIN;

CREATE OR REPLACE FUNCTION public.canonical_student_major(p_major TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_part TEXT;
  v_normalized TEXT;
  v_office TEXT;
  v_result TEXT := '';
BEGIN
  IF p_major IS NULL THEN
    RETURN NULL;
  END IF;

  FOR v_part IN
    SELECT BTRIM(value)
    FROM REGEXP_SPLIT_TO_TABLE(BTRIM(p_major), '[/／、，,+]|和|与') AS parts(value)
    WHERE BTRIM(value) <> ''
  LOOP
    v_normalized := REGEXP_REPLACE(v_part, '[[:space:]]+', '', 'g');
    v_office := CASE
      WHEN v_normalized ILIKE '%中提琴%' THEN '小提琴教研室'
      WHEN v_normalized ILIKE '%合唱团%'
        OR v_normalized ILIKE '%合唱课%'
        OR v_normalized = '合唱'
        OR v_normalized ILIKE '%核心音乐素养%'
        OR v_normalized ILIKE '%音乐综合学科%'
        THEN '音乐综合学科教研室'
      ELSE v_part
    END;

    IF POSITION('/' || v_office || '/' IN '/' || v_result || '/') = 0 THEN
      v_result := CASE WHEN v_result = '' THEN v_office ELSE v_result || '/' || v_office END;
    END IF;
  END LOOP;

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.normalize_student_major_before_write()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $function$
BEGIN
  NEW.major := public.canonical_student_major(NEW.major);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_normalize_student_major ON public.student_database;
CREATE TRIGGER trg_normalize_student_major
BEFORE INSERT OR UPDATE OF major ON public.student_database
FOR EACH ROW
EXECUTE FUNCTION public.normalize_student_major_before_write();

CREATE OR REPLACE FUNCTION public.student_major_from_identity(p_name TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_text TEXT := BTRIM(COALESCE(p_name, ''));
  v_token TEXT;
  v_part TEXT;
  v_office TEXT;
  v_major TEXT := '';
BEGIN
  v_text := BTRIM(REGEXP_REPLACE(
    v_text,
    '^G[0-9]{1,2}(?:[-.][[:space:]]*[0-9]+)?[[:space:]]*',
    '',
    1,
    1,
    'i'
  ));
  IF v_text !~ '^[^[:space:]]+[[:space:]]+.+$' THEN
    RETURN NULL;
  END IF;
  v_token := SPLIT_PART(REGEXP_REPLACE(v_text, '[[:space:]]+', ' ', 'g'), ' ', 1);
  FOR v_part IN
    SELECT BTRIM(value)
    FROM REGEXP_SPLIT_TO_TABLE(v_token, '[/／、，,+]|和|与') AS parts(value)
  LOOP
    v_office := CASE
      WHEN v_part ILIKE '%古典吉他%' OR v_part ILIKE '%吉他%' THEN '吉他教研室'
      WHEN v_part ILIKE '%低音提琴%' OR v_part ILIKE '%大提琴%' THEN '大提琴教研室'
      WHEN v_part ILIKE '%中提琴%' OR v_part ILIKE '%小提琴%' THEN '小提琴教研室'
      WHEN v_part ILIKE '%钢琴%' THEN '钢琴教研室'
      WHEN v_part ILIKE '%竖琴%' THEN '竖琴教研室'
      WHEN v_part ILIKE '%长笛%' OR v_part ILIKE '%单簧管%' OR v_part ILIKE '%双簧管%'
        OR v_part ILIKE '%大管%' OR v_part ILIKE '%巴松%' OR v_part ILIKE '%萨克斯%'
        OR v_part ILIKE '%笛子%' OR v_part ILIKE '%箫%' OR v_part ILIKE '%唢呐%'
        THEN '木管教研室'
      WHEN v_part ILIKE '%小号%' OR v_part ILIKE '%圆号%' OR v_part ILIKE '%长号%'
        OR v_part ILIKE '%大号%' THEN '铜管教研室'
      WHEN v_part ILIKE '%打击乐%' OR v_part ILIKE '%架子鼓%' OR v_part ILIKE '%马林巴%'
        OR v_part ILIKE '%定音鼓%' THEN '打击乐教研室'
      WHEN v_part ILIKE '%合唱团%' OR v_part ILIKE '%合唱课%' OR v_part = '合唱'
        OR v_part ILIKE '%核心音乐素养%' OR v_part ILIKE '%音乐综合学科%'
        THEN '音乐综合学科教研室'
      WHEN v_part ILIKE '%声乐%' OR v_part ILIKE '%美声%' OR v_part ILIKE '%歌唱%'
        THEN '声乐教研室'
      WHEN v_part ILIKE '%钢琴教研室%' THEN '钢琴教研室'
      WHEN v_part ILIKE '%小提琴教研室%' OR v_part ILIKE '%中提琴教研室%' THEN '小提琴教研室'
      WHEN v_part ILIKE '%大提琴教研室%' THEN '大提琴教研室'
      WHEN v_part ILIKE '%竖琴教研室%' THEN '竖琴教研室'
      WHEN v_part ILIKE '%吉他教研室%' THEN '吉他教研室'
      WHEN v_part ILIKE '%木管教研室%' THEN '木管教研室'
      WHEN v_part ILIKE '%铜管教研室%' THEN '铜管教研室'
      WHEN v_part ILIKE '%打击乐教研室%' THEN '打击乐教研室'
      WHEN v_part ILIKE '%声乐教研室%' THEN '声乐教研室'
      ELSE NULL
    END;
    IF v_office IS NOT NULL
       AND POSITION('/' || v_office || '/' IN '/' || v_major || '/') = 0 THEN
      v_major := CASE WHEN v_major = '' THEN v_office ELSE v_major || '/' || v_office END;
    END IF;
  END LOOP;
  RETURN public.canonical_student_major(NULLIF(v_major, ''));
END;
$function$;

UPDATE public.student_database
SET major = public.canonical_student_major(major)
WHERE major IS DISTINCT FROM public.canonical_student_major(major);

UPDATE public.student_schedules
SET major = public.canonical_student_major(major)
WHERE major IS DISTINCT FROM public.canonical_student_major(major);

UPDATE public.practice_sessions
SET student_major = public.canonical_student_major(student_major)
WHERE student_major IS DISTINCT FROM public.canonical_student_major(student_major);

UPDATE public.practice_logs
SET student_major = public.canonical_student_major(student_major)
WHERE student_major IS DISTINCT FROM public.canonical_student_major(student_major);

UPDATE public.student_baseline
SET student_major = public.canonical_student_major(student_major)
WHERE student_major IS DISTINCT FROM public.canonical_student_major(student_major);

CREATE OR REPLACE FUNCTION public.normalize_teacher_course_departments(p_rules JSONB)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_rule JSONB;
  v_aliases JSONB;
  v_is_core BOOLEAN;
  v_is_choir BOOLEAN;
  v_office TEXT;
  v_result JSONB := '[]'::JSONB;
BEGIN
  IF p_rules IS NULL OR jsonb_typeof(p_rules) <> 'array' THEN
    RETURN p_rules;
  END IF;

  FOR v_rule IN SELECT value FROM jsonb_array_elements(p_rules)
  LOOP
    v_aliases := CASE WHEN jsonb_typeof(v_rule->'aliases') = 'array' THEN v_rule->'aliases' ELSE '[]'::JSONB END;
    v_is_core := v_rule->>'id' = 'core_musicianship'
      OR BTRIM(COALESCE(v_rule->>'name', '')) = '核心音乐素养'
      OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_aliases) AS alias(value) WHERE BTRIM(alias.value) = '核心音乐素养');
    v_is_choir := v_rule->>'id' = 'choir'
      OR BTRIM(COALESCE(v_rule->>'name', '')) IN ('合唱团', '合唱课', '合唱')
      OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_aliases) AS alias(value) WHERE BTRIM(alias.value) IN ('合唱团', '合唱课', '合唱'));

    IF v_is_core OR v_is_choir THEN
      v_rule := v_rule || jsonb_build_object('office', '音乐综合学科教研室');
    ELSIF BTRIM(COALESCE(v_rule->>'office', '')) <> '' THEN
      v_office := public.canonical_student_major(v_rule->>'office');
      v_rule := v_rule || jsonb_build_object('office', v_office);
    END IF;

    IF v_is_choir AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements_text(v_aliases) AS alias(value) WHERE BTRIM(alias.value) = '合唱团'
    ) THEN
      v_rule := jsonb_set(v_rule, '{aliases}', v_aliases || jsonb_build_array('合唱团'), TRUE);
    END IF;

    v_result := v_result || jsonb_build_array(v_rule);
  END LOOP;

  RETURN v_result;
END;
$function$;

UPDATE public.teacher_course_settings
SET rules = public.normalize_teacher_course_departments(rules),
    updated_at = NOW()
WHERE singleton IS TRUE
  AND rules IS DISTINCT FROM public.normalize_teacher_course_departments(rules);

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
       OR (item.rule ? 'office' AND jsonb_typeof(item.rule->'office') <> 'string')
       OR char_length(COALESCE(item.rule->>'office', '')) > 60
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

  normalized_rules := public.normalize_teacher_course_departments(normalized_rules);

  INSERT INTO public.teacher_course_settings (singleton, rules, updated_at)
  VALUES (TRUE, normalized_rules, NOW())
  ON CONFLICT (singleton) DO UPDATE
  SET rules = EXCLUDED.rules,
      updated_at = EXCLUDED.updated_at;

  RETURN public.get_teacher_course_settings();
END;
$function$;

REVOKE ALL ON FUNCTION public.canonical_student_major(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.normalize_student_major_before_write() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.student_major_from_identity(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.normalize_teacher_course_departments(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_teacher_course_settings(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_teacher_course_settings(JSONB) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
