CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS public.piano_room_auth (
  id BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
  password_hash TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.piano_room_auth (id, password_hash)
VALUES (TRUE, '$2a$12$uLvgQQ4AjsmQXwbgIuvpy.agq/aLttZWZebUxsjDUe9oANGFhZ3Nu')
ON CONFLICT (id) DO NOTHING;

REVOKE ALL ON TABLE public.piano_room_auth FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.verify_piano_room_password(p_password TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_password_hash TEXT;
BEGIN
  IF NULLIF(TRIM(COALESCE(p_password, '')), '') IS NULL THEN
    RETURN FALSE;
  END IF;

  SELECT password_hash
  INTO v_password_hash
  FROM public.piano_room_auth
  WHERE id = TRUE;

  RETURN v_password_hash IS NOT NULL
    AND extensions.crypt(p_password, v_password_hash) = v_password_hash;
END;
$$;

CREATE OR REPLACE FUNCTION public.change_piano_room_password(
  p_old_password TEXT,
  p_new_password TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_password_hash TEXT;
  v_old_password TEXT := TRIM(COALESCE(p_old_password, ''));
  v_new_password TEXT := TRIM(COALESCE(p_new_password, ''));
BEGIN
  IF v_old_password = '' OR v_new_password = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', '请输入旧密码和新密码');
  END IF;

  IF LENGTH(v_new_password) < 6 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', '新密码至少6位');
  END IF;

  SELECT password_hash
  INTO v_password_hash
  FROM public.piano_room_auth
  WHERE id = TRUE
  FOR UPDATE;

  IF v_password_hash IS NULL
     OR extensions.crypt(v_old_password, v_password_hash) <> v_password_hash THEN
    RETURN jsonb_build_object('success', FALSE, 'error', '旧密码错误');
  END IF;

  UPDATE public.piano_room_auth
  SET password_hash = extensions.crypt(v_new_password, extensions.gen_salt('bf', 12)),
      updated_at = NOW()
  WHERE id = TRUE;

  RETURN jsonb_build_object('success', TRUE, 'message', '密码已修改');
END;
$$;

REVOKE ALL ON FUNCTION public.verify_piano_room_password(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.change_piano_room_password(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.verify_piano_room_password(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.change_piano_room_password(TEXT, TEXT) TO anon, authenticated;
