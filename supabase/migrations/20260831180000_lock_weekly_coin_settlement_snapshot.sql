BEGIN;

CREATE TABLE IF NOT EXISTS public.weekly_leaderboard_locks (
  week_monday      DATE PRIMARY KEY,
  locked_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  snapshot_rows    INTEGER NOT NULL CHECK (snapshot_rows >= 0),
  snapshot_checksum TEXT NOT NULL,
  lock_source      TEXT NOT NULL DEFAULT 'backup_weekly_leaderboards'
);

ALTER TABLE public.weekly_leaderboard_locks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.weekly_leaderboard_locks FROM anon, authenticated;

COMMENT ON TABLE public.weekly_leaderboard_locks IS
'Immutable weekly leaderboard lock metadata used by coin settlement. Row count and checksum must match the locked snapshot.';

CREATE OR REPLACE FUNCTION public.get_weekly_leaderboard_snapshot_checksum(
  p_week_monday DATE
)
RETURNS TEXT
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT MD5(COALESCE(
    STRING_AGG(
      (TO_JSONB(history) - 'id')::TEXT,
      E'\n'
      ORDER BY history.board, history.rank_no, history.student_name, history.id::TEXT
    ),
    ''
  ))
  FROM public.weekly_leaderboard_history history
  WHERE history.week_monday = p_week_monday;
$function$;

