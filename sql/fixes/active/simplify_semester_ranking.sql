-- ============================================================
-- 学期管理精简版（移除梅纽因之星，仅保留累计排行 + 新学期清零）
-- ============================================================

-- 1) 下线梅纽因之星相关后端对象
DROP FUNCTION IF EXISTS public.award_meiyin_star(TEXT, TEXT, TEXT);
DROP TABLE IF EXISTS public.meiyin_star_log;

-- 2) 保留新学期清零能力（如果函数不存在则重建）
CREATE OR REPLACE FUNCTION public.start_new_semester(p_confirm TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_count INTEGER;
    v_total_cleared INTEGER;
BEGIN
    IF p_confirm <> 'CONFIRM_NEW_SEMESTER' THEN
        RETURN '❌ 安全确认失败。请传入字符串 "CONFIRM_NEW_SEMESTER" 方可执行。';
    END IF;

    INSERT INTO public.student_coins (student_name, balance, semester_earned)
    SELECT sd.name, 0, 0
    FROM public.student_database sd
    ON CONFLICT (student_name) DO NOTHING;

    INSERT INTO public.coin_transactions
        (student_name, amount, balance_after, reason, transaction_type)
    SELECT
        sc.student_name,
        -sc.balance,
        0,
        '开启新学期：清空音符币余额（原余额 ' || sc.balance || '，本学期累计 '
            || sc.semester_earned || '）。',
        'semester_reset'
    FROM public.student_coins sc
    ORDER BY sc.student_name;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    SELECT COALESCE(SUM(GREATEST(balance, 0)), 0)
    INTO v_total_cleared
    FROM public.student_coins;

    UPDATE public.student_coins
    SET balance = 0,
        semester_earned = 0,
        updated_at = NOW()
    WHERE student_name IS NOT NULL;

    RETURN '✅ 新学期已开启，共清空 ' || v_count || ' 位学生的音符币余额，合计清空 '
           || v_total_cleared || ' 枚；已写入所有人的流水记录。';
END;
$$;

GRANT EXECUTE ON FUNCTION public.start_new_semester(TEXT) TO anon, authenticated;

-- 3) 视图保持包含 semester_earned，供后台累计排行使用
DROP VIEW IF EXISTS public.vw_student_coin_balances;
CREATE VIEW public.vw_student_coin_balances
WITH (security_invoker = true) AS
SELECT
    sd.name                         AS student_name,
    sd.major                        AS student_major,
    sd.grade                        AS student_grade,
    COALESCE(sc.balance, 0)         AS balance,
    COALESCE(sc.semester_earned, 0) AS semester_earned,
    sc.updated_at
FROM public.student_database sd
LEFT JOIN public.student_coins sc ON sd.name = sc.student_name
WHERE COALESCE(sd.archived, FALSE) IS FALSE;

GRANT SELECT ON public.vw_student_coin_balances TO anon, authenticated;
