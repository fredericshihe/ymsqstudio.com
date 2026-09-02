BEGIN;

SELECT public.refresh_all_w_scores();

NOTIFY pgrst, 'reload schema';

COMMIT;
