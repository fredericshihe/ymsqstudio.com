-- ============================================================
-- 学期管理系统
-- 文件：setup_semester.sql
--
-- 功能：
--   1. 为 student_coins 新增 semester_earned 字段
--      （本学期通过排行榜自动奖励获得的音符币，每学期重置）
--   2. 移除梅纽因之星相关历史对象（表 + RPC）
--   3. start_new_semester(confirm)  — 开启新学期（重置 semester_earned）
--   4. 更新 adjust_student_coins()  — 同步累加 semester_earned
--   5. 更新 vw_student_coin_balances 视图 — 暴露 semester_earned
--
-- 设计原则：
--   - balance（总余额）：可跨学期积累，用于兑换任意奖励
--   - semester_earned：按交易类型更新（auto_reward / compensation 增加，deduction 减少，redemption 不变），每学期可重置
--   - 后台仅保留“学期累计排行 + 学期重置”，移除梅纽因之星功能
-- ============================================================


-- ============================================================
-- 1. 为 student_coins 添加 semester_earned 字段
-- ============================================================
ALTER TABLE public.student_coins
ADD COLUMN IF NOT EXISTS semester_earned INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.student_coins.semester_earned IS
    '本学期累计获得的音符币（正向调整会累加，学期初可调用 start_new_semester() 重置为 0）。';


-- ============================================================
-- 2. 移除梅纽因之星相关对象（历史功能下线）
-- ============================================================
DROP FUNCTION IF EXISTS public.award_meiyin_star(TEXT, TEXT, TEXT);
DROP TABLE IF EXISTS public.meiyin_star_log;


-- ============================================================
-- 3. 开启新学期（重置所有学生的 semester_earned）
-- ============================================================
CREATE OR REPLACE FUNCTION public.start_new_semester(p_confirm TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    -- 安全确认，防止误触
    IF p_confirm <> 'CONFIRM_NEW_SEMESTER' THEN
        RETURN '❌ 安全确认失败。请传入字符串 "CONFIRM_NEW_SEMESTER" 方可执行。';
    END IF;

    UPDATE public.student_coins SET semester_earned = 0;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    RETURN '✅ 新学期已开启，共重置 ' || v_count || ' 位学生的 semester_earned 为 0。'
           || '（balance 总余额不变）';
END;
$$;

GRANT EXECUTE ON FUNCTION public.start_new_semester(TEXT) TO anon, authenticated;


-- ============================================================
-- 4. 更新 adjust_student_coins()：按交易类型更新 semester_earned
--    - auto_reward / compensation：正向计入本学期累计
--    - deduction：负向冲减本学期累计，但最低不低于 0
--    - redemption：只影响余额，不影响本学期累计
-- ============================================================
CREATE OR REPLACE FUNCTION public.adjust_student_coins(
    p_student_name TEXT,
    p_amount       INTEGER,
    p_reason       TEXT,
    p_type         TEXT DEFAULT 'compensation'
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_current_balance INTEGER;
    v_new_balance     INTEGER;
    v_new_semester_earned INTEGER;
BEGIN
    IF p_type NOT IN ('auto_reward', 'compensation', 'deduction', 'redemption') THEN
        RAISE EXCEPTION '不支持的 p_type: %', p_type;
    END IF;

    IF p_type IN ('auto_reward', 'compensation') AND p_amount <= 0 THEN
        RAISE EXCEPTION '类型 % 的 p_amount 必须为正数', p_type;
    END IF;

    IF p_type IN ('deduction', 'redemption') AND p_amount >= 0 THEN
        RAISE EXCEPTION '类型 % 的 p_amount 必须为负数', p_type;
    END IF;

    -- 1. 若学生不在余额表，先初始化
    INSERT INTO public.student_coins (student_name, balance, semester_earned)
    VALUES (p_student_name, 0, 0)
    ON CONFLICT (student_name) DO NOTHING;

    -- 2. 行锁 + 读当前余额
    SELECT balance, semester_earned
    INTO v_current_balance, v_new_semester_earned
    FROM public.student_coins
    WHERE student_name = p_student_name
    FOR UPDATE;

    -- 3. 计算新余额
    v_new_balance := v_current_balance + p_amount;

    -- 4. 按交易类型更新本学期累计
    v_new_semester_earned := CASE
        WHEN p_type IN ('auto_reward', 'compensation')
            THEN v_new_semester_earned + p_amount
        WHEN p_type = 'deduction'
            THEN GREATEST(0, v_new_semester_earned + p_amount)
        ELSE
            v_new_semester_earned
    END;

    -- 5. 更新余额 + semester_earned
    UPDATE public.student_coins
    SET balance         = v_new_balance,
        semester_earned = v_new_semester_earned,
        updated_at      = NOW()
    WHERE student_name = p_student_name;

    -- 6. 写入流水记录
    INSERT INTO public.coin_transactions
        (student_name, amount, balance_after, reason, transaction_type)
    VALUES
        (p_student_name, p_amount, v_new_balance, p_reason, p_type);

    RETURN v_new_balance;
END;
$$;

GRANT EXECUTE ON FUNCTION public.adjust_student_coins(TEXT, INTEGER, TEXT, TEXT) TO anon, authenticated;


-- ============================================================
-- 5. 更新视图，暴露 semester_earned 供管理后台读取
--    必须先 DROP 再重建，否则 CREATE OR REPLACE 不允许改列顺序
-- ============================================================
DROP VIEW IF EXISTS public.vw_student_coin_balances;
CREATE VIEW public.vw_student_coin_balances AS
SELECT
    sd.name                              AS student_name,
    sd.major                             AS student_major,
    sd.grade                             AS student_grade,
    COALESCE(sc.balance, 0)              AS balance,
    COALESCE(sc.semester_earned, 0)      AS semester_earned,
    sc.updated_at
FROM public.student_database sd
LEFT JOIN public.student_coins sc ON sd.name = sc.student_name;

GRANT SELECT ON public.vw_student_coin_balances TO anon, authenticated;


-- ============================================================
-- 常用管理命令
-- ============================================================

-- 查看本学期各学生进度（按 semester_earned 降序）：
-- SELECT student_name, semester_earned, balance
-- FROM public.student_coins
-- ORDER BY semester_earned DESC;

-- 开启新学期（重置 semester_earned）：
-- SELECT public.start_new_semester('CONFIRM_NEW_SEMESTER');
