-- Allow the game to refund energy that was already consumed for a wild battle
-- when the saved battle is in the escape phase. Positive student energy grants
-- are still rejected everywhere else; teachers must use grant_energy.

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

  IF p_game_data #>> '{_sync,revision}' ~ '^[0-9]+$' THEN
    v_incoming_revision := (p_game_data #>> '{_sync,revision}')::BIGINT;
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
      IF v_existing_game_data = p_game_data THEN
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

  IF p_game_data #>> '{activeBattleEnergyCost}' ~ '^[0-9]+$' THEN
    v_incoming_battle_energy_cost := GREATEST((p_game_data #>> '{activeBattleEnergyCost}')::INT, 0);
  END IF;

  v_is_escape_refund :=
    p_energy_delta > 0
    AND p_energy_reason = '逃跑成功退回能量'
    AND v_has_existing_save
    AND COALESCE(v_existing_game_data #>> '{view}', '') = 'battle'
    AND COALESCE(v_existing_game_data #>> '{battleKind}', 'wild') = 'wild'
    AND COALESCE(v_existing_game_data #>> '{battlePhase}', '') = 'escape'
    AND v_existing_battle_energy_cost >= p_energy_delta
    AND COALESCE(p_game_data #>> '{view}', '') = 'map'
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
    SET game_data = p_game_data,
        last_saved = v_saved_at,
        save_revision = v_next_revision
    WHERE gs.user_id = p_user_id
    RETURNING gs.game_data, gs.last_saved, gs.save_revision
    INTO v_existing_game_data, v_existing_last_saved, v_existing_revision;

    RETURN QUERY SELECT v_existing_game_data, v_existing_last_saved, v_existing_revision, TRUE, NULL::TEXT, v_current_gold, v_current_energy, v_max_energy;
    RETURN;
  END IF;

  INSERT INTO game_saves (user_id, game_data, last_saved, save_revision)
  VALUES (p_user_id, p_game_data, v_saved_at, v_next_revision)
  RETURNING game_saves.game_data, game_saves.last_saved, game_saves.save_revision
  INTO v_existing_game_data, v_existing_last_saved, v_existing_revision;

  RETURN QUERY SELECT v_existing_game_data, v_existing_last_saved, v_existing_revision, TRUE, NULL::TEXT, v_current_gold, v_current_energy, v_max_energy;
END;
$$;
GRANT EXECUTE ON FUNCTION save_cloud_game_state_with_resources(UUID, JSONB, INT, TEXT, INT, TEXT) TO anon, authenticated;
NOTIFY pgrst, 'reload schema';
