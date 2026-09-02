BEGIN;

DO $migration$
DECLARE
  v_core_definition TEXT;
  v_core_updated TEXT;
  v_wrapper_definition TEXT;
  v_wrapper_updated TEXT;
BEGIN
  SELECT pg_get_functiondef('public.calculate_student_week_target_core(text,date)'::REGPROCEDURE)
  INTO v_core_definition;

  v_core_updated := replace(
    v_core_definition,
    $old$IF v_active_week_count = 0 THEN
    IF v_anchor_target IS NULL THEN
      v_candidate := v_peer_ref;
      v_source := 'cold_start_peer';
    ELSIF v_is_returning THEN
      v_candidate := 0.35 * v_anchor_target + 0.65 * v_peer_ref;
      v_source := 'returning_peer_anchor';
    ELSE
      v_candidate := v_anchor_target;
      v_source := 'carry_forward';
    END IF;
  ELSE$old$,
    $new$IF v_active_week_count = 0 THEN
    v_candidate := v_peer_ref;
    v_source := CASE
      WHEN v_is_returning THEN 'returning_peer_baseline'
      ELSE 'cold_start_peer'
    END;
  ELSE$new$
  );

  v_core_updated := replace(
    v_core_updated,
    $old$  IF v_anchor_target IS NOT NULL THEN
    v_upper_limit :=$old$,
    $new$  IF v_anchor_target IS NOT NULL AND v_active_week_count > 0 THEN
    v_upper_limit :=$new$
  );

  v_core_updated := replace(
    v_core_updated,
    $old$percentile_cont(0.50) WITHIN GROUP (ORDER BY psr.student_week_ref)::FLOAT8$old$,
    $new$AVG(psr.student_week_ref)::FLOAT8$new$
  );

  v_core_updated := replace(
    v_core_updated,
    $old$percentile_cont(0.50) WITHIN GROUP (ORDER BY sr.target)::FLOAT8$old$,
    $new$AVG(sr.target)::FLOAT8$new$
  );

  IF v_core_updated = v_core_definition
     OR v_core_updated NOT LIKE '%returning_peer_baseline%'
     OR v_core_updated NOT LIKE '%v_active_week_count > 0%'
     OR v_core_updated NOT LIKE '%AVG(psr.student_week_ref)%'
     OR v_core_updated NOT LIKE '%AVG(sr.target)%' THEN
    RAISE EXCEPTION '目标核心函数未匹配到预期逻辑，停止迁移';
  END IF;

  EXECUTE v_core_updated;

  SELECT pg_get_functiondef('public.calculate_student_week_target(text,date)'::REGPROCEDURE)
  INTO v_wrapper_definition;

  v_wrapper_updated := replace(
    v_wrapper_definition,
    $old$AND calculated_row.recent_active_weeks = 0 THEN$old$,
    $new$AND calculated_row.recent_active_weeks = 0
     AND calculated_row.target_source NOT IN ('returning_peer_baseline', 'cold_start_peer') THEN$new$
  );

  IF v_wrapper_updated = v_wrapper_definition
     OR v_wrapper_updated NOT LIKE '%calculated_row.target_source NOT IN%' THEN
    RAISE EXCEPTION '目标锁定包装函数未匹配到预期逻辑，停止迁移';
  END IF;

  EXECUTE v_wrapper_updated;
END;
$migration$;

COMMENT ON FUNCTION public.calculate_student_week_target(TEXT, DATE) IS
'New and returning students start from the historical same-department average weekly reference. After active weeks accumulate, targets adapt to the student''s actual recent practice while weekly targets remain locked.';

SELECT public.refresh_student_week_targets(
  DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE,
  TRUE
);

NOTIFY pgrst, 'reload schema';

COMMIT;
