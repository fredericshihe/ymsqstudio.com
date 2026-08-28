BEGIN;

CREATE OR REPLACE FUNCTION public.reconcile_practice_alerts_incremental(
  p_business_date DATE,
  p_alerts JSONB,
  p_student_names TEXT[]
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_previous_lifecycle_write TEXT := current_setting(
    'app.practice_alerts_lifecycle_write', TRUE
  );
  v_safe_alerts JSONB := '[]'::JSONB;
  v_reconcile_result JSONB := '{}'::JSONB;
  v_scope_size INTEGER := 0;
  v_cleared INTEGER := 0;
BEGIN
  IF p_business_date IS NULL THEN
    RAISE EXCEPTION '业务日期不能为空';
  END IF;

  IF p_alerts IS NULL OR jsonb_typeof(p_alerts) <> 'array' THEN
    RAISE EXCEPTION '提醒列表必须是 JSON 数组';
  END IF;

  IF p_student_names IS NULL THEN
    RAISE EXCEPTION '增量学生范围不能为空';
  END IF;

  IF cardinality(p_student_names) > 500 THEN
    RAISE EXCEPTION '单次增量学生不能超过 500 人';
  END IF;

  IF jsonb_array_length(p_alerts) > 2000 THEN
    RAISE EXCEPTION '单批提醒不能超过 2000 条';
  END IF;

  CREATE TEMP TABLE _practice_alert_incremental_scope (
    student_name TEXT PRIMARY KEY
  ) ON COMMIT DROP;

  INSERT INTO _practice_alert_incremental_scope (student_name)
  SELECT DISTINCT sd.name
  FROM unnest(p_student_names) AS requested(raw_name)
  JOIN public.student_database sd
    ON sd.name = NULLIF(BTRIM(requested.raw_name), '')
   AND COALESCE(sd.archived, FALSE) IS FALSE
  CROSS JOIN public.practice_alert_settings settings
  WHERE settings.singleton IS TRUE
    AND public.practice_grade_is_monitored(sd.grade, settings.monitored_grades);

  SELECT COUNT(*) INTO v_scope_size
  FROM _practice_alert_incremental_scope;

  IF v_scope_size = 0 THEN
    RETURN jsonb_build_object(
      'business_date', p_business_date,
      'scope_students', 0,
      'inserted', 0,
      'updated', 0,
      'cleared_present', 0,
      'complete_lifecycle', FALSE
    );
  END IF;

  CREATE TEMP TABLE _practice_alert_incremental_candidates (
    student_name TEXT NOT NULL,
    type TEXT NOT NULL,
    slot_start TEXT,
    slot_end TEXT,
    PRIMARY KEY (student_name, type, slot_start, slot_end)
  ) ON COMMIT DROP;

  INSERT INTO _practice_alert_incremental_candidates (
    student_name, type, slot_start, slot_end
  )
  SELECT DISTINCT
    NULLIF(BTRIM(item->>'student_name'), ''),
    item->>'type',
    NULLIF(BTRIM(item->>'slot_start'), ''),
    NULLIF(BTRIM(item->>'slot_end'), '')
  FROM jsonb_array_elements(p_alerts) AS entries(item)
  JOIN _practice_alert_incremental_scope scope
    ON scope.student_name = NULLIF(BTRIM(item->>'student_name'), '')
  WHERE item->>'type' = 'absent'
    AND NULLIF(BTRIM(item->>'slot_start'), '') IS NOT NULL
    AND NULLIF(BTRIM(item->>'slot_end'), '') IS NOT NULL;

  SELECT COALESCE(
    jsonb_agg(
      (item - 'client_version') || jsonb_build_object('client_version', 1)
    ),
    '[]'::JSONB
  )
  INTO v_safe_alerts
  FROM jsonb_array_elements(p_alerts) AS entries(item)
  JOIN _practice_alert_incremental_scope scope
    ON scope.student_name = NULLIF(BTRIM(item->>'student_name'), '')
  WHERE item->>'type' = 'absent';

  v_reconcile_result := public.reconcile_practice_alerts(
    p_business_date,
    v_safe_alerts
  );

  PERFORM set_config('app.practice_alerts_lifecycle_write', 'on', TRUE);

  UPDATE public.practice_alerts pa
  SET lifecycle_status = 'cleared_present',
      resolved = TRUE,
      resolved_at = COALESCE(pa.resolved_at, NOW()),
      resolution_reason = 'practice_recorded',
      updated_at = NOW()
  FROM _practice_alert_incremental_scope scope
  WHERE scope.student_name = pa.student_name
    AND pa.business_date = p_business_date
    AND pa.type = 'absent'
    AND pa.ignored IS FALSE
    AND pa.archived_at IS NULL
    AND pa.lifecycle_status IN ('active', 'confirmed_absent')
    AND NOT EXISTS (
      SELECT 1
      FROM _practice_alert_incremental_candidates candidate
      WHERE candidate.student_name = pa.student_name
        AND candidate.type = pa.type
        AND candidate.slot_start IS NOT DISTINCT FROM pa.slot_start
        AND candidate.slot_end IS NOT DISTINCT FROM pa.slot_end
    );
  GET DIAGNOSTICS v_cleared = ROW_COUNT;

  PERFORM set_config(
    'app.practice_alerts_lifecycle_write',
    COALESCE(v_previous_lifecycle_write, ''), TRUE
  );

  RETURN jsonb_build_object(
    'business_date', p_business_date,
    'scope_students', v_scope_size,
    'inserted', COALESCE((v_reconcile_result->>'inserted')::INTEGER, 0),
    'updated', COALESCE((v_reconcile_result->>'updated')::INTEGER, 0),
    'cleared_present', v_cleared,
    'complete_lifecycle', FALSE
  );
EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config(
      'app.practice_alerts_lifecycle_write',
      COALESCE(v_previous_lifecycle_write, ''), TRUE
    );
    RAISE;
END;
$function$;

REVOKE ALL ON FUNCTION public.reconcile_practice_alerts_incremental(
  DATE, JSONB, TEXT[]
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.reconcile_practice_alerts_incremental(
  DATE, JSONB, TEXT[]
) TO anon, authenticated;

COMMIT;
