CREATE OR REPLACE FUNCTION public.canonical_student_name(p_name TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_text TEXT := BTRIM(COALESCE(p_name, ''));
  v_normalized TEXT;
  v_compact TEXT;
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
  v_compact := REGEXP_REPLACE(v_normalized, '[[:space:]]+', '', 'g');
  IF v_compact ~ '^[一-龥·•]+$' THEN
    v_normalized := v_compact;
  END IF;
  RETURN NULLIF(BTRIM(REGEXP_REPLACE(v_normalized, '[[:space:]]+', ' ', 'g')), '');
END;
$function$;

DO $migration$
DECLARE
  group_row RECORD;
  profile_row RECORD;
  keeper_profile_id BIGINT;
  keeper_profile_name TEXT;
  keeper_grade TEXT;
  keeper_major TEXT;
  keeper_archived BOOLEAN;
  schedule_row RECORD;
  schedule_keeper_id TEXT;
  schedule_keeper_cells JSONB;
  schedule_keeper_grade TEXT;
  schedule_keeper_major TEXT;
BEGIN
  PERFORM set_config('app.skip_score_trigger', 'on', true);

  CREATE TEMP TABLE _spaced_student_names (
    raw_name TEXT PRIMARY KEY,
    canonical_name TEXT NOT NULL
  ) ON COMMIT DROP;

  INSERT INTO _spaced_student_names(raw_name, canonical_name)
  SELECT DISTINCT BTRIM(sd.name), public.canonical_student_name(sd.name)
  FROM public.student_database AS sd
  WHERE NULLIF(BTRIM(sd.name), '') IS NOT NULL
    AND public.canonical_student_name(sd.name) IS DISTINCT FROM BTRIM(sd.name);

  FOR group_row IN
    SELECT canonical_name
    FROM _spaced_student_names
    GROUP BY canonical_name
  LOOP
    SELECT sd.id, sd.name, COALESCE(sd.grade, ''), COALESCE(sd.major, ''), COALESCE(sd.archived, FALSE)
    INTO keeper_profile_id, keeper_profile_name, keeper_grade, keeper_major, keeper_archived
    FROM public.student_database AS sd
    WHERE public.canonical_student_name(sd.name) = group_row.canonical_name
    ORDER BY (sd.name = group_row.canonical_name) DESC, sd.updated_at DESC NULLS LAST, sd.id
    LIMIT 1;

    IF keeper_profile_id IS NULL THEN
      CONTINUE;
    END IF;

    SELECT sd.grade, sd.major, COALESCE(sd.archived, FALSE)
    INTO keeper_grade, keeper_major, keeper_archived
    FROM public.student_database AS sd
    WHERE public.canonical_student_name(sd.name) = group_row.canonical_name
    ORDER BY sd.updated_at DESC NULLS LAST, sd.id DESC
    LIMIT 1;

    FOR profile_row IN
      SELECT sd.name
      FROM public.student_database AS sd
      WHERE sd.id <> keeper_profile_id
        AND public.canonical_student_name(sd.name) = group_row.canonical_name
    LOOP
      UPDATE public.rooms
      SET occupant_student_name = group_row.canonical_name
      WHERE occupant_student_name = profile_row.name;

      UPDATE public.practice_alerts
      SET student_name = group_row.canonical_name
      WHERE student_name = profile_row.name;

      UPDATE public.practice_logs
      SET student_name = group_row.canonical_name
      WHERE student_name = profile_row.name;

      DELETE FROM public.practice_sessions AS target
      USING public.practice_sessions AS source
      WHERE source.student_name = profile_row.name
        AND target.student_name = group_row.canonical_name
        AND target.session_start = source.session_start;
      UPDATE public.practice_sessions
      SET student_name = group_row.canonical_name
      WHERE student_name = profile_row.name;

      DELETE FROM public.student_baseline
      WHERE student_name = profile_row.name
        AND EXISTS (SELECT 1 FROM public.student_baseline WHERE student_name = group_row.canonical_name);
      UPDATE public.student_baseline
      SET student_name = group_row.canonical_name
      WHERE student_name = profile_row.name;

      DELETE FROM public.student_score_history AS target
      USING public.student_score_history AS source
      WHERE source.student_name = profile_row.name
        AND target.student_name = group_row.canonical_name
        AND target.snapshot_date = source.snapshot_date;
      UPDATE public.student_score_history
      SET student_name = group_row.canonical_name
      WHERE student_name = profile_row.name;

      DELETE FROM public.student_coins
      WHERE student_name = profile_row.name;

      UPDATE public.coin_transactions
      SET student_name = group_row.canonical_name
      WHERE student_name = profile_row.name;

      DELETE FROM public.weekly_coin_reward_detail AS target
      USING public.weekly_coin_reward_detail AS source
      WHERE source.student_name = profile_row.name
        AND target.student_name = group_row.canonical_name
        AND target.week_monday = source.week_monday
        AND target.board = source.board
        AND target.rank_no = source.rank_no;
      UPDATE public.weekly_coin_reward_detail
      SET student_name = group_row.canonical_name
      WHERE student_name = profile_row.name;

      UPDATE public.weekly_leaderboard_history
      SET student_name = group_row.canonical_name
      WHERE student_name = profile_row.name;

      DELETE FROM public.student_time_slots AS target
      USING public.student_time_slots AS source
      WHERE source.student_name = profile_row.name
        AND target.student_name = group_row.canonical_name
        AND target.weekday = source.weekday
        AND target.start_time = source.start_time
        AND target.end_time = source.end_time;
      UPDATE public.student_time_slots
      SET student_name = group_row.canonical_name
      WHERE student_name = profile_row.name;

      UPDATE public.student_time_slots_backup
      SET student_name = group_row.canonical_name
      WHERE student_name = profile_row.name;
    END LOOP;

    IF keeper_profile_name IS DISTINCT FROM group_row.canonical_name THEN
      UPDATE public.rooms
      SET occupant_student_name = group_row.canonical_name
      WHERE occupant_student_name = keeper_profile_name;

      UPDATE public.practice_alerts
      SET student_name = group_row.canonical_name
      WHERE student_name = keeper_profile_name;

      UPDATE public.practice_logs
      SET student_name = group_row.canonical_name
      WHERE student_name = keeper_profile_name;

      DELETE FROM public.practice_sessions AS target
      USING public.practice_sessions AS source
      WHERE source.student_name = keeper_profile_name
        AND target.student_name = group_row.canonical_name
        AND target.session_start = source.session_start;
      UPDATE public.practice_sessions
      SET student_name = group_row.canonical_name
      WHERE student_name = keeper_profile_name;

      DELETE FROM public.student_baseline
      WHERE student_name = keeper_profile_name
        AND EXISTS (SELECT 1 FROM public.student_baseline WHERE student_name = group_row.canonical_name);
      UPDATE public.student_baseline
      SET student_name = group_row.canonical_name
      WHERE student_name = keeper_profile_name;

      DELETE FROM public.student_score_history AS target
      USING public.student_score_history AS source
      WHERE source.student_name = keeper_profile_name
        AND target.student_name = group_row.canonical_name
        AND target.snapshot_date = source.snapshot_date;
      UPDATE public.student_score_history
      SET student_name = group_row.canonical_name
      WHERE student_name = keeper_profile_name;

      DELETE FROM public.student_coins
      WHERE student_name = keeper_profile_name
        AND EXISTS (SELECT 1 FROM public.student_coins WHERE student_name = group_row.canonical_name);
      UPDATE public.student_coins
      SET student_name = group_row.canonical_name
      WHERE student_name = keeper_profile_name;

      UPDATE public.coin_transactions
      SET student_name = group_row.canonical_name
      WHERE student_name = keeper_profile_name;

      DELETE FROM public.weekly_coin_reward_detail AS target
      USING public.weekly_coin_reward_detail AS source
      WHERE source.student_name = keeper_profile_name
        AND target.student_name = group_row.canonical_name
        AND target.week_monday = source.week_monday
        AND target.board = source.board
        AND target.rank_no = source.rank_no;
      UPDATE public.weekly_coin_reward_detail
      SET student_name = group_row.canonical_name
      WHERE student_name = keeper_profile_name;

      UPDATE public.weekly_leaderboard_history
      SET student_name = group_row.canonical_name
      WHERE student_name = keeper_profile_name;

      DELETE FROM public.student_time_slots AS target
      USING public.student_time_slots AS source
      WHERE source.student_name = keeper_profile_name
        AND target.student_name = group_row.canonical_name
        AND target.weekday = source.weekday
        AND target.start_time = source.start_time
        AND target.end_time = source.end_time;
      UPDATE public.student_time_slots
      SET student_name = group_row.canonical_name
      WHERE student_name = keeper_profile_name;

      UPDATE public.student_time_slots_backup
      SET student_name = group_row.canonical_name
      WHERE student_name = keeper_profile_name;
    END IF;

    UPDATE public.student_database
    SET name = group_row.canonical_name,
        grade = COALESCE(keeper_grade, ''),
        major = COALESCE(keeper_major, ''),
        archived = keeper_archived
    WHERE id = keeper_profile_id;

    DELETE FROM public.student_database
    WHERE id <> keeper_profile_id
      AND public.canonical_student_name(name) = group_row.canonical_name;
  END LOOP;

  CREATE TEMP TABLE _schedule_identity_groups (
    canonical_name TEXT PRIMARY KEY
  ) ON COMMIT DROP;

  INSERT INTO _schedule_identity_groups(canonical_name)
  SELECT public.canonical_student_name(s.name)
  FROM public.student_schedules AS s
  WHERE NULLIF(BTRIM(s.name), '') IS NOT NULL
  GROUP BY public.canonical_student_name(s.name);

  FOR group_row IN SELECT canonical_name FROM _schedule_identity_groups LOOP
    SELECT s.id::TEXT, s.cells, COALESCE(s.grade, ''), COALESCE(s.major, '')
    INTO schedule_keeper_id, schedule_keeper_cells, schedule_keeper_grade, schedule_keeper_major
    FROM public.student_schedules AS s
    WHERE public.canonical_student_name(s.name) = group_row.canonical_name
    ORDER BY s.updated_at DESC NULLS LAST, s.id::TEXT
    LIMIT 1;

    IF schedule_keeper_id IS NULL THEN CONTINUE; END IF;

    DELETE FROM public.student_time_slots
    WHERE public.canonical_student_name(student_name) = group_row.canonical_name;

    UPDATE public.student_schedules
    SET name = '__identity_merge__' || schedule_keeper_id
    WHERE id::TEXT = schedule_keeper_id;

    DELETE FROM public.student_schedules
    WHERE public.canonical_student_name(name) = group_row.canonical_name
      AND id::TEXT <> schedule_keeper_id;

    UPDATE public.student_schedules
    SET name = group_row.canonical_name,
        grade = schedule_keeper_grade,
        major = schedule_keeper_major,
        cells = COALESCE(schedule_keeper_cells, '{}'::JSONB)
    WHERE id::TEXT = schedule_keeper_id;

    PERFORM public._rebuild_student_schedule_slots(group_row.canonical_name, schedule_keeper_cells);
  END LOOP;

  PERFORM set_config('app.skip_score_trigger', 'off', true);
END;
$migration$;

CREATE UNIQUE INDEX IF NOT EXISTS student_database_canonical_name_key
  ON public.student_database(public.canonical_student_name(name));

CREATE UNIQUE INDEX IF NOT EXISTS student_schedules_canonical_name_key
  ON public.student_schedules(public.canonical_student_name(name));
