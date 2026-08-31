WITH current_week AS (
  SELECT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS monday
),
lock_state AS (
  SELECT
    leaderboard_lock.week_monday,
    leaderboard_lock.locked_at,
    leaderboard_lock.snapshot_rows,
    leaderboard_lock.snapshot_checksum,
    COUNT(history.*)::INTEGER AS actual_rows,
    public.get_weekly_leaderboard_snapshot_checksum(leaderboard_lock.week_monday)
      AS actual_checksum
  FROM public.weekly_leaderboard_locks leaderboard_lock
  JOIN current_week week ON week.monday = leaderboard_lock.week_monday
  LEFT JOIN public.weekly_leaderboard_history history
    ON history.week_monday = leaderboard_lock.week_monday
  GROUP BY
    leaderboard_lock.week_monday,
    leaderboard_lock.locked_at,
    leaderboard_lock.snapshot_rows,
    leaderboard_lock.snapshot_checksum
),
expected AS (
  SELECT
    history.week_monday,
    history.board,
    history.rank_no,
    history.student_name,
    CASE
      WHEN history.board = '综合榜' AND history.rank_no = 1 THEN 80
      WHEN history.board = '综合榜' AND history.rank_no BETWEEN 2 AND 3 THEN 64
      WHEN history.board = '综合榜' AND history.rank_no BETWEEN 4 AND 6 THEN 48
      WHEN history.board = '综合榜' AND history.rank_no BETWEEN 7 AND 10 THEN 32
      WHEN history.board = '稳定榜' AND history.rank_no = 1 THEN 12
      WHEN history.board = '稳定榜' AND history.rank_no BETWEEN 2 AND 3 THEN 9
      WHEN history.board = '稳定榜' AND history.rank_no BETWEEN 4 AND 6 THEN 5
      WHEN history.board = '守则榜' AND history.rank_no = 1 THEN 11
      WHEN history.board = '守则榜' AND history.rank_no BETWEEN 2 AND 3 THEN 8
      WHEN history.board = '守则榜' AND history.rank_no BETWEEN 4 AND 6 THEN 5
      WHEN history.board = '进步榜' AND history.rank_no = 1 THEN 10
      WHEN history.board = '进步榜' AND history.rank_no BETWEEN 2 AND 3 THEN 6
      WHEN history.board = '进步榜' AND history.rank_no BETWEEN 4 AND 6 THEN 4
      WHEN history.board = '缩水榜' AND history.rank_no = 1 THEN -10
      WHEN history.board = '缩水榜' AND history.rank_no BETWEEN 2 AND 3 THEN -6
      WHEN history.board = '缩水榜' AND history.rank_no BETWEEN 4 AND 6 THEN -4
      ELSE 0
    END AS expected_amount
  FROM public.weekly_leaderboard_history history
  JOIN current_week week ON week.monday = history.week_monday
),
actual AS (
  SELECT
    detail.week_monday,
    detail.board,
    detail.rank_no,
    detail.student_name,
    detail.amount
  FROM public.weekly_coin_reward_detail detail
  JOIN current_week week ON week.monday = detail.week_monday
),
settlement_diff AS (
  SELECT COUNT(*)::INTEGER AS mismatch_count
  FROM expected
  FULL OUTER JOIN actual
    ON actual.week_monday = expected.week_monday
   AND actual.board = expected.board
   AND actual.rank_no = expected.rank_no
   AND actual.student_name = expected.student_name
  WHERE expected.expected_amount IS DISTINCT FROM actual.amount
    AND (
      COALESCE(expected.expected_amount, 0) <> 0
      OR actual.amount IS NOT NULL
    )
)
SELECT
  lock_state.week_monday,
  lock_state.locked_at,
  lock_state.snapshot_rows,
  lock_state.actual_rows,
  lock_state.snapshot_rows = lock_state.actual_rows AS row_count_matches,
  lock_state.snapshot_checksum = lock_state.actual_checksum AS checksum_matches,
  settlement_diff.mismatch_count
FROM lock_state
CROSS JOIN settlement_diff;

SELECT jobname, schedule, command, active
FROM cron.job
WHERE jobname IN (
  'refresh_w_score_before_weekly_lock',
  'backup_weekly_leaderboards_job',
  'reward_weekly_coins_job',
  'weekly_score_update_job'
)
ORDER BY schedule, jobname;
