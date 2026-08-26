ALTER TABLE public.student_schedules
  ADD COLUMN IF NOT EXISTS major TEXT NOT NULL DEFAULT '';

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
  SELECT DISTINCT
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
    AND parsed.start_time < parsed.end_time
  ON CONFLICT DO NOTHING;
END;
$function$;

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
      WHEN v_part ILIKE '%中提琴%' THEN '中提琴教研室'
      WHEN v_part ILIKE '%小提琴%' THEN '小提琴教研室'
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
      WHEN v_part ILIKE '%声乐%' OR v_part ILIKE '%美声%' OR v_part ILIKE '%合唱%'
        OR v_part ILIKE '%歌唱%' THEN '声乐教研室'
      WHEN v_part ILIKE '%钢琴教研室%' THEN '钢琴教研室'
      WHEN v_part ILIKE '%小提琴教研室%' THEN '小提琴教研室'
      WHEN v_part ILIKE '%大提琴教研室%' THEN '大提琴教研室'
      WHEN v_part ILIKE '%中提琴教研室%' THEN '中提琴教研室'
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
  RETURN NULLIF(v_major, '');
END;
$function$;

CREATE OR REPLACE FUNCTION public.canonical_student_name(p_name TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_text TEXT := BTRIM(COALESCE(p_name, ''));
  v_normalized TEXT;
  v_token TEXT;
BEGIN
  v_normalized := BTRIM(REGEXP_REPLACE(v_text, '[[:space:]]+', ' ', 'g'));
  v_normalized := BTRIM(REGEXP_REPLACE(
    v_normalized,
    '^G[0-9]{1,2}(?:[-.][[:space:]]*[0-9]+)?[[:space:]]*',
    '',
    1,
    1,
    'i'
  ));
  IF public.student_major_from_identity(v_normalized) IS NOT NULL THEN
    v_token := SPLIT_PART(v_normalized, ' ', 1);
    v_normalized := BTRIM(SUBSTRING(v_normalized FROM LENGTH(v_token) + 1));
  END IF;
  RETURN NULLIF(BTRIM(REGEXP_REPLACE(v_normalized, '[[:space:]]+', ' ', 'g')), '');
END;
$function$;

DO $migration$
DECLARE
  r RECORD;
  v_name TEXT;
  v_keeper_id TEXT;
  v_cells JSONB;
  v_max_revision BIGINT;
  v_max_updated TIMESTAMPTZ;
BEGIN
  CREATE TEMP TABLE _student_schedule_identity (
    schedule_id TEXT PRIMARY KEY,
    raw_name TEXT NOT NULL,
    canonical_name TEXT NOT NULL
  ) ON COMMIT DROP;

  INSERT INTO _student_schedule_identity(schedule_id, raw_name, canonical_name)
  SELECT s.id::TEXT, BTRIM(s.name), public.canonical_student_name(s.name)
  FROM public.student_schedules AS s
  WHERE NULLIF(BTRIM(s.name), '') IS NOT NULL;

  CREATE TEMP TABLE _student_schedule_affected(name TEXT PRIMARY KEY) ON COMMIT DROP;

  INSERT INTO _student_schedule_affected(name)
  SELECT DISTINCT m.canonical_name
  FROM _student_schedule_identity AS m
  JOIN public.student_database AS sd ON sd.name = m.canonical_name
  WHERE m.raw_name IS DISTINCT FROM m.canonical_name;

  PERFORM set_config('app.skip_score_trigger', 'on', true);

  FOR r IN
    SELECT DISTINCT m.raw_name, m.canonical_name
    FROM _student_schedule_identity AS m
    JOIN public.student_database AS sd ON sd.name = m.canonical_name
    WHERE m.raw_name IS DISTINCT FROM m.canonical_name
  LOOP
    UPDATE public.rooms
    SET occupant_student_name = r.canonical_name
    WHERE occupant_student_name = r.raw_name;

    UPDATE public.practice_alerts
    SET student_name = r.canonical_name
    WHERE student_name = r.raw_name;

    UPDATE public.practice_logs
    SET student_name = r.canonical_name
    WHERE student_name = r.raw_name;

    DELETE FROM public.practice_sessions AS target
    USING public.practice_sessions AS source
    WHERE source.student_name = r.raw_name
      AND target.student_name = r.canonical_name
      AND target.session_start = source.session_start;
    UPDATE public.practice_sessions
    SET student_name = r.canonical_name
    WHERE student_name = r.raw_name;

    DELETE FROM public.student_baseline
    WHERE student_name = r.canonical_name;
    UPDATE public.student_baseline
    SET student_name = r.canonical_name
    WHERE student_name = r.raw_name;

    DELETE FROM public.student_score_history AS target
    USING public.student_score_history AS source
    WHERE source.student_name = r.raw_name
      AND target.student_name = r.canonical_name
      AND target.snapshot_date = source.snapshot_date;
    UPDATE public.student_score_history
    SET student_name = r.canonical_name
    WHERE student_name = r.raw_name;

    DELETE FROM public.student_coins
    WHERE student_name = r.canonical_name;
    UPDATE public.student_coins
    SET student_name = r.canonical_name
    WHERE student_name = r.raw_name;

    DELETE FROM public.weekly_coin_reward_detail AS target
    USING public.weekly_coin_reward_detail AS source
    WHERE source.student_name = r.raw_name
      AND target.student_name = r.canonical_name
      AND target.week_monday = source.week_monday
      AND target.board = source.board
      AND target.rank_no = source.rank_no;
    UPDATE public.weekly_coin_reward_detail
    SET student_name = r.canonical_name
    WHERE student_name = r.raw_name;

    UPDATE public.coin_transactions
    SET student_name = r.canonical_name
    WHERE student_name = r.raw_name;

    UPDATE public.weekly_leaderboard_history
    SET student_name = r.canonical_name
    WHERE student_name = r.raw_name;

    UPDATE public.student_time_slots
    SET student_name = r.canonical_name
    WHERE student_name = r.raw_name;

    UPDATE public.student_time_slots_backup
    SET student_name = r.canonical_name
    WHERE student_name = r.raw_name;

    UPDATE public.weekly_coin_reward_log
    SET summary = REPLACE(summary::TEXT, r.raw_name, r.canonical_name)::JSONB
    WHERE summary::TEXT LIKE '%' || r.raw_name || '%';
  END LOOP;

  UPDATE public.student_schedules AS s
  SET name = m.canonical_name
  FROM _student_schedule_identity AS m
  JOIN public.student_database AS sd ON sd.name = m.canonical_name
  WHERE s.id::TEXT = m.schedule_id
    AND s.name IS DISTINCT FROM m.canonical_name;

  PERFORM set_config('app.skip_score_trigger', 'off', true);

  UPDATE public.student_schedules AS s
  SET grade = COALESCE(sd.grade, ''),
      major = COALESCE(sd.major, '')
  FROM public.student_database AS sd
  WHERE s.name = sd.name;

  FOR v_name IN
    SELECT s.name
    FROM public.student_schedules AS s
    GROUP BY s.name
    HAVING COUNT(*) > 1
  LOOP
    INSERT INTO _student_schedule_affected(name) VALUES (v_name) ON CONFLICT DO NOTHING;

    SELECT s.id::TEXT
    INTO v_keeper_id
    FROM public.student_schedules AS s
    WHERE s.name = v_name
    ORDER BY s.updated_at DESC NULLS LAST, s.id::TEXT
    LIMIT 1;

    v_cells := '{}'::JSONB;
    v_max_revision := 1;
    v_max_updated := NULL;
    FOR r IN
      SELECT s.cells, s.revision, s.updated_at
      FROM public.student_schedules AS s
      WHERE s.name = v_name
      ORDER BY s.updated_at ASC NULLS FIRST, s.id::TEXT
    LOOP
      v_cells := v_cells || COALESCE(r.cells, '{}'::JSONB);
      v_max_revision := GREATEST(v_max_revision, COALESCE(r.revision, 1));
      IF r.updated_at IS NOT NULL
         AND (v_max_updated IS NULL OR r.updated_at > v_max_updated) THEN
        v_max_updated := r.updated_at;
      END IF;
    END LOOP;

    UPDATE public.student_schedules
    SET cells = v_cells,
        revision = v_max_revision,
        updated_at = COALESCE(v_max_updated, NOW())
    WHERE id::TEXT = v_keeper_id;

    DELETE FROM public.student_schedules
    WHERE name = v_name
      AND id::TEXT <> v_keeper_id;
  END LOOP;

  DELETE FROM public.student_schedules AS s
  WHERE NOT EXISTS (
    SELECT 1 FROM public.student_database AS sd WHERE sd.name = s.name
  );

  UPDATE public.rooms AS room_row
  SET occupant_student_name = NULL,
      register_time = NULL
  WHERE room_row.occupant_student_name IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.student_database AS sd WHERE sd.name = room_row.occupant_student_name
    );

  DELETE FROM public.practice_logs AS p
  WHERE p.student_name IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.student_database AS sd WHERE sd.name = p.student_name);
  DELETE FROM public.practice_sessions AS p
  WHERE p.student_name IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.student_database AS sd WHERE sd.name = p.student_name);
  DELETE FROM public.practice_alerts AS p
  WHERE p.student_name IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.student_database AS sd WHERE sd.name = p.student_name);
  DELETE FROM public.student_baseline AS p
  WHERE p.student_name IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.student_database AS sd WHERE sd.name = p.student_name);
  DELETE FROM public.student_score_history AS p
  WHERE p.student_name IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.student_database AS sd WHERE sd.name = p.student_name);
  DELETE FROM public.student_coins AS p
  WHERE p.student_name IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.student_database AS sd WHERE sd.name = p.student_name);
  DELETE FROM public.coin_transactions AS p
  WHERE p.student_name IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.student_database AS sd WHERE sd.name = p.student_name);
  DELETE FROM public.weekly_coin_reward_detail AS p
  WHERE p.student_name IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.student_database AS sd WHERE sd.name = p.student_name);
  DELETE FROM public.weekly_leaderboard_history AS p
  WHERE p.student_name IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.student_database AS sd WHERE sd.name = p.student_name);
  DELETE FROM public.student_time_slots AS p
  WHERE p.student_name IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.student_database AS sd WHERE sd.name = p.student_name);
  DELETE FROM public.student_time_slots_backup AS p
  WHERE NOT EXISTS (SELECT 1 FROM public.student_database AS sd WHERE sd.name = p.student_name);

  FOR r IN
    SELECT affected.name, s.cells
    FROM _student_schedule_affected AS affected
    JOIN public.student_schedules AS s ON s.name = affected.name
  LOOP
    PERFORM public._rebuild_student_schedule_slots(r.name, r.cells);
  END LOOP;

  CREATE UNIQUE INDEX IF NOT EXISTS student_schedules_name_key
    ON public.student_schedules(name);