REVOKE ALL ON FUNCTION public.get_weekly_leaderboard_snapshot_checksum(DATE)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.backup_weekly_leaderboards()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_monday DATE := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
  v_snapshot_rows INTEGER := 0;
  v_snapshot_checksum TEXT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('weekly-leaderboard-lock:' || v_monday::TEXT));

  IF EXISTS (
    SELECT 1
    FROM public.weekly_leaderboard_locks lock_row
    WHERE lock_row.week_monday = v_monday
  ) THEN
    RAISE EXCEPTION '本周排行榜已于 21:30 锁定，禁止重复覆盖：%', v_monday;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.weekly_coin_reward_log reward_log
    WHERE reward_log.week_monday = v_monday
  ) OR EXISTS (
    SELECT 1
    FROM public.weekly_coin_reward_detail reward_detail
    WHERE reward_detail.week_monday = v_monday
  ) THEN
    RAISE EXCEPTION '本周音符币已经产生结算记录，禁止重新锁榜：%', v_monday;
  END IF;

  DELETE FROM public.weekly_leaderboard_history history
  WHERE history.week_monday = v_monday;

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
    v_monday,
    (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE,
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
    NULL::NUMERIC,
    NULL::NUMERIC,
    NULL::NUMERIC,
    NULL::NUMERIC,
    NULL::INTEGER
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

  GET DIAGNOSTICS v_snapshot_rows = ROW_COUNT;
  v_snapshot_checksum := public.get_weekly_leaderboard_snapshot_checksum(v_monday);

  INSERT INTO public.weekly_leaderboard_locks (
    week_monday,
    locked_at,
    snapshot_rows,
    snapshot_checksum,
    lock_source
  ) VALUES (
    v_monday,
    NOW(),
    v_snapshot_rows,
    v_snapshot_checksum,
    'backup_weekly_leaderboards'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.backup_weekly_leaderboards() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.reward_weekly_coins()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_monday DATE;
  v_friday_bjt DATE;
  v_week_label TEXT;
  reward_row RECORD;
  lock_row RECORD;
  v_snapshot_rows INTEGER;
  v_snapshot_checksum TEXT;
  v_amount INTEGER;
  v_reason TEXT;
  v_title TEXT;
  v_total_events INTEGER := 0;
  v_reward_coins INTEGER := 0;
  v_penalty_coins INTEGER := 0;
  v_net_coins INTEGER := 0;
  v_comp_cnt INTEGER := 0;
  v_comp_coins INTEGER := 0;
  v_stable_cnt INTEGER := 0;
  v_stable_coins INTEGER := 0;
  v_rules_cnt INTEGER := 0;
  v_rules_coins INTEGER := 0;
  v_prog_cnt INTEGER := 0;
  v_prog_coins INTEGER := 0;
  v_shrink_cnt INTEGER := 0;
BEGIN
  IF NOT COALESCE(
    (
      SELECT setting.value::BOOLEAN
      FROM public.system_settings setting
      WHERE setting.key = 'auto_coin_reward_enabled'
    ),
    TRUE
  ) THEN
    RETURN '🔴 自动音符币结算已关闭，本次奖励与缩水榜扣币均跳过。';
  END IF;

  v_monday := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
  v_friday_bjt := v_monday + 4;

  IF v_friday_bjt < '2026-03-27'::DATE THEN
    RETURN '⏳ 正式结算日期为 2026年3月27日，当前周五为 '
      || TO_CHAR(v_friday_bjt, 'YYYY年MM月DD日') || '，跳过。';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('weekly-leaderboard-lock:' || v_monday::TEXT));

  IF EXISTS (
    SELECT 1
    FROM public.weekly_coin_reward_log reward_log
    WHERE reward_log.week_monday = v_monday
  ) THEN
    RETURN '⚠️ ' || v_monday::TEXT || ' 当周已结算，跳过。';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.weekly_coin_reward_detail reward_detail
    WHERE reward_detail.week_monday = v_monday
  ) THEN
    RETURN '⚠️ ' || v_monday::TEXT || ' 当周结算明细已存在，判定为已结算。';
  END IF;

  SELECT
    leaderboard_lock.week_monday,
    leaderboard_lock.locked_at,
    leaderboard_lock.snapshot_rows,
    leaderboard_lock.snapshot_checksum
  INTO lock_row
  FROM public.weekly_leaderboard_locks leaderboard_lock
  WHERE leaderboard_lock.week_monday = v_monday
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '21:30 锁榜快照不存在，停止音符币结算：%', v_monday;
  END IF;

  SELECT COUNT(*)::INTEGER
  INTO v_snapshot_rows
  FROM public.weekly_leaderboard_history history
  WHERE history.week_monday = v_monday;

  v_snapshot_checksum := public.get_weekly_leaderboard_snapshot_checksum(v_monday);

  IF v_snapshot_rows <> lock_row.snapshot_rows
     OR v_snapshot_checksum IS DISTINCT FROM lock_row.snapshot_checksum THEN
    RAISE EXCEPTION
      '21:30 锁榜快照完整性校验失败，停止音符币结算：%（锁定 % 行，当前 % 行）',
      v_monday,
      lock_row.snapshot_rows,
      v_snapshot_rows;
  END IF;

  v_week_label := TO_CHAR(v_friday_bjt, 'YYYY年MM月DD日') || '当周';

  FOR reward_row IN
    SELECT
      history.board,
      history.rank_no,
      history.student_name,
      history.display_score,
      history.alpha,
      history.trend_score,
      history.recent10_outlier_rate
    FROM public.weekly_leaderboard_history history
    WHERE history.week_monday = v_monday
      AND history.board IN ('综合榜', '稳定榜', '守则榜', '进步榜')
    ORDER BY history.board, history.rank_no, history.student_name
  LOOP
    v_amount := 0;
    v_reason := NULL;
    v_title := NULL;

    IF reward_row.board = '综合榜' THEN
      IF reward_row.rank_no = 1 THEN v_amount := 80; v_title := '榜首霸主';
      ELSIF reward_row.rank_no BETWEEN 2 AND 3 THEN v_amount := 64; v_title := '荣耀亚军';
      ELSIF reward_row.rank_no BETWEEN 4 AND 6 THEN v_amount := 48; v_title := '实力季军';
      ELSIF reward_row.rank_no BETWEEN 7 AND 10 THEN v_amount := 32; v_title := '优秀达人';
      END IF;

      IF v_amount > 0 THEN
        v_reason := '【周榜结算】' || v_week_label
          || ' · 综合榜第' || reward_row.rank_no || '名（' || v_title || '）'
          || ' · 综合分 ' || ROUND(reward_row.display_score, 1)::TEXT || ' 分';
        v_comp_cnt := v_comp_cnt + 1;
        v_comp_coins := v_comp_coins + v_amount;
      END IF;
    ELSIF reward_row.board = '稳定榜' THEN
      IF reward_row.rank_no = 1 THEN v_amount := 12;
      ELSIF reward_row.rank_no BETWEEN 2 AND 3 THEN v_amount := 9;
      ELSIF reward_row.rank_no BETWEEN 4 AND 6 THEN v_amount := 5;
      END IF;

      IF v_amount > 0 THEN
        v_reason := '【周榜结算】' || v_week_label
          || ' · 稳定榜第' || reward_row.rank_no || '名'
          || ' · α 可信度 ' || ROUND(COALESCE(reward_row.alpha, 0), 3)::TEXT;
        v_stable_cnt := v_stable_cnt + 1;
        v_stable_coins := v_stable_coins + v_amount;
      END IF;
    ELSIF reward_row.board = '守则榜' THEN
      IF reward_row.rank_no = 1 THEN v_amount := 11;
      ELSIF reward_row.rank_no BETWEEN 2 AND 3 THEN v_amount := 8;
      ELSIF reward_row.rank_no BETWEEN 4 AND 6 THEN v_amount := 5;
      END IF;

      IF v_amount > 0 THEN
        v_reason := '【周榜结算】' || v_week_label
          || ' · 守则榜第' || reward_row.rank_no || '名'
          || ' · 近10次异常率 '
          || ROUND(COALESCE(reward_row.recent10_outlier_rate, 0) * 100, 1)::TEXT || '%';
        v_rules_cnt := v_rules_cnt + 1;
        v_rules_coins := v_rules_coins + v_amount;
      END IF;
    ELSIF reward_row.board = '进步榜' THEN
      IF reward_row.rank_no = 1 THEN v_amount := 10;
      ELSIF reward_row.rank_no BETWEEN 2 AND 3 THEN v_amount := 6;
      ELSIF reward_row.rank_no BETWEEN 4 AND 6 THEN v_amount := 4;
      END IF;

      IF v_amount > 0 THEN
        v_reason := '【周榜结算】' || v_week_label
          || ' · 进步榜第' || reward_row.rank_no || '名'
          || ' · 本周进步 +' || ROUND(COALESCE(reward_row.trend_score, 0))::TEXT || ' 分';
        v_prog_cnt := v_prog_cnt + 1;
        v_prog_coins := v_prog_coins + v_amount;
      END IF;
    END IF;

    IF v_amount > 0 AND v_reason IS NOT NULL THEN
      PERFORM public.adjust_student_coins(
        p_student_name := reward_row.student_name,
        p_amount := v_amount,
        p_reason := v_reason,
        p_type := 'auto_reward'
      );

      INSERT INTO public.weekly_coin_reward_detail (
        week_monday,
        board,
        rank_no,
        student_name,
        amount,
        reason,
        display_score,
        alpha,
        trend_score,
        recent10_outlier_rate
      ) VALUES (
        v_monday,
        reward_row.board,
        reward_row.rank_no,
        reward_row.student_name,
        v_amount,
        v_reason,
        reward_row.display_score,
        reward_row.alpha,
        reward_row.trend_score,
        reward_row.recent10_outlier_rate
      );

      v_total_events := v_total_events + 1;
      v_reward_coins := v_reward_coins + v_amount;
      v_net_coins := v_net_coins + v_amount;
    END IF;
  END LOOP;

  FOR reward_row IN
    SELECT
      history.board,
      history.rank_no,
      history.student_name,
      history.display_score,
      history.completed_minutes,
      history.completion_ratio,
      history.shortfall_minutes
    FROM public.weekly_leaderboard_history history
    WHERE history.week_monday = v_monday
      AND history.board = '缩水榜'
      AND history.rank_no <= 6
    ORDER BY history.rank_no, history.student_name
  LOOP
    IF reward_row.rank_no = 1 THEN v_amount := -10;
    ELSIF reward_row.rank_no BETWEEN 2 AND 3 THEN v_amount := -6;
    ELSIF reward_row.rank_no BETWEEN 4 AND 6 THEN v_amount := -4;
    ELSE v_amount := 0;
    END IF;

    IF v_amount < 0 THEN
      v_reason := '【周榜结算】' || v_week_label
        || ' · 缩水榜第' || reward_row.rank_no || '名'
        || ' · 当前应完成进度 '
        || ROUND(COALESCE(reward_row.completion_ratio, 0) * 100, 1)::TEXT || '%'
        || ' · 本周累计 '
        || ROUND(COALESCE(reward_row.completed_minutes, 0), 0)::TEXT || ' 分钟'
        || ' · 当前还差 '
        || ROUND(COALESCE(reward_row.shortfall_minutes, 0), 0)::TEXT || ' 分钟';

      PERFORM public.adjust_student_coins(
        p_student_name := reward_row.student_name,
        p_amount := v_amount,
        p_reason := v_reason,
        p_type := 'auto_penalty'
      );

      INSERT INTO public.weekly_coin_reward_detail (
        week_monday,
        board,
        rank_no,
        student_name,
        amount,
        reason,
        display_score
      ) VALUES (
        v_monday,
        reward_row.board,
        reward_row.rank_no,
        reward_row.student_name,
        v_amount,
        v_reason,
        reward_row.display_score
      );

      v_total_events := v_total_events + 1;
      v_penalty_coins := v_penalty_coins + ABS(v_amount);
      v_net_coins := v_net_coins + v_amount;
      v_shrink_cnt := v_shrink_cnt + 1;
    END IF;
  END LOOP;

  INSERT INTO public.weekly_coin_reward_log (
    week_monday,
    total_events,
    total_coins,
    summary
  ) VALUES (
    v_monday,
    v_total_events,
    v_net_coins,
    jsonb_build_object(
      '综合榜', jsonb_build_object('人次', v_comp_cnt, '币', v_comp_coins),
      '稳定榜', jsonb_build_object('人次', v_stable_cnt, '币', v_stable_coins),
      '守则榜', jsonb_build_object('人次', v_rules_cnt, '币', v_rules_coins),
      '进步榜', jsonb_build_object('人次', v_prog_cnt, '币', v_prog_coins),
      '缩水榜', jsonb_build_object('人次', v_shrink_cnt, '币', -v_penalty_coins),
      '奖励合计', v_reward_coins,
      '扣币合计', v_penalty_coins,
      '净变化', v_net_coins,
      '锁榜时间', lock_row.locked_at,
      '锁榜行数', lock_row.snapshot_rows,
      '锁榜校验码', lock_row.snapshot_checksum
    )
  );

  RETURN '✅ ' || v_week_label || ' 音符币结算完成（使用21:30锁榜快照）'
    || ' | 奖励 ' || v_reward_coins::TEXT || ' 枚'
    || ' · 缩水榜扣除 ' || v_penalty_coins::TEXT || ' 枚'
    || ' · 净变化 ' || v_net_coins::TEXT || ' 枚'
    || ' | 共 ' || v_total_events::TEXT || ' 笔';
END;
$function$;

COMMENT ON FUNCTION public.reward_weekly_coins() IS
'Friday 21:32 coin settlement reads only the immutable 21:30 leaderboard snapshot. Missing or modified snapshots abort settlement. Rewards and shrink penalties share the auto_coin_reward_enabled switch.';

REVOKE ALL ON FUNCTION public.reward_weekly_coins() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reward_weekly_coins() TO service_role;

DO $block$
BEGIN
  PERFORM cron.unschedule('refresh_w_score_before_weekly_lock');
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$block$;

SELECT cron.schedule(
  'refresh_w_score_before_weekly_lock',
  '25 13 * * 5',
  $$SELECT public.refresh_all_w_scores();$$
);

NOTIFY pgrst, 'reload schema';

COMMIT;
