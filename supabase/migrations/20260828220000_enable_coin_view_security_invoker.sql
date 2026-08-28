BEGIN;

ALTER VIEW public.vw_student_coin_balances
SET (security_invoker = true);

GRANT SELECT ON public.vw_student_coin_balances TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
