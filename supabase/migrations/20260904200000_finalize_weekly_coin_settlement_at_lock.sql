BEGIN;

-- 21:30 是本周榜单的唯一结算时点：
--   1) 先在同一把事务锁内重算全部当前周 W/综合分；
--   2) 再把重算后的五类榜单写入 weekly_leaderboard_history；
--   3) 21:32 的 reward_weekly_coins() 只读取这份不可变快照。
--
-- 这样可以避免 21:25 预刷新后，21:30 前新增记录没有进入结算榜，
-- 也避免发币函数再次读取 21:32 的实时榜单。

DO $migration$
DECLARE
  target_definition  TEXT;
  updated_definition TEXT;
  delete_pos          INTEGER;
BEGIN
  SELECT pg_get_functiondef('public.backup_weekly_leaderboards()'::REGPROCEDURE)
  INTO target_definition;

  IF target_definition IS NULL THEN
    RAISE EXCEPTION '找不到 public.backup_weekly_leaderboards()，停止 21:30 最终锁榜迁移';
  END IF;

  IF target_definition LIKE '%PERFORM public.refresh_all_w_scores();%'
     AND target_definition LIKE '%结算前强制完成一次最终重算%' THEN
    RETURN;
  END IF;

  delete_pos := POSITION('DELETE FROM public.weekly_leaderboard_history' IN target_definition);
  IF delete_pos = 0 THEN
    RAISE EXCEPTION
      'backup_weekly_leaderboards() 定义与预期版本不一致，未找到锁榜写入位置，停止迁移';
  END IF;

  updated_definition := SUBSTR(target_definition, 1, delete_pos - 1)
    || E'-- 结算前强制完成一次最终重算，结果由本事务锁定为 21:30 快照。\n'
    || E'  PERFORM public.refresh_all_w_scores();\n\n'
    || SUBSTR(target_definition, delete_pos);

  IF updated_definition = target_definition
     OR updated_definition NOT LIKE '%PERFORM public.refresh_all_w_scores();%'
     OR updated_definition NOT LIKE '%weekly_leaderboard_history history%' THEN
    RAISE EXCEPTION '未能把最终重算插入 21:30 锁榜事务，停止迁移';
  END IF;

  EXECUTE updated_definition;
END;
$migration$;

CREATE OR REPLACE FUNCTION public.get_weekly_leaderboard_settlement_status(
  p_week_monday DATE DEFAULT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
)
RETURNS TABLE (
  week_monday   DATE,
  is_locked     BOOLEAN,
  locked_at     TIMESTAMPTZ,
  snapshot_rows INTEGER
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT
    requested.week_monday,
    lock_row.week_monday IS NOT NULL,
    lock_row.locked_at,
    lock_row.snapshot_rows
  FROM (
    SELECT COALESCE(
      p_week_monday,
      DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
    ) AS week_monday
  ) requested
  LEFT JOIN public.weekly_leaderboard_locks lock_row
    ON lock_row.week_monday = requested.week_monday;
$function$;

REVOKE ALL ON FUNCTION public.get_weekly_leaderboard_settlement_status(DATE)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_weekly_leaderboard_settlement_status(DATE)
TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_weekly_leaderboard_settlement_snapshot(
  p_week_monday DATE DEFAULT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
)
RETURNS TABLE (
  week_monday           DATE,
  board                 TEXT,
  rank_no               INTEGER,
  student_name          TEXT,
  student_major         TEXT,
  student_grade         TEXT,
  display_score         NUMERIC,
  alpha                 NUMERIC,
  trend_score           NUMERIC,
  mean_duration         NUMERIC,
  record_count          INTEGER,
  recent10_outlier_rate NUMERIC,
  recent10_mean_dur     NUMERIC,
  recent10_count        INTEGER,
  target_minutes        NUMERIC,
  completed_minutes     NUMERIC,
  completion_ratio      NUMERIC,
  shortfall_minutes     NUMERIC,
  week_session_count    INTEGER
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT
    history.week_monday,
    history.board,
    history.rank_no,
    history.student_name,
    history.student_major,
    history.student_grade,
    history.display_score,
    history.alpha,
    history.trend_score,
    history.mean_duration,
    history.record_count,
    history.recent10_outlier_rate,
    history.recent10_mean_dur,
    history.recent10_count,
    history.target_minutes,
    history.completed_minutes,
    history.completion_ratio,
    history.shortfall_minutes,
    history.week_session_count
  FROM public.weekly_leaderboard_locks lock_row
  JOIN public.weekly_leaderboard_history history
    ON history.week_monday = lock_row.week_monday
  WHERE lock_row.week_monday = COALESCE(
    p_week_monday,
    DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
  )
  ORDER BY history.board, history.rank_no, history.student_name;
$function$;

REVOKE ALL ON FUNCTION public.get_weekly_leaderboard_settlement_snapshot(DATE)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_weekly_leaderboard_settlement_snapshot(DATE)
TO anon, authenticated;

-- 显式重建两个任务，确保生产环境的时间不会漂移：
-- UTC 13:30 = 北京时间周五 21:30 锁榜；
-- UTC 13:32 = 北京时间周五 21:32 只读锁榜快照发币。
CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $cron$
BEGIN
  PERFORM cron.unschedule('backup_weekly_leaderboards_job');
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$cron$;

SELECT cron.schedule(
  'backup_weekly_leaderboards_job',
  '30 13 * * 5',
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
  '32 13 * * 5',
  $$SELECT public.reward_weekly_coins();$$
);

DO $cron$
BEGIN
  PERFORM cron.unschedule('refresh_w_score_before_weekly_lock');
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$cron$;

COMMENT ON FUNCTION public.backup_weekly_leaderboards() IS
'Friday 21:30 finalizes the weekly leaderboard in one transaction: refreshes all current-week scores, writes the leaderboard snapshot, and locks it for the 21:32 coin settlement.';

COMMENT ON FUNCTION public.reward_weekly_coins() IS
'Friday 21:32 settles rewards and shrink penalties only from the immutable leaderboard snapshot created by the 21:30 final-final score calculation.';

NOTIFY pgrst, 'reload schema';

COMMIT;
