BEGIN;

-- Resolve one active practice alert through the lifecycle-write path.
-- Direct client UPDATEs intentionally remain restricted by
-- practice_alerts_update_guard(); this RPC is the only single-row path the
-- realtime client needs for automatic resolution.
CREATE OR REPLACE FUNCTION public.resolve_practice_alert(p_alert_id BIGINT)
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
  v_updated INTEGER := 0;
BEGIN
  IF p_alert_id IS NULL OR p_alert_id <= 0 THEN
    RAISE EXCEPTION '提醒 ID 无效';
  END IF;

  PERFORM set_config('app.practice_alerts_lifecycle_write', 'on', TRUE);

  UPDATE public.practice_alerts
  SET resolved = TRUE,
      resolved_at = COALESCE(resolved_at, NOW()),
      updated_at = NOW()
  WHERE id = p_alert_id
    AND ignored IS FALSE
    AND resolved IS FALSE
    AND archived_at IS NULL;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  PERFORM set_config(
    'app.practice_alerts_lifecycle_write',
    COALESCE(v_previous_lifecycle_write, ''),
    TRUE
  );

  RETURN jsonb_build_object(
    'id', p_alert_id,
    'updated', v_updated > 0
  );
EXCEPTION
  WHEN OTHERS THEN
    -- Restore the transaction-local guard setting before propagating the
    -- error. The transaction will still be rolled back by the caller.
    PERFORM set_config(
      'app.practice_alerts_lifecycle_write',
      COALESCE(v_previous_lifecycle_write, ''),
      TRUE
    );
    RAISE;
END;
$function$;

REVOKE ALL ON FUNCTION public.resolve_practice_alert(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_practice_alert(BIGINT) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
