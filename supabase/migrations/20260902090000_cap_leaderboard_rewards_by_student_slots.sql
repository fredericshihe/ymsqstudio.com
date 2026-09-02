BEGIN;

DO $migration$
DECLARE
  v_board_definition  TEXT;
  v_board_updated     TEXT;
  v_reward_definition TEXT;
  v_reward_updated    TEXT;
BEGIN
  SELECT pg_get_functiondef('public.get_weekly_leaderboards()'::REGPROCEDURE)
  INTO v_board_definition;

  v_board_updated := regexp_replace(
    v_board_definition,
    $$comp_top10 AS \(
\s*SELECT c\.student_name
\s*FROM comp c
\s*WHERE c\.rank_no <= 10
\s*\),$$,
    $$comp_top10 AS (
  SELECT ranked.student_name
  FROM (
    SELECT c.student_name,
           ROW_NUMBER() OVER (
             ORDER BY c.rank_no, c.student_name
           ) AS slot_no
    FROM comp c
  ) ranked
  WHERE ranked.slot_no <= 10
),$$,
    1,
    1,
    'n'
  );

  v_board_updated := regexp_replace(
    v_board_updated,
    $$ORDER BY board,\s*rank_no;$$,
    $$ORDER BY board, rank_no, student_name;$$,
    1,
    1,
    'n'
  );

  IF v_board_updated = v_board_definition
     OR v_board_updated NOT LIKE '%ROW_NUMBER() OVER%'
     OR v_board_updated NOT LIKE '%ranked.slot_no <= 10%'
     OR v_board_updated NOT LIKE '%ORDER BY board, rank_no, student_name%' THEN
    RAISE EXCEPTION '排行榜名额逻辑未匹配到预期版本，停止迁移';
  END IF;

  EXECUTE v_board_updated;

  SELECT pg_get_functiondef('public.reward_weekly_coins()'::REGPROCEDURE)
  INTO v_reward_definition;

  v_reward_updated := replace(
    v_reward_definition,
    $old$FOR reward_row IN
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
  LOOP$old$,
    $new$FOR reward_row IN
    SELECT
      ranked.board,
      ranked.rank_no,
      ranked.student_name,
      ranked.display_score,
      ranked.alpha,
      ranked.trend_score,
      ranked.recent10_outlier_rate
    FROM (
      SELECT
        history.board,
        history.rank_no,
        history.student_name,
        history.display_score,
        history.alpha,
        history.trend_score,
        history.recent10_outlier_rate,
        ROW_NUMBER() OVER (
          PARTITION BY history.board
          ORDER BY history.rank_no, history.student_name
        ) AS reward_slot
      FROM public.weekly_leaderboard_history history
      WHERE history.week_monday = v_monday
        AND history.board IN ('综合榜', '稳定榜', '守则榜', '进步榜')
    ) ranked
    WHERE ranked.reward_slot <= CASE
      WHEN ranked.board = '综合榜' THEN 10
      ELSE 6
    END
    ORDER BY ranked.board, ranked.rank_no, ranked.student_name
  LOOP$new$
  );

  v_reward_updated := replace(
    v_reward_updated,
    $old$FOR reward_row IN
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
  LOOP$old$,
    $new$FOR reward_row IN
    SELECT
      ranked.board,
      ranked.rank_no,
      ranked.student_name,
      ranked.display_score,
      ranked.completed_minutes,
      ranked.completion_ratio,
      ranked.shortfall_minutes
    FROM (
      SELECT
        history.board,
        history.rank_no,
        history.student_name,
        history.display_score,
        history.completed_minutes,
        history.completion_ratio,
        history.shortfall_minutes,
        ROW_NUMBER() OVER (
          ORDER BY history.rank_no, history.student_name
        ) AS reward_slot
      FROM public.weekly_leaderboard_history history
      WHERE history.week_monday = v_monday
        AND history.board = '缩水榜'
    ) ranked
    WHERE ranked.reward_slot <= 6
    ORDER BY ranked.rank_no, ranked.student_name
  LOOP$new$
  );

  IF v_reward_updated = v_reward_definition
     OR v_reward_updated NOT LIKE '%PARTITION BY history.board%'
     OR v_reward_updated NOT LIKE '%ranked.reward_slot <= CASE%'
     OR v_reward_updated NOT LIKE '%ranked.reward_slot <= 6%' THEN
    RAISE EXCEPTION '音符币结算名额逻辑未匹配到预期版本，停止迁移';
  END IF;

  EXECUTE v_reward_updated;
END;
$migration$;

COMMENT ON FUNCTION public.get_weekly_leaderboards() IS
'Leaderboard display keeps dense ranks for ties, while top lists reserve one slot per student: composite top 10 students and each other leaderboard top 6 students. Ties at the boundary are deterministically capped by student name.';

COMMENT ON FUNCTION public.reward_weekly_coins() IS
'Weekly coin rewards and shrink penalties are capped by student slots, not only rank numbers. Composite rewards use at most 10 students; stable, discipline, progress, and shrink rules use at most 6 students. Equal ranks retain equal reward tiers when selected.';

NOTIFY pgrst, 'reload schema';

COMMIT;
