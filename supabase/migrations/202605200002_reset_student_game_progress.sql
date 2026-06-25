CREATE OR REPLACE FUNCTION clear_cloud_game_save(
  p_user_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_gold INT := 0;
  v_energy INT := 6;
  v_max_energy INT := 10;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM users
    WHERE id = p_user_id
    AND role = 'student'
  ) THEN
    RAISE EXCEPTION 'Student not found';
  END IF;

  DELETE FROM game_saves
  WHERE user_id = p_user_id;

  UPDATE users
  SET gold = 0,
      energy = 6,
      max_energy = 10
  WHERE id = p_user_id
  RETURNING gold, energy, max_energy
  INTO v_gold, v_energy, v_max_energy;

  RETURN json_build_object(
    'success', true,
    'goldAfter', v_gold,
    'energyAfter', v_energy,
    'maxEnergyAfter', v_max_energy
  );
END;
$$;
GRANT EXECUTE ON FUNCTION clear_cloud_game_save(UUID) TO anon, authenticated;
