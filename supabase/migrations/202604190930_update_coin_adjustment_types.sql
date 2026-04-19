-- 手动音符币操作类型细化：
-- compensation：补偿，增加 balance，增加 semester_earned
-- deduction：扣除，减少 balance，减少 semester_earned（最低到 0）
-- redemption：兑换，减少 balance，不影响 semester_earned
-- auto_reward：系统结算，增加 balance，增加 semester_earned

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
    v_new_balance INTEGER;
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

    INSERT INTO public.student_coins (student_name, balance, semester_earned)
    VALUES (p_student_name, 0, 0)
    ON CONFLICT (student_name) DO NOTHING;

    SELECT balance, semester_earned
    INTO v_current_balance, v_new_semester_earned
    FROM public.student_coins
    WHERE student_name = p_student_name
    FOR UPDATE;

    v_new_balance := v_current_balance + p_amount;

    v_new_semester_earned := CASE
        WHEN p_type IN ('auto_reward', 'compensation')
            THEN v_new_semester_earned + p_amount
        WHEN p_type = 'deduction'
            THEN GREATEST(0, v_new_semester_earned + p_amount)
        ELSE
            v_new_semester_earned
    END;

    UPDATE public.student_coins
    SET balance = v_new_balance,
        semester_earned = v_new_semester_earned,
        updated_at = NOW()
    WHERE student_name = p_student_name;

    INSERT INTO public.coin_transactions
        (student_name, amount, balance_after, reason, transaction_type)
    VALUES
        (p_student_name, p_amount, v_new_balance, p_reason, p_type);

    RETURN v_new_balance;
END;
$$;

GRANT EXECUTE ON FUNCTION public.adjust_student_coins(TEXT, INTEGER, TEXT, TEXT) TO anon, authenticated;
