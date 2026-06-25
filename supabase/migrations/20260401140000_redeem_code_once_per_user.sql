-- 同一用户同一兑换码仅可成功兑换一次（与 max_uses 全局次数并行：码仍可被其他用户使用）
CREATE TABLE IF NOT EXISTS public.redeem_code_redemptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  redeem_code_id uuid NOT NULL REFERENCES public.redeem_codes (id) ON DELETE CASCADE,
  redeemed_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, redeem_code_id)
);
CREATE INDEX IF NOT EXISTS idx_redeem_redemptions_code_id
  ON public.redeem_code_redemptions (redeem_code_id);
ALTER TABLE public.redeem_code_redemptions ENABLE ROW LEVEL SECURITY;
-- 业务仅经 service_role / SECURITY DEFINER；与 redeem_codes 一致不向 anon 开放

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

  -- 串行化同一 (用户, 码) 的并发请求，避免双请求同时通过「未兑换」检查
  PERFORM pg_advisory_xact_lock(
    92001,
    abs(hashtext(p_user_id::text || ':' || r.id::text))
  );

  IF EXISTS (
    SELECT 1
    FROM redeem_code_redemptions
    WHERE user_id = p_user_id
      AND redeem_code_id = r.id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ALREADY_REDEEMED');
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

  INSERT INTO redeem_code_redemptions (user_id, redeem_code_id)
  VALUES (p_user_id, r.id);

  RETURN jsonb_build_object(
    'ok', true,
    'access_expires_at', new_exp,
    'plan', r.plan
  );
END;
$$;
REVOKE ALL ON FUNCTION public.redeem_access_code(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.redeem_access_code(text, uuid) TO service_role;
