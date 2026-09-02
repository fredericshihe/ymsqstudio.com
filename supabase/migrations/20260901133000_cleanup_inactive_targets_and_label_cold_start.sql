BEGIN;

DO $migration$
DECLARE
  v_definition TEXT;
  v_updated TEXT;
BEGIN
  SELECT pg_get_functiondef('public.calculate_student_week_target_core(text,date)'::REGPROCEDURE)
  INTO v_definition;

  v_updated := replace(
    v_definition,
    $old$v_source := CASE
      WHEN v_is_returning THEN 'returning_peer_baseline'
      ELSE 'cold_start_peer'
    END;$old$,
    $new$v_source := CASE
      WHEN v_last_session IS NULL THEN 'cold_start_peer'
      WHEN v_is_returning THEN 'returning_peer_baseline'
      ELSE 'carry_forward'
    END;$new$
  );

  IF v_updated = v_definition
     OR v_updated NOT LIKE '%WHEN v_last_session IS NULL THEN ''cold_start_peer''%'
     OR v_updated NOT LIKE '%returning_peer_baseline%' THEN
    RAISE EXCEPTION '目标来源标签未匹配到预期逻辑，停止迁移';
  END IF;

  EXECUTE v_updated;
END;
$migration$;

DELETE FROM public.student_week_targets target
WHERE NOT EXISTS (
  SELECT 1
  FROM public.student_database student
  WHERE student.name = target.student_name
    AND COALESCE(student.archived, FALSE) IS FALSE
    AND NULLIF(BTRIM(student.name), '') IS NOT NULL
);

SELECT public.refresh_student_week_targets(
  DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE,
  TRUE
);

NOTIFY pgrst, 'reload schema';

COMMIT;