END;
$migration$;

CREATE OR REPLACE FUNCTION public.sync_student_name_references()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_old_name TEXT := NULLIF(BTRIM(OLD.name), '');
  v_new_name TEXT := NULLIF(BTRIM(NEW.name), '');
BEGIN
  IF TG_OP <> 'UPDATE'
     OR v_old_name IS NULL
     OR v_new_name IS NULL
     OR v_old_name = v_new_name THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.student_database AS sd
    WHERE sd.id <> NEW.id
      AND sd.name = v_new_name
  ) THEN
    RAISE EXCEPTION '学生姓名已存在，不能将 % 改名为 %', v_old_name, v_new_name;
  END IF;

  PERFORM set_config('app.skip_score_trigger', 'on', true);

  UPDATE public.rooms
  SET occupant_student_name = v_new_name
  WHERE occupant_student_name = v_old_name;

  UPDATE public.practice_alerts
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  UPDATE public.practice_logs
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  DELETE FROM public.practice_sessions AS target
  USING public.practice_sessions AS source
  WHERE source.student_name = v_old_name
    AND target.student_name = v_new_name
    AND target.session_start = source.session_start;
  UPDATE public.practice_sessions
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  DELETE FROM public.student_baseline
  WHERE student_name = v_new_name;
  UPDATE public.student_baseline
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  DELETE FROM public.student_score_history AS target
  USING public.student_score_history AS source
  WHERE source.student_name = v_old_name
    AND target.student_name = v_new_name
    AND target.snapshot_date = source.snapshot_date;
  UPDATE public.student_score_history
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  DELETE FROM public.student_coins
  WHERE student_name = v_new_name;
  UPDATE public.student_coins
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  DELETE FROM public.weekly_coin_reward_detail AS target
  USING public.weekly_coin_reward_detail AS source
  WHERE source.student_name = v_old_name
    AND target.student_name = v_new_name
    AND target.week_monday = source.week_monday
    AND target.board = source.board
    AND target.rank_no = source.rank_no;
  UPDATE public.weekly_coin_reward_detail
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  UPDATE public.coin_transactions
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  UPDATE public.weekly_leaderboard_history
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  UPDATE public.student_time_slots
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  UPDATE public.student_time_slots_backup
  SET student_name = v_new_name
  WHERE student_name = v_old_name;

  UPDATE public.weekly_coin_reward_log
  SET summary = REPLACE(summary::TEXT, v_old_name, v_new_name)::JSONB
  WHERE summary::TEXT LIKE '%' || v_old_name || '%';

  UPDATE public.student_schedules
  SET name = v_new_name
  WHERE name = v_old_name;

  PERFORM set_config('app.skip_score_trigger', 'off', true);
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_student_profile_metadata()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_old_name TEXT := NULLIF(BTRIM(OLD.name), '');
  v_new_name TEXT := NULLIF(BTRIM(NEW.name), '');
