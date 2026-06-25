-- Ensure configured boss victories cannot be lost by a late or partial client-side
-- save. When a trainer battle reaches the victory phase and carries a boss event
-- identity, the backend appends the map-scoped boss id before persisting.

CREATE OR REPLACE FUNCTION apply_configured_boss_completion_to_game_data(
  p_game_data JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_battle_phase TEXT;
  v_event_type TEXT;
  v_event_id TEXT;
  v_map_name TEXT;
  v_scoped_id TEXT;
  v_world JSONB;
  v_defeated_boss_ids JSONB;
  v_enemy_team JSONB;
  v_enemy_count INT := 0;
  v_remaining_enemy_count INT := 0;
  v_is_completed_boss_save BOOLEAN := FALSE;
BEGIN
  IF p_game_data IS NULL THEN
    RETURN p_game_data;
  END IF;

  IF COALESCE(p_game_data #>> '{battleKind}', '') <> 'trainer' THEN
    RETURN p_game_data;
  END IF;

  v_battle_phase := COALESCE(p_game_data #>> '{battlePhase}', '');

  v_event_type := COALESCE(
    NULLIF(p_game_data #>> '{battleEventCompletion,eventType}', ''),
    NULLIF(p_game_data #>> '{battleEnvironment,battleEventCompletion,eventType}', ''),
    NULLIF(p_game_data #>> '{battlePhaseData,battleEventCompletion,eventType}', ''),
    NULLIF(p_game_data #>> '{battleEnvironment,eventType}', ''),
    NULLIF(p_game_data #>> '{battlePhaseData,battleEnvironment,eventType}', '')
  );
  v_event_id := COALESCE(
    NULLIF(p_game_data #>> '{battleEventCompletion,eventId}', ''),
    NULLIF(p_game_data #>> '{battleEnvironment,battleEventCompletion,eventId}', ''),
    NULLIF(p_game_data #>> '{battlePhaseData,battleEventCompletion,eventId}', ''),
    NULLIF(p_game_data #>> '{battleEnvironment,eventId}', ''),
    NULLIF(p_game_data #>> '{battlePhaseData,battleEnvironment,eventId}', '')
  );
  v_map_name := COALESCE(
    NULLIF(p_game_data #>> '{battleEventCompletion,mapName}', ''),
    NULLIF(p_game_data #>> '{battleEnvironment,battleEventCompletion,mapName}', ''),
    NULLIF(p_game_data #>> '{battlePhaseData,battleEventCompletion,mapName}', ''),
    NULLIF(p_game_data #>> '{battleEnvironment,mapName}', ''),
    NULLIF(p_game_data #>> '{battlePhaseData,battleEnvironment,mapName}', ''),
    NULLIF(p_game_data #>> '{world,currentMapName}', ''),
    NULLIF(p_game_data #>> '{currentMapName}', '')
  );

  IF v_event_type <> 'boss' OR v_event_id IS NULL OR v_map_name IS NULL THEN
    RETURN p_game_data;
  END IF;

  v_enemy_team := CASE
    WHEN jsonb_typeof(p_game_data -> 'enemyTeam') = 'array' THEN p_game_data -> 'enemyTeam'
    ELSE '[]'::JSONB
  END;

  SELECT
    COUNT(*)::INT,
    COUNT(*) FILTER (
      WHERE (
        CASE
          WHEN enemy ->> 'currentHp' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (enemy ->> 'currentHp')::NUMERIC
          WHEN enemy ->> 'hp' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (enemy ->> 'hp')::NUMERIC
          ELSE 1
        END
      ) > 0
    )::INT
  INTO v_enemy_count, v_remaining_enemy_count
  FROM jsonb_array_elements(v_enemy_team) AS enemy;

  v_is_completed_boss_save := (
    v_battle_phase = 'victory'
    OR (v_enemy_count > 0 AND v_remaining_enemy_count = 0)
  );

  IF NOT v_is_completed_boss_save THEN
    RETURN p_game_data;
  END IF;

  v_scoped_id := v_map_name || ':' || v_event_id;
  v_world := CASE
    WHEN jsonb_typeof(p_game_data -> 'world') = 'object' THEN p_game_data -> 'world'
    ELSE '{}'::JSONB
  END;
  v_defeated_boss_ids := CASE
    WHEN jsonb_typeof(v_world -> 'defeatedBossIds') = 'array' THEN v_world -> 'defeatedBossIds'
    ELSE '[]'::JSONB
  END;

  IF NOT (v_defeated_boss_ids ? v_scoped_id) AND NOT (v_defeated_boss_ids ? v_event_id) THEN
    v_defeated_boss_ids := v_defeated_boss_ids || to_jsonb(v_scoped_id);
  END IF;

  v_world := jsonb_set(v_world, '{defeatedBossIds}', v_defeated_boss_ids, TRUE);
  RETURN jsonb_set(p_game_data, '{world}', v_world, TRUE);
END;
$$;
DROP FUNCTION IF EXISTS save_cloud_game_save(UUID, JSONB);
CREATE OR REPLACE FUNCTION save_cloud_game_save(
  p_user_id UUID,
  p_game_data JSONB
)
RETURNS TABLE (
  game_data JSONB,
  last_saved TIMESTAMP WITH TIME ZONE,
  save_revision BIGINT,
  accepted BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_saved_at TIMESTAMP WITH TIME ZONE := NOW();
  v_game_data JSONB := apply_configured_boss_completion_to_game_data(p_game_data);
  v_existing_game_data JSONB;
  v_existing_last_saved TIMESTAMP WITH TIME ZONE;
  v_existing_revision BIGINT := 0;
  v_incoming_revision BIGINT;
  v_next_revision BIGINT;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM users
    WHERE id = p_user_id
    AND role = 'student'
  ) THEN
    RAISE EXCEPTION 'Student not found';
  END IF;

  IF v_game_data #>> '{_sync,revision}' ~ '^[0-9]+$' THEN
    v_incoming_revision := (v_game_data #>> '{_sync,revision}')::BIGINT;
  END IF;

  SELECT gs.game_data, gs.last_saved, COALESCE(gs.save_revision, 0)
  INTO v_existing_game_data, v_existing_last_saved, v_existing_revision
  FROM game_saves gs
  WHERE gs.user_id = p_user_id
  FOR UPDATE;

  IF FOUND THEN
    v_next_revision := COALESCE(NULLIF(v_incoming_revision, 0), v_existing_revision + 1);

    IF v_next_revision < v_existing_revision THEN
      RETURN QUERY SELECT v_existing_game_data, v_existing_last_saved, v_existing_revision, FALSE;
      RETURN;
    END IF;

    IF v_next_revision = v_existing_revision THEN
      IF v_existing_game_data = v_game_data THEN
        RETURN QUERY SELECT v_existing_game_data, v_existing_last_saved, v_existing_revision, TRUE;
      ELSE
        RETURN QUERY SELECT v_existing_game_data, v_existing_last_saved, v_existing_revision, FALSE;
      END IF;
      RETURN;
    END IF;

    UPDATE game_saves gs
    SET game_data = v_game_data,
        last_saved = v_saved_at,
        save_revision = v_next_revision
    WHERE gs.user_id = p_user_id
    RETURNING gs.game_data, gs.last_saved, gs.save_revision
    INTO v_existing_game_data, v_existing_last_saved, v_existing_revision;

    RETURN QUERY SELECT v_existing_game_data, v_existing_last_saved, v_existing_revision, TRUE;
    RETURN;
  END IF;

  v_next_revision := COALESCE(NULLIF(v_incoming_revision, 0), 1);

  INSERT INTO game_saves (user_id, game_data, last_saved, save_revision)
  VALUES (p_user_id, v_game_data, v_saved_at, v_next_revision)
  RETURNING game_saves.game_data, game_saves.last_saved, game_saves.save_revision
  INTO v_existing_game_data, v_existing_last_saved, v_existing_revision;

  RETURN QUERY SELECT v_existing_game_data, v_existing_last_saved, v_existing_revision, TRUE;
END;
$$;
GRANT EXECUTE ON FUNCTION save_cloud_game_save(UUID, JSONB) TO anon, authenticated;
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
  v_game_data JSONB := apply_configured_boss_completion_to_game_data(p_game_data);
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

  IF v_game_data #>> '{_sync,revision}' ~ '^[0-9]+$' THEN
    v_incoming_revision := (v_game_data #>> '{_sync,revision}')::BIGINT;
  END IF;

  SELECT gs.game_data, gs.last_saved, COALESCE(gs.save_revision, 0)
  INTO v_existing_game_data, v_existing_last_saved, v_existing_revision
  FROM game_saves gs
  WHERE gs.user_id = p_user_id
  FOR UPDATE;
  v_has_existing_save := FOUND;

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
