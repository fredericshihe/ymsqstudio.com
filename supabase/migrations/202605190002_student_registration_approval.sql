ALTER TABLE users ADD COLUMN IF NOT EXISTS registration_status TEXT NOT NULL DEFAULT 'approved' CHECK (registration_status IN ('pending', 'approved', 'rejected'));
ALTER TABLE users ADD COLUMN IF NOT EXISTS registration_requested_at TIMESTAMP WITH TIME ZONE DEFAULT NOW();
ALTER TABLE users ADD COLUMN IF NOT EXISTS registration_reviewed_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS registration_rejection_reason TEXT;
UPDATE users
SET registration_status = 'approved',
    registration_requested_at = COALESCE(registration_requested_at, created_at, NOW()),
    registration_reviewed_at = COALESCE(registration_reviewed_at, created_at, NOW())
WHERE registration_status IS NULL;
CREATE INDEX IF NOT EXISTS idx_users_registration_status ON users(registration_status);
DROP FUNCTION IF EXISTS register_table_user(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS review_student_registration(UUID, UUID, BOOLEAN, TEXT);
DROP FUNCTION IF EXISTS login_with_table_password(TEXT, TEXT);
CREATE OR REPLACE FUNCTION register_table_user(
  p_username TEXT,
  p_password TEXT,
  p_nickname TEXT,
  p_role TEXT,
  p_teacher_username TEXT DEFAULT NULL,
  p_teacher_registration_code TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_username TEXT := TRIM(COALESCE(p_username, ''));
  v_role TEXT := CASE WHEN p_role = 'teacher' THEN 'teacher' ELSE 'student' END;
  v_teacher_id UUID;
  v_profile users%ROWTYPE;
BEGIN
  IF v_username = '' THEN
    RETURN jsonb_build_object('success', false, 'error', '请输入用户名');
  END IF;

  IF LENGTH(TRIM(COALESCE(p_password, ''))) < 6 THEN
    RETURN jsonb_build_object('success', false, 'error', '密码至少6位');
  END IF;

  IF EXISTS (SELECT 1 FROM users WHERE username = v_username) THEN
    RETURN jsonb_build_object('success', false, 'error', '用户名已存在');
  END IF;

  IF v_role = 'teacher' THEN
    IF TRIM(COALESCE(p_teacher_registration_code, '')) <> '198985' THEN
      RETURN jsonb_build_object('success', false, 'error', '老师注册密码不正确，无法创建教师账号');
    END IF;
  ELSE
    SELECT id INTO v_teacher_id
    FROM users
    WHERE username = TRIM(COALESCE(p_teacher_username, ''))
      AND role = 'teacher'
      AND COALESCE(registration_status, 'approved') = 'approved'
    LIMIT 1;

    IF v_teacher_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', '找不到该老师，请检查老师用户名');
    END IF;
  END IF;

  INSERT INTO users (
    email,
    username,
    nickname,
    role,
    teacher_id,
    gold,
    energy,
    max_energy,
    plain_password,
    registration_status,
    registration_requested_at,
    registration_reviewed_at
  )
  VALUES (
    v_username || '@pokemon-game.local',
    v_username,
    NULLIF(TRIM(COALESCE(p_nickname, '')), ''),
    v_role,
    v_teacher_id,
    0,
    CASE WHEN v_role = 'student' THEN 6 ELSE 0 END,
    CASE WHEN v_role = 'student' THEN 10 ELSE 0 END,
    p_password,
    CASE WHEN v_role = 'student' THEN 'pending' ELSE 'approved' END,
    NOW(),
    CASE WHEN v_role = 'teacher' THEN NOW() ELSE NULL END
  )
  RETURNING * INTO v_profile;

  RETURN jsonb_build_object(
    'success', true,
    'pendingApproval', v_role = 'student',
    'message', CASE
      WHEN v_role = 'student' THEN '注册申请已提交，请尽快通知老师登录教师工作台确认。老师通过后，你就可以使用该账号登录。'
      ELSE '注册成功！'
    END,
    'profile', to_jsonb(v_profile)
  );
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('success', false, 'error', '用户名已存在');
END;
$$;
GRANT EXECUTE ON FUNCTION register_table_user(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;
CREATE OR REPLACE FUNCTION review_student_registration(
  p_teacher_id UUID,
  p_student_id UUID,
  p_approved BOOLEAN,
  p_rejection_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_student users%ROWTYPE;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM users
    WHERE id = p_teacher_id
      AND role = 'teacher'
      AND COALESCE(registration_status, 'approved') = 'approved'
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', '只有已通过的老师账号可以审核学生');
  END IF;

  SELECT * INTO v_student
  FROM users
  WHERE id = p_student_id
    AND role = 'student'
    AND teacher_id = p_teacher_id
  LIMIT 1;

  IF v_student.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', '找不到该学生申请');
  END IF;

  UPDATE users
  SET registration_status = CASE WHEN p_approved THEN 'approved' ELSE 'rejected' END,
      registration_reviewed_at = NOW(),
      registration_rejection_reason = CASE WHEN p_approved THEN NULL ELSE NULLIF(TRIM(COALESCE(p_rejection_reason, '')), '') END
  WHERE id = p_student_id;

  RETURN jsonb_build_object(
    'success', true,
    'status', CASE WHEN p_approved THEN 'approved' ELSE 'rejected' END
  );
END;
$$;
GRANT EXECUTE ON FUNCTION review_student_registration(UUID, UUID, BOOLEAN, TEXT) TO anon, authenticated;
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
  plain_password TEXT,
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
  IF NULLIF(TRIM(p_username), '') IS NULL OR p_password IS NULL THEN
    RETURN;
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
    u.plain_password,
    COALESCE(u.registration_status, 'approved') AS registration_status,
    u.registration_rejection_reason,
    u.registration_requested_at,
    u.registration_reviewed_at,
    u.created_at
  FROM users u
  WHERE TRIM(u.username) = TRIM(p_username)
  AND COALESCE(TRIM(u.plain_password), '') = TRIM(p_password)
  ORDER BY
    CASE WHEN u.username = p_username THEN 0 ELSE 1 END,
    u.created_at DESC
  LIMIT 1;
END;
$$;
GRANT EXECUTE ON FUNCTION login_with_table_password(TEXT, TEXT) TO anon, authenticated;
