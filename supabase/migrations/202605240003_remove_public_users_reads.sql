DROP POLICY IF EXISTS "Public read access for auth" ON users;
DROP FUNCTION IF EXISTS get_table_user_profile(UUID);
DROP FUNCTION IF EXISTS get_user_resources(UUID);
DROP FUNCTION IF EXISTS get_teacher_students(UUID);
DROP FUNCTION IF EXISTS get_teacher_pending_students(UUID);
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
BEGIN
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
CREATE OR REPLACE FUNCTION get_teacher_students(
  p_teacher_id UUID
)
RETURNS TABLE (
  id UUID,
  username TEXT,
  nickname TEXT,
  gold INT,
  energy INT,
  max_energy INT,
  created_at TIMESTAMP WITH TIME ZONE,
  registration_status TEXT,
  registration_requested_at TIMESTAMP WITH TIME ZONE,
  registration_reviewed_at TIMESTAMP WITH TIME ZONE,
  registration_rejection_reason TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM users
    WHERE id = p_teacher_id
      AND role = 'teacher'
      AND COALESCE(registration_status, 'approved') = 'approved'
  ) THEN
    RAISE EXCEPTION 'Teacher role required';
  END IF;

  RETURN QUERY
  SELECT
    u.id,
    u.username,
    u.nickname,
    u.gold,
    u.energy,
    u.max_energy,
    u.created_at,
    COALESCE(u.registration_status, 'approved') AS registration_status,
    u.registration_requested_at,
    u.registration_reviewed_at,
    u.registration_rejection_reason
  FROM users u
  WHERE u.role = 'student'
    AND u.teacher_id = p_teacher_id
    AND (u.registration_status IS NULL OR u.registration_status = 'approved')
  ORDER BY u.nickname, u.created_at;
END;
$$;
GRANT EXECUTE ON FUNCTION get_teacher_students(UUID) TO anon, authenticated;
CREATE OR REPLACE FUNCTION get_teacher_pending_students(
  p_teacher_id UUID
)
RETURNS TABLE (
  id UUID,
  username TEXT,
  nickname TEXT,
  created_at TIMESTAMP WITH TIME ZONE,
  teacher_id UUID,
  registration_status TEXT,
  registration_requested_at TIMESTAMP WITH TIME ZONE
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM users
    WHERE id = p_teacher_id
      AND role = 'teacher'
      AND COALESCE(registration_status, 'approved') = 'approved'
  ) THEN
    RAISE EXCEPTION 'Teacher role required';
  END IF;

  RETURN QUERY
  SELECT
    u.id,
    u.username,
    u.nickname,
    u.created_at,
    u.teacher_id,
    COALESCE(u.registration_status, 'approved') AS registration_status,
    u.registration_requested_at
  FROM users u
  WHERE u.role = 'student'
    AND u.teacher_id = p_teacher_id
    AND u.registration_status = 'pending'
  ORDER BY u.registration_requested_at ASC;
END;
$$;
GRANT EXECUTE ON FUNCTION get_teacher_pending_students(UUID) TO anon, authenticated;