BEGIN
  IF TG_OP <> 'UPDATE'
     OR (OLD.name IS NOT DISTINCT FROM NEW.name
         AND OLD.major IS NOT DISTINCT FROM NEW.major
         AND OLD.grade IS NOT DISTINCT FROM NEW.grade) THEN
    RETURN NEW;
  END IF;

  PERFORM set_config('app.skip_score_trigger', 'on', true);

  UPDATE public.practice_sessions
  SET student_major = NEW.major,
      student_grade = NEW.grade
  WHERE student_name IN (v_old_name, v_new_name);

  UPDATE public.practice_logs
  SET student_major = NEW.major,
      student_grade = NEW.grade
  WHERE student_name IN (v_old_name, v_new_name);

  UPDATE public.student_baseline
  SET student_major = NEW.major,
      student_grade = NEW.grade
  WHERE student_name IN (v_old_name, v_new_name);

  PERFORM set_config('app.skip_score_trigger', 'off', true);

  UPDATE public.student_schedules
  SET name = v_new_name,
      major = COALESCE(NEW.major, ''),
      grade = COALESCE(NEW.grade, '')
  WHERE name = v_old_name OR name = v_new_name;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.delete_student_related_records()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM set_config('app.skip_score_trigger', 'on', true);

  UPDATE public.rooms
  SET occupant_student_name = NULL,
      register_time = NULL
  WHERE occupant_student_name = OLD.name;

  DELETE FROM public.practice_alerts WHERE student_name = OLD.name;
  DELETE FROM public.practice_logs WHERE student_name = OLD.name;
  DELETE FROM public.practice_sessions WHERE student_name = OLD.name;
  DELETE FROM public.student_time_slots WHERE student_name = OLD.name;
  DELETE FROM public.student_schedules WHERE name = OLD.name;
  DELETE FROM public.student_time_slots_backup WHERE student_name = OLD.name;
  DELETE FROM public.student_score_history WHERE student_name = OLD.name;
  DELETE FROM public.student_baseline WHERE student_name = OLD.name;
  DELETE FROM public.student_coins WHERE student_name = OLD.name;
  DELETE FROM public.coin_transactions WHERE student_name = OLD.name;
  DELETE FROM public.weekly_coin_reward_detail WHERE student_name = OLD.name;
  DELETE FROM public.weekly_leaderboard_history WHERE student_name = OLD.name;

  PERFORM set_config('app.skip_score_trigger', 'off', true);
  RETURN OLD;
