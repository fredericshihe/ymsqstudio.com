BEGIN;

-- Resolve multiple active alerts with one lifecycle-authorized UPDATE. This
-- keeps the update guard enabled for direct REST writes while avoiding one RPC
-- request per alert during the five-minute detection pass.
CREATE OR REPLACE FUNCTION public.resolve_practice_alerts(p_alert_ids BIGINT[])
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_previous_lifecycle_write TEXT := current_setting(
    'app.practice_alerts_lifecycle_write',
    TRUE
  );
  v_requested INTEGER := COALESCE(cardinality(p_alert_ids), 0);
  v_resolved INTEGER := 0;
BEGIN
  IF p_alert_ids IS NULL THEN
    RAISE EXCEPTION '提醒 ID 列表不能为空';
  END IF;

  IF v_requested > 1000 THEN
    RAISE EXCEPTION '单批提醒不能超过 1000 条';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(p_alert_ids) AS alert_id
    WHERE alert_id IS NULL OR alert_id <= 0
  ) THEN
    RAISE EXCEPTION '提醒 ID 无效';
  END IF;

  PERFORM set_config('app.practice_alerts_lifecycle_write', 'on', TRUE);

  UPDATE public.practice_alerts
  SET resolved = TRUE,
      resolved_at = COALESCE(resolved_at, NOW()),
      updated_at = NOW()
  WHERE id = ANY(p_alert_ids)
    AND ignored IS FALSE
    AND resolved IS FALSE
    AND archived_at IS NULL;

  GET DIAGNOSTICS v_resolved = ROW_COUNT;

  PERFORM set_config(
    'app.practice_alerts_lifecycle_write',
    COALESCE(v_previous_lifecycle_write, ''),
    TRUE
  );

  RETURN jsonb_build_object(
    'requested', v_requested,
    'resolved', v_resolved
  );
EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config(
      'app.practice_alerts_lifecycle_write',
      COALESCE(v_previous_lifecycle_write, ''),
      TRUE
    );
    RAISE;
END;
$function$;

REVOKE ALL ON FUNCTION public.resolve_practice_alerts(BIGINT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_practice_alerts(BIGINT[]) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
