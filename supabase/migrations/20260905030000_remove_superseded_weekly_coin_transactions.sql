BEGIN;

DO $cleanup$
DECLARE
  v_monday DATE := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
  v_lock_time TIMESTAMPTZ;
  v_deleted_old INTEGER := 0;
  v_deleted_corrections INTEGER := 0;
BEGIN
  SELECT locked_at
  INTO v_lock_time
  FROM public.weekly_leaderboard_locks
  WHERE week_monday = v_monday;

  IF v_lock_time IS NULL THEN
    RAISE EXCEPTION '找不到当前周最终锁榜时间，停止清理旧发放流水';
  END IF;

  DELETE FROM public.coin_transactions
  WHERE transaction_type = 'settlement_correction'
    AND reason = '【周榜结算纠正】已撤销清空前结算，改按清空后最终重算榜单重新发放'
    AND created_at = v_lock_time;
  GET DIAGNOSTICS v_deleted_corrections = ROW_COUNT;

  DELETE FROM public.coin_transactions
  WHERE transaction_type = 'auto_reward'
    AND reason LIKE '【周榜结算】' || TO_CHAR(v_monday + 4, 'YYYY年MM月DD日') || '当周%'
    AND created_at < v_lock_time;
  GET DIAGNOSTICS v_deleted_old = ROW_COUNT;

  IF v_deleted_old <> 22 OR v_deleted_corrections <> 21 THEN
    RAISE EXCEPTION
      '旧周榜流水数量不符合预期，已删除旧发放 % 笔、纠正 % 笔',
      v_deleted_old,
      v_deleted_corrections;
  END IF;
END;
$cleanup$;

COMMIT;
