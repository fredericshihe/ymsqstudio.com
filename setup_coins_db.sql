-- ============================================================================
-- 音符币系统数据库初始化脚本 (Note Coins System)
-- ============================================================================

-- 1. 创建音符币余额表
-- 存储每个学生的当前音符币总数
CREATE TABLE IF NOT EXISTS public.student_coins (
    student_name TEXT PRIMARY KEY,
    balance INTEGER NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2. 创建音符币流水记录表
-- 存储所有的加减操作，包括手动操作和未来的自动结算
CREATE TABLE IF NOT EXISTS public.coin_transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    student_name TEXT NOT NULL,
    amount INTEGER NOT NULL,          -- 变动数量：正数为增加，负数为扣除
    balance_after INTEGER NOT NULL,   -- 变动后的最新余额
    reason TEXT,                      -- 备注说明（如：帮老师打扫琴房、综合榜第一名奖励等）
    transaction_type TEXT NOT NULL DEFAULT 'manual', -- 记录类型：'manual' (手动), 'auto_reward' (自动奖励)
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 为流水表创建索引，加速前端按学生和时间查询历史记录
CREATE INDEX IF NOT EXISTS idx_coin_tx_student ON public.coin_transactions(student_name, created_at DESC);

-- 3. 创建核心操作函数 (RPC)
-- 这是一个原子操作函数，保证更新余额和写入流水同时成功，避免数据不一致
CREATE OR REPLACE FUNCTION public.adjust_student_coins(
    p_student_name TEXT,
    p_amount INTEGER,
    p_reason TEXT,
    p_type TEXT DEFAULT 'manual'
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER -- 使用创建者权限，确保前端调用时有权限写入
AS $$
DECLARE
    v_current_balance INTEGER;
    v_new_balance INTEGER;
BEGIN
    -- 1. 如果该学生在余额表中还不存在，先初始化为 0
    INSERT INTO public.student_coins (student_name, balance)
    VALUES (p_student_name, 0)
    ON CONFLICT (student_name) DO NOTHING;

    -- 2. 锁定该学生的行，并获取当前余额（防止并发修改冲突）
    SELECT balance INTO v_current_balance
    FROM public.student_coins
    WHERE student_name = p_student_name
    FOR UPDATE;

    -- 3. 计算新余额
    v_new_balance := v_current_balance + p_amount;

    -- 4. 更新余额表
    UPDATE public.student_coins
    SET balance = v_new_balance,
        updated_at = NOW()
    WHERE student_name = p_student_name;

    -- 5. 写入流水记录表
    INSERT INTO public.coin_transactions (student_name, amount, balance_after, reason, transaction_type)
    VALUES (p_student_name, p_amount, v_new_balance, p_reason, p_type);

    -- 返回变动后的最新余额
    RETURN v_new_balance;
END;
$$;

-- 授予前端调用权限
GRANT EXECUTE ON FUNCTION public.adjust_student_coins(TEXT, INTEGER, TEXT, TEXT) TO anon, authenticated;

-- 4. 创建一个视图，方便前端一次性拉取学生信息和余额
CREATE OR REPLACE VIEW public.vw_student_coin_balances AS
SELECT 
    sd.name AS student_name,
    sd.major AS student_major,
    sd.grade AS student_grade,
    COALESCE(sc.balance, 0) AS balance,
    sc.updated_at
FROM public.student_database sd
LEFT JOIN public.student_coins sc ON sd.name = sc.student_name;

GRANT SELECT ON public.vw_student_coin_balances TO anon, authenticated;
GRANT SELECT ON public.coin_transactions TO anon, authenticated;
