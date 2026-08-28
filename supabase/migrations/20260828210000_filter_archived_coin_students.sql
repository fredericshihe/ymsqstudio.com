BEGIN;

CREATE OR REPLACE VIEW public.vw_student_coin_balances AS
SELECT
    sd.name                              AS student_name,
    sd.major                             AS student_major,
    sd.grade                             AS student_grade,
    COALESCE(sc.balance, 0)              AS balance,
    COALESCE(sc.semester_earned, 0)      AS semester_earned,
    sc.updated_at
FROM public.student_database sd
LEFT JOIN public.student_coins sc ON sd.name = sc.student_name
WHERE COALESCE(sd.archived, FALSE) IS FALSE;

GRANT SELECT ON public.vw_student_coin_balances TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
