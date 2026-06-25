-- Daily energy refill:
-- - Student max_energy defaults to 10 unless teacher overrides.
-- - Every day at midnight (Asia/Shanghai), energy refills to max_energy regardless of remaining energy.
--
-- Implementation notes:
-- - Uses lazy refresh: the refill is applied on the first backend interaction each day (login/load/save/grant/consume).
-- - Avoids requiring pg_cron availability in every Supabase project.

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS last_energy_refilled_on DATE;
-- Keep student defaults consistent (teacher overrides remain untouched).
ALTER TABLE users
  ALTER COLUMN max_energy SET DEFAULT 10;
UPDATE users
SET max_energy = GREATEST(COALESCE(max_energy, 10), 0)
WHERE role = 'student';
UPDATE users
SET last_energy_refilled_on = COALESCE(last_energy_refilled_on, (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE)
WHERE role = 'student';
DROP FUNCTION IF EXISTS energy_today_cn();
CREATE OR REPLACE FUNCTION energy_today_cn()
RETURNS DATE
LANGUAGE sql
STABLE
AS $$
  SELECT (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
$$;
GRANT EXECUTE ON FUNCTION energy_today_cn() TO anon, authenticated;
DROP FUNCTION IF EXISTS refresh_daily_energy(UUID);
CREATE OR REPLACE FUNCTION refresh_daily_energy(
  p_user_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_today DATE := energy_today_cn();
  v_energy_before INT;
  v_energy_after INT;
  v_max_energy INT;
  v_last_refill DATE;
  v_delta INT;
BEGIN
  SELECT energy, max_energy, last_energy_refilled_on
  INTO v_energy_before, v_max_energy, v_last_refill
  FROM users
  WHERE id = p_user_id
  AND role = 'student'
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'Student not found');
  END IF;

  v_energy_before := GREATEST(COALESCE(v_energy_before, 0), 0);
  v_max_energy := GREATEST(COALESCE(v_max_energy, 10), 0, v_energy_before);
  v_last_refill := COALESCE(v_last_refill, v_today);

  IF v_last_refill >= v_today THEN
    RETURN json_build_object(
      'ok', true,
      'refilled', false,
      'energy', v_energy_before,
      'max_energy', v_max_energy,
      'today', v_today
    );
  END IF;

  v_energy_after := v_max_energy;
  v_delta := v_energy_after - v_energy_before;

  UPDATE users
  SET energy = v_energy_after,
      max_energy = v_max_energy,
      last_energy_refilled_on = v_today
  WHERE id = p_user_id;

  IF v_delta <> 0 THEN
    INSERT INTO energy_logs (student_id, amount, reason, energy_after, max_energy_after)
    VALUES (p_user_id, v_delta, '每日能量刷新', v_energy_after, v_max_energy);
  END IF;

  RETURN json_build_object(
    'ok', true,
    'refilled', true,
    'energy', v_energy_after,
    'max_energy', v_max_energy,
    'today', v_today
  );
END;
$$;
GRANT EXECUTE ON FUNCTION refresh_daily_energy(UUID) TO anon, authenticated;
-- Ensure login/load/save paths apply the daily refill.

CREATE OR REPLACE FUNCTION login_with_table_password(
  p_username TEXT,
  p_password TEXT
)
RETURNS TABLE (
  id UUID,
  email TEXT,
  username TEXT,
  nickname TEXT,
  role TEXT,
  teacher_id UUID,
  gold INT,
  energy INT,
  max_energy INT,
  registration_status TEXT,
  registration_rejection_reason TEXT,
  registration_requested_at TIMESTAMP WITH TIME ZONE,
  registration_reviewed_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
BEGIN
  IF NULLIF(TRIM(p_username), '') IS NULL OR p_password IS NULL THEN
    RETURN;
  END IF;

  SELECT u.id
  INTO v_user_id
  FROM users u
  WHERE TRIM(u.username) = TRIM(p_username)
  AND COALESCE(TRIM(u.plain_password), '') = TRIM(p_password)
  ORDER BY
    CASE WHEN u.username = p_username THEN 0 ELSE 1 END,
    u.created_at DESC
  LIMIT 1;

  IF v_user_id IS NOT NULL THEN
    PERFORM refresh_daily_energy(v_user_id);
  END IF;

  RETURN QUERY
  SELECT
    u.id,
    u.email,
    u.username,
    u.nickname,
    u.role,
    u.teacher_id,
    u.gold,
    u.energy,
    u.max_energy,
    COALESCE(u.registration_status, 'approved') AS registration_status,
    u.registration_rejection_reason,
    u.registration_requested_at,
    u.registration_reviewed_at,
    u.created_at
  FROM users u
  WHERE u.id = v_user_id
  LIMIT 1;
END;
$$;
GRANT EXECUTE ON FUNCTION login_with_table_password(TEXT, TEXT) TO anon, authenticated;
DROP FUNCTION IF EXISTS load_cloud_game_state_with_resources(UUID);
CREATE OR REPLACE FUNCTION load_cloud_game_state_with_resources(
  p_user_id UUID
)
RETURNS TABLE (
  game_data JSONB,
  last_saved TIMESTAMP WITH TIME ZONE,
  save_revision BIGINT,
  gold INT,
  energy INT,
  max_energy INT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM users
    WHERE id = p_user_id
    AND role = 'student'
  ) THEN
    RAISE EXCEPTION 'Student not found';
  END IF;

  PERFORM refresh_daily_energy(p_user_id);

  RETURN QUERY
  SELECT
    gs.game_data,
    gs.last_saved,
    COALESCE(gs.save_revision, 0),
    COALESCE(u.gold, 0),
    COALESCE(u.energy, 0),
    COALESCE(u.max_energy, 0)
  FROM users u
  LEFT JOIN game_saves gs ON gs.user_id = u.id
  WHERE u.id = p_user_id
  AND u.role = 'student';
END;
$$;
GRANT EXECUTE ON FUNCTION load_cloud_game_state_with_resources(UUID) TO anon, authenticated;
-- Re-define save_cloud_game_state_with_resources to apply daily energy refill before energy delta checks.
DROP FUNCTION IF EXISTS save_cloud_game_state_with_resources(UUID, JSONB, INT, TEXT, INT, TEXT);
CREATE OR REPLACE FUNCTION save_cloud_game_state_with_resources(
  p_user_id UUID,
  p_game_data JSONB,
  p_gold_delta INT DEFAULT 0,
  p_gold_reason TEXT DEFAULT '游戏金币变动',
  p_energy_delta INT DEFAULT 0,
  p_energy_reason TEXT DEFAULT '能量变动'
)
RETURNS TABLE (
  game_data JSONB,
  last_saved TIMESTAMP WITH TIME ZONE,
  save_revision BIGINT,
  accepted BOOLEAN,
  error_message TEXT,
  gold_after INT,
  energy_after INT,
  max_energy_after INT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_saved_at TIMESTAMP WITH TIME ZONE := NOW();
  v_force_boss_completion BOOLEAN := p_gold_delta > 0
    AND COALESCE(p_game_data #>> '{battleKind}', '') = 'trainer';
  v_game_data JSONB := apply_configured_boss_completion_to_game_data(p_game_data, v_force_boss_completion);
  v_existing_game_data JSONB;
  v_existing_last_saved TIMESTAMP WITH TIME ZONE;
  v_existing_revision BIGINT := 0;
  v_incoming_revision BIGINT;
  v_next_revision BIGINT;
  v_has_existing_save BOOLEAN := FALSE;
  v_current_gold INT;
  v_current_energy INT;
  v_max_energy INT;
  v_existing_battle_energy_cost INT := 0;
  v_incoming_battle_energy_cost INT := 0;
  v_is_escape_refund BOOLEAN := FALSE;
  v_next_energy INT;
  v_energy_log_amount INT;
BEGIN
  SELECT gold, energy, max_energy
  INTO v_current_gold, v_current_energy, v_max_energy
  FROM users
  WHERE id = p_user_id
  AND role = 'student'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Student not found';
  END IF;

  -- Apply daily refill under the same lock.
  PERFORM refresh_daily_energy(p_user_id);
  SELECT gold, energy, max_energy
  INTO v_current_gold, v_current_energy, v_max_energy
  FROM users
  WHERE id = p_user_id
  AND role = 'student';

  IF v_game_data #>> '{_sync,revision}' ~ '^[0-9]+$' THEN
    v_incoming_revision := (v_game_data #>> '{_sync,revision}')::BIGINT;
  END IF;

  SELECT gs.game_data, gs.last_saved, COALESCE(gs.save_revision, 0)
  INTO v_existing_game_data, v_existing_last_saved, v_existing_revision
  FROM game_saves gs
  WHERE gs.user_id = p_user_id
  FOR UPDATE;
  v_has_existing_save := FOUND;

  IF v_has_existing_save THEN
    v_game_data := preserve_game_data_world_string_array(v_game_data, v_existing_game_data, 'defeatedBossIds');
    v_game_data := preserve_game_data_world_string_array(v_game_data, v_existing_game_data, 'defeatedTrainerIds');
    v_game_data := preserve_game_data_world_string_array(v_game_data, v_existing_game_data, 'completedChallengeIds');
    v_game_data := preserve_game_data_world_string_array(v_game_data, v_existing_game_data, 'collectedEventIds');
  END IF;

  v_current_gold := COALESCE(v_current_gold, 0);
  v_current_energy := COALESCE(v_current_energy, 0);
  v_max_energy := GREATEST(COALESCE(v_max_energy, 10), v_current_energy, 0);

  IF v_has_existing_save THEN
    v_next_revision := COALESCE(NULLIF(v_incoming_revision, 0), v_existing_revision + 1);

    IF v_next_revision < v_existing_revision THEN
      RETURN QUERY SELECT v_existing_game_data, v_existing_last_saved, v_existing_revision, FALSE, '后端拒绝了旧版本存档。', v_current_gold, v_current_energy, v_max_energy;
      RETURN;
    END IF;

    IF v_next_revision = v_existing_revision THEN
      IF v_existing_game_data = v_game_data THEN
        RETURN QUERY SELECT v_existing_game_data, v_existing_last_saved, v_existing_revision, TRUE, NULL::TEXT, v_current_gold, v_current_energy, v_max_energy;
      ELSE
        RETURN QUERY SELECT v_existing_game_data, v_existing_last_saved, v_existing_revision, FALSE, '后端拒绝了旧版本存档。', v_current_gold, v_current_energy, v_max_energy;
      END IF;
      RETURN;
    END IF;
  ELSE
    v_next_revision := COALESCE(NULLIF(v_incoming_revision, 0), 1);
  END IF;

  IF v_existing_game_data #>> '{activeBattleEnergyCost}' ~ '^[0-9]+$' THEN
    v_existing_battle_energy_cost := GREATEST((v_existing_game_data #>> '{activeBattleEnergyCost}')::INT, 0);
  END IF;

  IF v_game_data #>> '{activeBattleEnergyCost}' ~ '^[0-9]+$' THEN
    v_incoming_battle_energy_cost := GREATEST((v_game_data #>> '{activeBattleEnergyCost}')::INT, 0);
  END IF;

  v_is_escape_refund :=
    p_energy_delta > 0
    AND p_energy_reason = '逃跑成功退回能量'
    AND v_has_existing_save
    AND COALESCE(v_existing_game_data #>> '{view}', '') = 'battle'
    AND COALESCE(v_existing_game_data #>> '{battleKind}', 'wild') = 'wild'
    AND COALESCE(v_existing_game_data #>> '{battlePhase}', '') = 'escape'
    AND COALESCE(v_existing_game_data #>> '{battleEnergyRefundEligible}', 'false') = 'true'
    AND v_existing_battle_energy_cost >= p_energy_delta
    AND COALESCE(v_game_data #>> '{view}', '') = 'map'
    AND COALESCE(v_game_data #>> '{battleEnergyRefundEligible}', 'false') = 'false'
    AND v_incoming_battle_energy_cost = 0;

  IF p_gold_delta <> 0 AND v_current_gold + p_gold_delta < 0 THEN
    RETURN QUERY SELECT v_existing_game_data, v_existing_last_saved, v_existing_revision, FALSE, '金币不足', v_current_gold, v_current_energy, v_max_energy;
    RETURN;
  END IF;

  IF p_energy_delta > 0 AND NOT v_is_escape_refund THEN
    RETURN QUERY SELECT v_existing_game_data, v_existing_last_saved, v_existing_revision, FALSE, '能量只能由老师恢复或增加', v_current_gold, v_current_energy, v_max_energy;
    RETURN;
  END IF;

  IF p_energy_delta <> 0 AND v_current_energy + p_energy_delta < 0 THEN
    RETURN QUERY SELECT v_existing_game_data, v_existing_last_saved, v_existing_revision, FALSE, '能量不足', v_current_gold, v_current_energy, v_max_energy;
    RETURN;
  END IF;

  IF p_gold_delta <> 0 THEN
    v_current_gold := v_current_gold + p_gold_delta;
    UPDATE users
    SET gold = v_current_gold
    WHERE id = p_user_id;

    INSERT INTO gold_logs (student_id, amount, reason, balance_after)
    VALUES (p_user_id, p_gold_delta, p_gold_reason, v_current_gold);
  END IF;

  IF p_energy_delta <> 0 THEN
    v_next_energy := CASE
      WHEN p_energy_delta > 0 THEN LEAST(v_max_energy, v_current_energy + p_energy_delta)
      ELSE v_current_energy + p_energy_delta
    END;
    v_energy_log_amount := v_next_energy - v_current_energy;
    v_current_energy := v_next_energy;

    UPDATE users
    SET energy = v_current_energy,
        max_energy = v_max_energy
    WHERE id = p_user_id;

    IF v_energy_log_amount <> 0 THEN
      INSERT INTO energy_logs (student_id, amount, reason, energy_after, max_energy_after)
      VALUES (p_user_id, v_energy_log_amount, p_energy_reason, v_current_energy, v_max_energy);
    END IF;
  END IF;

  IF v_has_existing_save THEN
    UPDATE game_saves gs
    SET game_data = v_game_data,
        last_saved = v_saved_at,
        save_revision = v_next_revision
    WHERE gs.user_id = p_user_id
    RETURNING gs.game_data, gs.last_saved, gs.save_revision
    INTO v_existing_game_data, v_existing_last_saved, v_existing_revision;

    RETURN QUERY SELECT v_existing_game_data, v_existing_last_saved, v_existing_revision, TRUE, NULL::TEXT, v_current_gold, v_current_energy, v_max_energy;
    RETURN;
  END IF;

  INSERT INTO game_saves (user_id, game_data, last_saved, save_revision)
  VALUES (p_user_id, v_game_data, v_saved_at, v_next_revision)
  RETURNING game_saves.game_data, game_saves.last_saved, game_saves.save_revision
  INTO v_existing_game_data, v_existing_last_saved, v_existing_revision;

  RETURN QUERY SELECT v_existing_game_data, v_existing_last_saved, v_existing_revision, TRUE, NULL::TEXT, v_current_gold, v_current_energy, v_max_energy;
END;
$$;
GRANT EXECUTE ON FUNCTION save_cloud_game_state_with_resources(UUID, JSONB, INT, TEXT, INT, TEXT) TO anon, authenticated;
NOTIFY pgrst, 'reload schema';
-- Keep profile/resource reads consistent (login isn't the only place the client fetches energy).

DROP FUNCTION IF EXISTS get_table_user_profile(UUID);
CREATE OR REPLACE FUNCTION get_table_user_profile(
  p_user_id UUID
)
RETURNS TABLE (
  id UUID,
  email TEXT,
  username TEXT,
  nickname TEXT,
  role TEXT,
  teacher_id UUID,
  gold INT,
  energy INT,
  max_energy INT,
  registration_status TEXT,
  registration_rejection_reason TEXT,
  registration_requested_at TIMESTAMP WITH TIME ZONE,
  registration_reviewed_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_role TEXT;
BEGIN
  SELECT u.role INTO v_role
  FROM users u
  WHERE u.id = p_user_id
  LIMIT 1;

  IF v_role = 'student' THEN
    PERFORM refresh_daily_energy(p_user_id);
  END IF;

  RETURN QUERY
  SELECT
    u.id,
    u.email,
    u.username,
    u.nickname,
    u.role,
    u.teacher_id,
    u.gold,
    u.energy,
    u.max_energy,
    COALESCE(u.registration_status, 'approved') AS registration_status,
    u.registration_rejection_reason,
    u.registration_requested_at,
    u.registration_reviewed_at,
    u.created_at
  FROM users u
  WHERE u.id = p_user_id
  LIMIT 1;
END;
$$;
GRANT EXECUTE ON FUNCTION get_table_user_profile(UUID) TO anon, authenticated;
DROP FUNCTION IF EXISTS get_user_resources(UUID);
CREATE OR REPLACE FUNCTION get_user_resources(
  p_user_id UUID
)
RETURNS TABLE (
  gold INT,
  energy INT,
  max_energy INT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  PERFORM refresh_daily_energy(p_user_id);

  RETURN QUERY
  SELECT
    COALESCE(u.gold, 0),
    COALESCE(u.energy, 0),
    COALESCE(u.max_energy, 0)
  FROM users u
  WHERE u.id = p_user_id
    AND u.role = 'student'
  LIMIT 1;
END;
$$;
GRANT EXECUTE ON FUNCTION get_user_resources(UUID) TO anon, authenticated;
-- Optional: true midnight refill (Asia/Shanghai) via pg_cron if available.
-- Runs at 16:00 UTC which is 00:00 Asia/Shanghai.

DROP FUNCTION IF EXISTS refresh_all_students_daily_energy();
CREATE OR REPLACE FUNCTION refresh_all_students_daily_energy()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_today DATE := energy_today_cn();
  v_updated INT := 0;
BEGIN
  WITH candidates AS (
    SELECT id, GREATEST(COALESCE(energy, 0), 0) AS energy_before, GREATEST(COALESCE(max_energy, 10), 0) AS max_energy
    FROM users
    WHERE role = 'student'
    AND COALESCE(last_energy_refilled_on, DATE '1900-01-01') < v_today
  ),
  updated AS (
    UPDATE users u
    SET energy = u.max_energy,
        last_energy_refilled_on = v_today
    FROM candidates c
    WHERE u.id = c.id
    RETURNING u.id, c.energy_before, u.max_energy
  )
  INSERT INTO energy_logs (student_id, amount, reason, energy_after, max_energy_after)
  SELECT
    u.id,
    (u.max_energy - u.energy_before),
    '每日能量刷新',
    u.max_energy,
    u.max_energy
  FROM updated u
  WHERE (u.max_energy - u.energy_before) <> 0;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END;
$$;
GRANT EXECUTE ON FUNCTION refresh_all_students_daily_energy() TO anon, authenticated;
DO $daily_energy_refill$
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron extension unavailable; daily energy refill will be applied lazily on first interaction each day.';
    RETURN;
  END;

  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE NOTICE 'pg_cron extension not enabled; daily energy refill will be applied lazily on first interaction each day.';
    RETURN;
  END IF;

  -- Best-effort: schedule job if not already present.
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'daily-energy-refill-cn') THEN
    PERFORM cron.schedule(
      'daily-energy-refill-cn',
      '0 16 * * *',
      $$SELECT refresh_all_students_daily_energy();$$
    );
  END IF;
END;
$daily_energy_refill$;
