DROP FUNCTION IF EXISTS login_with_table_password(TEXT, TEXT);
DROP FUNCTION IF EXISTS teacher_reset_student_password(UUID, UUID, TEXT);
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
    CASE WHEN v_role = 'student' THEN 500 ELSE 0 END,
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
    'profile', jsonb_build_object(
      'id', v_profile.id,
      'email', v_profile.email,
      'username', v_profile.username,
      'nickname', v_profile.nickname,
      'role', v_profile.role,
      'teacher_id', v_profile.teacher_id,
      'gold', v_profile.gold,
      'energy', v_profile.energy,
      'max_energy', v_profile.max_energy,
      'registration_status', COALESCE(v_profile.registration_status, 'approved'),
      'registration_rejection_reason', v_profile.registration_rejection_reason,
      'registration_requested_at', v_profile.registration_requested_at,
      'registration_reviewed_at', v_profile.registration_reviewed_at,
      'created_at', v_profile.created_at
    )
  );
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('success', false, 'error', '用户名已存在');
END;
$$;
GRANT EXECUTE ON FUNCTION register_table_user(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;
CREATE OR REPLACE FUNCTION teacher_reset_student_password(
  p_teacher_id UUID,
  p_student_id UUID,
  p_new_password TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_clean_password TEXT := TRIM(COALESCE(p_new_password, ''));
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM users
    WHERE id = p_teacher_id
      AND role = 'teacher'
      AND COALESCE(registration_status, 'approved') = 'approved'
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', '只有已通过的老师账号可以重置学生密码');
  END IF;

  IF LENGTH(v_clean_password) < 6 THEN
    RETURN jsonb_build_object('success', false, 'error', '新密码至少6位');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM users
    WHERE id = p_student_id
      AND role = 'student'
      AND teacher_id = p_teacher_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', '找不到该学生，无法重置密码');
  END IF;

  UPDATE users
  SET plain_password = v_clean_password
  WHERE id = p_student_id;

  RETURN jsonb_build_object(
    'success', true,
    'message', '学生密码已更新，旧密码立即失效。'
  );
END;
$$;
GRANT EXECUTE ON FUNCTION teacher_reset_student_password(UUID, UUID, TEXT) TO anon, authenticated;
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
