-- =============================================================
-- FIX: auto_coin_reward_enabled 开关读取失败（RLS 拦截问题）
-- 问题：system_settings 表若启用了 RLS，前端直接 SELECT 会返回 0 行
--       导致 maybeSingle() 返回 null，界面始终显示"已关闭"
-- 解法：增加 SECURITY DEFINER 读取 RPC，绕过 RLS；并补全初始记录
-- =============================================================

-- 1. 确保初始记录存在（默认开启）
INSERT INTO public.system_settings (key, value, updated_at)
VALUES ('auto_coin_reward_enabled', 'true', NOW())
ON CONFLICT (key) DO NOTHING;

-- 2. 新增 SECURITY DEFINER 读取函数（绕过 RLS）
CREATE OR REPLACE FUNCTION public.get_auto_reward_setting()
RETURNS TABLE(enabled BOOLEAN, updated_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT
        (value = 'true') AS enabled,
        s.updated_at
    FROM public.system_settings s
    WHERE s.key = 'auto_coin_reward_enabled'
    LIMIT 1;

    -- 如果没有记录，返回默认值 true
    IF NOT FOUND THEN
        RETURN QUERY SELECT TRUE, NOW();
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_auto_reward_setting() TO anon, authenticated;

-- 3. 如果表没有开放 SELECT，补上
GRANT SELECT ON public.system_settings TO anon, authenticated;
