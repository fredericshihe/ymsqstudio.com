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
