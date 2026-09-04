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

  IF target_definition LIKE '%PERFORM public.auto_clear_open_sessions();%' THEN
    NULL;
  ELSE
    updated_definition := REPLACE(
      target_definition,
      E'BEGIN\n  PERFORM pg_advisory_xact_lock',
      E'BEGIN\n  PERFORM public.auto_clear_open_sessions();\n\n  PERFORM pg_advisory_xact_lock'
    );

    IF updated_definition = target_definition THEN
      RAISE EXCEPTION '无法把自动清空插入锁榜函数';
    END IF;

    EXECUTE updated_definition;
  END IF;
END;
$migration$;

DO $cron$
BEGIN
  PERFORM cron.unschedule('backup_weekly_leaderboards_job');
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$cron$;

SELECT cron.schedule(
  'backup_weekly_leaderboards_job',
  '33 13 * * 5',
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

DO $cron$
BEGIN
  PERFORM cron.unschedule('weekly_score_update_job');
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$cron$;

SELECT cron.schedule(
  'weekly_score_update_job',
  '31 13 * * 5',
  $$SELECT public.run_weekly_score_update();$$
);

CREATE OR REPLACE FUNCTION public.reconcile_weekly_coin_settlement(
  p_week_monday DATE DEFAULT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_monday DATE := COALESCE(
    p_week_monday,
    DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
  );
  v_old RECORD;
  v_old_total INTEGER;
  v_current_balance INTEGER;
  v_current_semester_earned INTEGER;
  v_correction INTEGER;
  v_reward_result TEXT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('weekly-leaderboard-lock:' || v_monday::TEXT));
  PERFORM public.auto_clear_open_sessions();
  PERFORM public.run_weekly_score_update();
  PERFORM public.refresh_all_w_scores();

  CREATE TEMP TABLE settlement_old_payouts ON COMMIT DROP AS
  SELECT
    detail.student_name,
    SUM(detail.amount)::INTEGER AS total_amount
  FROM public.weekly_coin_reward_detail detail
  WHERE detail.week_monday = v_monday
  GROUP BY detail.student_name;

  SELECT COALESCE(SUM(total_amount), 0)::INTEGER
  INTO v_old_total
  FROM settlement_old_payouts;

  CREATE TEMP TABLE settlement_final_snapshot ON COMMIT DROP AS
  SELECT
    v_monday AS week_monday,
    (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS backup_date,
    leaderboard.board,
    leaderboard.rank_no,
    leaderboard.student_name,
    leaderboard.student_major,
    leaderboard.student_grade,
    leaderboard.display_score,
    leaderboard.alpha,
    leaderboard.trend_score,
    leaderboard.mean_duration,
    leaderboard.record_count,
    leaderboard.recent10_outlier_rate,
    leaderboard.recent10_mean_dur,
    leaderboard.recent10_count,
    NULL::NUMERIC AS target_minutes,
    NULL::NUMERIC AS completed_minutes,
    NULL::NUMERIC AS completion_ratio,
    NULL::NUMERIC AS shortfall_minutes,
    NULL::INTEGER AS week_session_count
  FROM public.get_weekly_leaderboards() leaderboard

  UNION ALL

  SELECT
    v_monday,
    (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE,
    decline.board,
    decline.rank_no,
    decline.student_name,
    decline.student_major,
    decline.student_grade,
    decline.display_score,
    decline.alpha,
    decline.trend_score,
    decline.mean_duration,
    decline.record_count,
    decline.recent10_outlier_rate,
    decline.recent10_mean_dur,
    decline.recent10_count,
    decline.target_minutes,
    decline.completed_minutes,
    decline.completion_ratio,
    decline.shortfall_minutes,
    decline.week_session_count
  FROM public.get_weekly_decline_leaderboard(v_monday) decline;

  FOR v_old IN
    SELECT
      old_payout.student_name,
      old_payout.total_amount,
      COALESCE(new_payout.total_amount, 0)::INTEGER AS new_amount
    FROM settlement_old_payouts old_payout
    LEFT JOIN (
      SELECT
        ranked.student_name,
        SUM(
          CASE
            WHEN ranked.board = '综合榜' AND ranked.rank_no = 1 THEN 80
            WHEN ranked.board = '综合榜' AND ranked.rank_no BETWEEN 2 AND 3 THEN 64
            WHEN ranked.board = '综合榜' AND ranked.rank_no BETWEEN 4 AND 6 THEN 48
            WHEN ranked.board = '综合榜' AND ranked.rank_no BETWEEN 7 AND 10 THEN 32
            WHEN ranked.board = '稳定榜' AND ranked.rank_no = 1 THEN 12
            WHEN ranked.board = '稳定榜' AND ranked.rank_no BETWEEN 2 AND 3 THEN 9
            WHEN ranked.board = '稳定榜' AND ranked.rank_no BETWEEN 4 AND 6 THEN 5
            WHEN ranked.board = '守则榜' AND ranked.rank_no = 1 THEN 11
            WHEN ranked.board = '守则榜' AND ranked.rank_no BETWEEN 2 AND 3 THEN 8
            WHEN ranked.board = '守则榜' AND ranked.rank_no BETWEEN 4 AND 6 THEN 5
            WHEN ranked.board = '进步榜' AND ranked.rank_no = 1 THEN 10
            WHEN ranked.board = '进步榜' AND ranked.rank_no BETWEEN 2 AND 3 THEN 6
            WHEN ranked.board = '进步榜' AND ranked.rank_no BETWEEN 4 AND 6 THEN 4
            WHEN ranked.board = '缩水榜' AND ranked.rank_no = 1 THEN -10
            WHEN ranked.board = '缩水榜' AND ranked.rank_no BETWEEN 2 AND 3 THEN -6
            WHEN ranked.board = '缩水榜' AND ranked.rank_no BETWEEN 4 AND 6 THEN -4
            ELSE 0
          END
        )::INTEGER AS total_amount
      FROM (
        SELECT
          snapshot.board,
          snapshot.rank_no,
          snapshot.student_name,
          ROW_NUMBER() OVER (
            PARTITION BY snapshot.board
            ORDER BY snapshot.rank_no, snapshot.student_name
          ) AS reward_slot
        FROM settlement_final_snapshot snapshot
        WHERE snapshot.board IN ('综合榜', '稳定榜', '守则榜', '进步榜', '缩水榜')
      ) ranked
      WHERE ranked.reward_slot <= CASE
        WHEN ranked.board = '综合榜' THEN 10
        ELSE 6
      END
      GROUP BY ranked.student_name
    ) new_payout ON new_payout.student_name = old_payout.student_name
  LOOP
    v_correction := -v_old.total_amount;
    INSERT INTO public.student_coins (student_name, balance, semester_earned)
    VALUES (v_old.student_name, 0, 0)
    ON CONFLICT (student_name) DO NOTHING;

    SELECT coins.balance, coins.semester_earned
    INTO v_current_balance, v_current_semester_earned
    FROM public.student_coins coins
    WHERE coins.student_name = v_old.student_name
    FOR UPDATE;

    UPDATE public.student_coins
    SET balance = v_current_balance + v_correction,
        semester_earned = CASE
          WHEN v_correction >= 0 THEN v_current_semester_earned + v_correction
          ELSE GREATEST(0, v_current_semester_earned + v_correction)
        END,
        updated_at = NOW()
    WHERE student_name = v_old.student_name;

    INSERT INTO public.coin_transactions (
      student_name,
      amount,
      balance_after,
      reason,
      transaction_type
    ) VALUES (
      v_old.student_name,
      v_correction,
      v_current_balance + v_correction,
      '【周榜结算纠正】已撤销清空前结算，改按清空后最终重算榜单重新发放',
      'settlement_correction'
    );
  END LOOP;

  DELETE FROM public.weekly_coin_reward_detail
  WHERE week_monday = v_monday;
  DELETE FROM public.weekly_coin_reward_log
  WHERE week_monday = v_monday;
  DELETE FROM public.weekly_leaderboard_locks
  WHERE week_monday = v_monday;
  DELETE FROM public.weekly_leaderboard_history
  WHERE week_monday = v_monday;

  INSERT INTO public.weekly_leaderboard_history (
    week_monday,
    backup_date,
    board,
    rank_no,
    student_name,
    student_major,
    student_grade,
    display_score,
    alpha,
    trend_score,
    mean_duration,
    record_count,
    recent10_outlier_rate,
    recent10_mean_dur,
    recent10_count,
    target_minutes,
    completed_minutes,
    completion_ratio,
    shortfall_minutes,
    week_session_count
  )
  SELECT
    week_monday,
    backup_date,
    board,
    rank_no,
    student_name,
    student_major,
    student_grade,
    display_score,
    alpha,
    trend_score,
    mean_duration,
    record_count,
    recent10_outlier_rate,
    recent10_mean_dur,
    recent10_count,
    target_minutes,
    completed_minutes,
    completion_ratio,
    shortfall_minutes,
    week_session_count
  FROM settlement_final_snapshot;

  INSERT INTO public.weekly_leaderboard_locks (
    week_monday,
    locked_at,
    snapshot_rows,
    snapshot_checksum,
    lock_source
  )
  SELECT
    v_monday,
    NOW(),
    COUNT(*)::INTEGER,
    public.get_weekly_leaderboard_snapshot_checksum(v_monday),
    'reconcile_after_auto_clear'
  FROM public.weekly_leaderboard_history
  WHERE week_monday = v_monday;

  v_reward_result := public.reward_weekly_coins();

  RETURN v_reward_result || ' | 已按清空后最终重算榜单纠正旧流水 ' || v_old_total::TEXT || ' 币';
END;
$function$;

REVOKE ALL ON FUNCTION public.reconcile_weekly_coin_settlement(DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reconcile_weekly_coin_settlement(DATE) TO service_role;

SELECT public.reconcile_weekly_coin_settlement(
  DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
);

NOTIFY pgrst, 'reload schema';

COMMIT;
