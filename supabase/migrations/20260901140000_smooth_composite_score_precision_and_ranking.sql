BEGIN;

DO $migration$
DECLARE
  v_core_definition  TEXT;
  v_core_updated     TEXT;
  v_board_definition TEXT;
  v_board_updated    TEXT;
BEGIN
  SELECT pg_get_functiondef('public.compute_student_score_rule_v2_core(text,date)'::REGPROCEDURE)
  INTO v_core_definition;

  v_core_updated := replace(
    v_core_definition,
    $old$  v_w_score := CASE
    WHEN v_week_completion <= 0.0 THEN 0.0
    WHEN v_week_completion < 0.50 THEN 0.20 + 0.50 * (v_week_completion / 0.50)
    WHEN v_week_completion < 1.00 THEN 0.70 + 0.20 * ((v_week_completion - 0.50) / 0.50)
    WHEN v_week_completion < 1.10 THEN 0.90 + 0.05 * ((v_week_completion - 1.00) / 0.10)
    ELSE 0.95
  END;
  v_w_score := GREATEST(0.0, LEAST(0.95, v_w_score));$old$,
    $new$  v_w_score := CASE
    WHEN v_week_completion <= 0.0 THEN 0.0
    WHEN v_week_completion < 0.50 THEN 0.20 + 0.50 * (v_week_completion / 0.50)
    WHEN v_week_completion < 1.00 THEN 0.70 + 0.20 * ((v_week_completion - 0.50) / 0.50)
    WHEN v_week_completion < 1.10 THEN 0.90 + 0.05 * ((v_week_completion - 1.00) / 0.10)
    ELSE LEAST(
      1.0,
      0.95 + 0.05 * (1.0 - EXP(-1.20 * (v_week_completion - 1.10)))
    )
  END;
  v_w_score := GREATEST(0.0, LEAST(1.0, v_w_score));$new$
  );

  v_core_updated := replace(
    v_core_updated,
    $old$  )::NUMERIC * 100.0, 1);$old$,
    $new$  )::NUMERIC * 100.0, 2);$new$
  );

  IF v_core_updated = v_core_definition
     OR v_core_updated NOT LIKE '%EXP(-1.20%'
     OR v_core_updated NOT LIKE '%100.0, 2)%' THEN
    RAISE EXCEPTION '综合分核心函数未匹配到预期逻辑，停止迁移';
  END IF;

  EXECUTE v_core_updated;

  SELECT pg_get_functiondef('public.get_weekly_leaderboards()'::REGPROCEDURE)
  INTO v_board_definition;

  v_board_updated := replace(
    v_board_definition,
    $old$'综合榜'::TEXT AS board,
    RANK() OVER (
      ORDER BY rp.display_score DESC NULLS LAST,
               rp.mean_duration DESC NULLS LAST,
               rp.record_count DESC NULLS LAST
    )::INTEGER AS rank_no,$old$,
    $new$'综合榜'::TEXT AS board,
    DENSE_RANK() OVER (
      ORDER BY rp.display_score DESC NULLS LAST
    )::INTEGER AS rank_no,$new$
  );

  IF v_board_updated = v_board_definition THEN
    v_board_updated := replace(
      v_board_definition,
      $old$'综合榜'::TEXT AS board,
    DENSE_RANK() OVER (
      ORDER BY rp.display_score DESC NULLS LAST,
               rp.mean_duration DESC NULLS LAST,
               rp.record_count DESC NULLS LAST
    )::INTEGER AS rank_no,$old$,
      $new$'综合榜'::TEXT AS board,
    DENSE_RANK() OVER (
      ORDER BY rp.display_score DESC NULLS LAST
    )::INTEGER AS rank_no,$new$
    );
  END IF;

  IF v_board_updated = v_board_definition
     OR v_board_updated NOT LIKE '%DENSE_RANK()%'
     OR v_board_updated LIKE $$'综合榜'::TEXT AS board,%DENSE_RANK() OVER (%rp.mean_duration DESC NULLS LAST%$$ THEN
    RAISE EXCEPTION '综合榜排名函数未匹配到预期逻辑，停止迁移';
  END IF;

  EXECUTE v_board_updated;
END;
$migration$;

COMMENT ON FUNCTION public.compute_student_score_rule_v2_core(TEXT, DATE) IS
'Composite scores retain two decimal places. The weekly progress dimension increases smoothly above 110% with diminishing returns instead of flattening all high-completion students to the same value.';

COMMENT ON FUNCTION public.get_weekly_leaderboards() IS
'The composite leaderboard ranks only by the displayed composite score using dense ranks. Exact score ties share a rank; no hidden duration or record-count tiebreakers are applied.';

SELECT public.refresh_all_w_scores();

NOTIFY pgrst, 'reload schema';

COMMIT;
