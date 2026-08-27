-- 修复 start_new_semester()：清空 student_coins 的 UPDATE 缺少 WHERE 子句，
-- 触发 Supabase 的全表更新保护（"UPDATE requires a WHERE clause"），导致清空全员音符币失败。

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
