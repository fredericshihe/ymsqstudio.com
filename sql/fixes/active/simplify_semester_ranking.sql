-- ============================================================
-- 学期管理精简版（移除梅纽因之星，仅保留累计排行 + 学期重置）
-- ============================================================

-- 1) 下线梅纽因之星相关后端对象
DROP FUNCTION IF EXISTS public.award_meiyin_star(TEXT, TEXT, TEXT);
DROP TABLE IF EXISTS public.meiyin_star_log;

-- 2) 保留学期重置能力（如果函数不存在则重建）
CREATE OR REPLACE FUNCTION public.start_new_semester(p_confirm TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    IF p_confirm <> 'CONFIRM_NEW_SEMESTER' THEN
        RETURN '❌ 安全确认失败。请传入字符串 "CONFIRM_NEW_SEMESTER" 方可执行。';
    END IF;

    UPDATE public.student_coins SET semester_earned = 0;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    RETURN '✅ 新学期已开启，共重置 ' || v_count || ' 位学生的 semester_earned 为 0。（balance 总余额不变）';
END;
$$;

GRANT EXECUTE ON FUNCTION public.start_new_semester(TEXT) TO anon, authenticated;

-- 3) 视图保持包含 semester_earned，供后台累计排行使用
DROP VIEW IF EXISTS public.vw_student_coin_balances;
CREATE VIEW public.vw_student_coin_balances AS
SELECT
    sd.name                         AS student_name,
    sd.major                        AS student_major,
    sd.grade                        AS student_grade,
    COALESCE(sc.balance, 0)         AS balance,
    COALESCE(sc.semester_earned, 0) AS semester_earned,
    sc.updated_at
FROM public.student_database sd
LEFT JOIN public.student_coins sc ON sd.name = sc.student_name;

GRANT SELECT ON public.vw_student_coin_balances TO anon, authenticated;

