-- 用户名展示 + 访问到期时间（与 auth.users 一一对应）
CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  username text NOT NULL UNIQUE,
  access_expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "profiles_select_own"
  ON public.profiles
  FOR SELECT
  TO authenticated
  USING (auth.uid() = id);
-- 兑换码：plan = day | week | month；可选 expires_at 表示「码本身」在此时间前有效
CREATE TABLE IF NOT EXISTS public.redeem_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  plan text NOT NULL CHECK (plan IN ('day', 'week', 'month')),
  max_uses int NOT NULL DEFAULT 1 CHECK (max_uses >= 1),
  used_count int NOT NULL DEFAULT 0 CHECK (used_count >= 0),
  active boolean NOT NULL DEFAULT true,
  expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
-- 原子兑换：续期从 max(当前时刻, 原到期时间) 起算
CREATE OR REPLACE FUNCTION public.redeem_access_code(p_code text, p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r redeem_codes%ROWTYPE;
  prof profiles%ROWTYPE;
  add_interval interval;
  base_ts timestamptz;
  new_exp timestamptz;
BEGIN
  SELECT * INTO r
  FROM redeem_codes
  WHERE upper(trim(code)) = upper(trim(p_code))
    AND active = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'INVALID_CODE');
  END IF;

  IF r.used_count >= r.max_uses THEN
    RETURN jsonb_build_object('ok', false, 'error', 'CODE_EXHAUSTED');
  END IF;

  IF r.expires_at IS NOT NULL AND r.expires_at < now() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'CODE_EXPIRED');
  END IF;

  SELECT * INTO prof FROM profiles WHERE id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NO_PROFILE');
  END IF;

  add_interval := CASE r.plan
    WHEN 'day' THEN interval '1 day'
    WHEN 'week' THEN interval '7 days'
    WHEN 'month' THEN interval '30 days'
    ELSE interval '1 day'
  END;

  base_ts := greatest(now(), COALESCE(prof.access_expires_at, to_timestamp(0)));
  new_exp := base_ts + add_interval;

  UPDATE profiles SET access_expires_at = new_exp WHERE id = p_user_id;
  UPDATE redeem_codes SET used_count = used_count + 1 WHERE id = r.id;

  RETURN jsonb_build_object(
    'ok', true,
    'access_expires_at', new_exp,
    'plan', r.plan
  );
END;
$$;
REVOKE ALL ON FUNCTION public.redeem_access_code(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.redeem_access_code(text, uuid) TO service_role;
-- 示例（请删除或改码后再生产使用）:
-- INSERT INTO public.redeem_codes (code, plan, max_uses) VALUES
--   ('DEMO-DAY-1', 'day', 100),
--   ('DEMO-WEEK-1', 'week', 50),
--   ('DEMO-MONTH-1', 'month', 10);;