END;
$function$;

DROP TRIGGER IF EXISTS trg_delete_student_related_records ON public.student_database;
CREATE TRIGGER trg_delete_student_related_records
AFTER DELETE ON public.student_database
FOR EACH ROW
EXECUTE FUNCTION public.delete_student_related_records();

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

  SELECT s.id::TEXT AS id, s.name, s.grade, s.major, s.revision, s.updated_at
  INTO current_row
  FROM public.student_schedules AS s
  WHERE s.id::TEXT = p_schedule_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到学生课表: %', p_schedule_id;
  END IF;

  IF p_expected_revision IS NOT NULL AND current_row.revision <> p_expected_revision THEN
    RAISE EXCEPTION '课表已被其他人修改，请刷新后重试' USING ERRCODE = '40001';
  END IF;

  UPDATE public.student_schedules
  SET cells = p_cells,
      revision = current_row.revision + 1,
      updated_at = NOW()
  WHERE id::TEXT = current_row.id
  RETURNING id::TEXT AS id, name, grade, major, cells, revision, updated_at
  INTO saved_row;

  PERFORM public._rebuild_student_schedule_slots(saved_row.name, saved_row.cells);

  RETURN jsonb_build_object(
    'id', saved_row.id,
    'name', saved_row.name,
    'grade', saved_row.grade,
    'major', saved_row.major,
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
BEGIN
  RETURN public.upsert_student_schedule(p_schedule_id, p_name, p_grade, NULL, p_cells);
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_student_schedule(
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
  current_row RECORD;
  saved_row RECORD;
  v_name TEXT := public.canonical_student_name(p_name);
  v_profile_grade TEXT;
  v_profile_major TEXT;
BEGIN
  IF p_cells IS NULL OR jsonb_typeof(p_cells) <> 'object' THEN
    RAISE EXCEPTION '课表 cells 必须是 JSON 对象';
  END IF;

  SELECT COALESCE(sd.grade, ''), COALESCE(sd.major, '')
  INTO v_profile_grade, v_profile_major
  FROM public.student_database AS sd
  WHERE sd.name = v_name
    AND COALESCE(sd.archived, FALSE) = FALSE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION '学生库中不存在学生“%”，请先在学生库创建后再保存课表', v_name;
  END IF;

  SELECT s.id::TEXT AS id, s.name, s.grade, s.major, s.revision
  INTO current_row
  FROM public.student_schedules AS s
  WHERE s.id::TEXT = p_schedule_id
     OR s.name = v_name
     OR public.canonical_student_name(s.name) = v_name
  ORDER BY (s.id::TEXT = p_schedule_id) DESC, (s.name = v_name) DESC, s.updated_at DESC NULLS LAST
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    IF current_row.name IS DISTINCT FROM v_name THEN
      UPDATE public.student_time_slots
      SET student_name = v_name
      WHERE student_name = current_row.name;
    END IF;

    UPDATE public.student_schedules
    SET name = v_name,
        grade = v_profile_grade,
        major = v_profile_major,
        cells = p_cells,
        revision = current_row.revision + 1,
        updated_at = NOW()
    WHERE id::TEXT = current_row.id;
  ELSE
    INSERT INTO public.student_schedules (id, name, grade, major, cells, revision, updated_at)
    VALUES (p_schedule_id, v_name, v_profile_grade, v_profile_major, p_cells, 1, NOW());
  END IF;

  SELECT s.id::TEXT AS id, s.name, s.grade, s.major, s.cells, s.revision, s.updated_at
  INTO saved_row
  FROM public.student_schedules AS s
  WHERE s.name = v_name
  LIMIT 1;

  PERFORM public._rebuild_student_schedule_slots(saved_row.name, saved_row.cells);

  RETURN jsonb_build_object(
    'id', saved_row.id,
    'name', saved_row.name,
    'grade', saved_row.grade,
    'major', saved_row.major,
    'cells', saved_row.cells,
    'revision', saved_row.revision,
    'updated_at', saved_row.updated_at
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.save_student_schedule(TEXT, BIGINT, JSONB) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_student_schedule(TEXT, TEXT, TEXT, JSONB) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_student_schedule(TEXT, TEXT, TEXT, TEXT, JSONB) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.canonical_student_name(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.student_major_from_identity(TEXT) FROM PUBLIC;
