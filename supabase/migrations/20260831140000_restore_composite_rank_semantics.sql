BEGIN;

-- 20260831130000 的线上首次执行曾被并发工作区改动带入 DENSE_RANK。
-- 综合榜并列规则不属于本次优化范围，恢复为此前一直使用的 RANK。
DO $migration$
DECLARE
  v_definition TEXT;
  v_updated    TEXT;
BEGIN
  SELECT pg_get_functiondef('public.get_weekly_leaderboards()'::REGPROCEDURE)
  INTO v_definition;

  v_updated := regexp_replace(
    v_definition,
    $$('综合榜'::[Tt][Ee][Xx][Tt] AS board,\s*)DENSE_RANK\(\) OVER$$,
    $$\1RANK() OVER$$,
    1,
    1,
    'n'
  );

  IF v_updated <> v_definition THEN
    EXECUTE v_updated;
  ELSIF v_definition !~ $$'综合榜'::[Tt][Ee][Xx][Tt] AS board,\s*RANK\(\) OVER$$ THEN
    RAISE EXCEPTION '未找到综合榜排名函数，停止迁移以避免误改其他榜单';
  END IF;
END;
$migration$;

REVOKE ALL ON FUNCTION public.get_weekly_leaderboards() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_weekly_leaderboards() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
