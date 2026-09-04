BEGIN;

DO $migration$
DECLARE
  target_definition TEXT;
  updated_definition TEXT;
BEGIN
  SELECT pg_get_functiondef('public.backup_weekly_leaderboards()'::REGPROCEDURE)
  INTO target_definition;

  IF target_definition IS NULL THEN
    RAISE EXCEPTION '找不到 public.backup_weekly_leaderboards()';
  END IF;

  IF target_definition LIKE '%PERFORM public.run_weekly_score_update();%' THEN
    NULL;
  ELSE
    updated_definition := REPLACE(
      target_definition,
      E'PERFORM public.auto_clear_open_sessions();\n\n  PERFORM pg_advisory_xact_lock',
      E'PERFORM public.auto_clear_open_sessions();\n  PERFORM public.run_weekly_score_update();\n\n  PERFORM pg_advisory_xact_lock'
    );

    IF updated_definition = target_definition THEN
      RAISE EXCEPTION '无法把周评分更新插入锁榜事务';
    END IF;

    EXECUTE updated_definition;
  END IF;
END;
$migration$;

DO $cron$
BEGIN
  PERFORM cron.unschedule('weekly_score_update_job');
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$cron$;

DO $cron$
BEGIN
  PERFORM cron.unschedule('backup_weekly_leaderboards_job');
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$cron$;

SELECT cron.schedule(
  'backup_weekly_leaderboards_job',
  '31 13 * * 5',
  $$SELECT public.backup_weekly_leaderboards();$$
);

DO $cron$
BEGIN
  PERFORM cron.unschedule('reward_weekly_coins_job');
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$cron$;

SELECT cron.schedule(
  'reward_weekly_coins_job',
  '35 13 * * 5',
  $$SELECT public.reward_weekly_coins();$$
);

COMMENT ON FUNCTION public.backup_weekly_leaderboards() IS
'Friday 21:30 clear, weekly score update, final W-score refresh, and immutable leaderboard lock run in one transaction; coin settlement reads this final snapshot.';

COMMENT ON FUNCTION public.reward_weekly_coins() IS
'Friday 21:35 settles rewards and shrink penalties only from the immutable snapshot created after the Friday 21:30 clear and final score calculation.';

DO $function_patch$
DECLARE
  target_definition TEXT;
  updated_definition TEXT;
BEGIN
  SELECT pg_get_functiondef('public.reward_weekly_coins()'::REGPROCEDURE)
  INTO target_definition;
  updated_definition := REPLACE(
    target_definition,
    '使用21:30锁榜快照',
    '使用清空后最终锁榜快照'
  );
  IF updated_definition <> target_definition THEN
    EXECUTE updated_definition;
  END IF;
END;
$function_patch$;

NOTIFY pgrst, 'reload schema';

COMMIT;
