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
    'profile', to_jsonb(v_profile)
  );
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('success', false, 'error', '用户名已存在');
END;
$$;
GRANT EXECUTE ON FUNCTION register_table_user(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;
CREATE OR REPLACE FUNCTION clear_cloud_game_save(
  p_user_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_gold INT := 500;
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
  SET gold = 500,
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
