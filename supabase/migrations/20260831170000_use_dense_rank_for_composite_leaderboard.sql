BEGIN;

DO $migration$
DECLARE
  v_definition TEXT;
  v_updated    TEXT;
BEGIN
  SELECT pg_get_functiondef('public.get_weekly_leaderboards()'::REGPROCEDURE)
  INTO v_definition;

  v_updated := regexp_replace(
    v_definition,
    $$('综合榜'::[Tt][Ee][Xx][Tt] AS board,\s*)RANK\(\) OVER$$,
    $$\1DENSE_RANK() OVER$$,
    1,
    1,
    'n'
  );

  IF v_updated = v_definition THEN
    RAISE EXCEPTION '未找到综合榜 RANK 排名表达式，停止迁移';
  END IF;

  EXECUTE v_updated;
END;
$migration$;

REVOKE ALL ON FUNCTION public.get_weekly_leaderboards() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_weekly_leaderboards() TO anon, authenticated;

COMMENT ON FUNCTION public.get_weekly_leaderboards() IS
'The composite leaderboard uses dense ranks so ties keep the same rank without skipping the next rank (1, 1, 2).';

NOTIFY pgrst, 'reload schema';

COMMIT;
