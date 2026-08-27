BEGIN;

-- Existing installations protect practice_alerts with a trigger that only permits
-- ignored/updated_at changes. Keep that protection for direct client updates, but
-- allow this migration and the reconciliation RPC to manage lifecycle columns.
CREATE OR REPLACE FUNCTION public.practice_alerts_update_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
BEGIN
  IF (
    to_jsonb(NEW) - 'ignored' - 'updated_at'
  ) = (
    to_jsonb(OLD) - 'ignored' - 'updated_at'
  ) THEN
    RETURN NEW;
  END IF;

  IF current_setting('app.practice_alerts_lifecycle_write', TRUE) = 'on'
     AND (
       to_jsonb(NEW)
         - 'ignored'
         - 'updated_at'
         - 'resolved'
         - 'resolved_at'
         - 'archived_at'
         - 'business_date'
     ) = (
       to_jsonb(OLD)
         - 'ignored'
         - 'updated_at'
         - 'resolved'
         - 'resolved_at'
         - 'archived_at'
         - 'business_date'
     ) THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'Only ignored and updated_at may be changed directly';
END;
$function$;

SELECT set_config('app.practice_alerts_lifecycle_write', 'on', TRUE);

ALTER TABLE public.practice_alerts
  ADD COLUMN IF NOT EXISTS business_date DATE,
  ADD COLUMN IF NOT EXISTS resolved_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ;

UPDATE public.practice_alerts
SET business_date = (COALESCE(created_at, NOW()) AT TIME ZONE 'Asia/Shanghai')::DATE
WHERE business_date IS NULL;

ALTER TABLE public.practice_alerts
  ALTER COLUMN business_date SET NOT NULL;

CREATE OR REPLACE FUNCTION public.set_practice_alert_business_date()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.business_date IS NULL THEN
    NEW.business_date := (COALESCE(NEW.created_at, NOW()) AT TIME ZONE 'Asia/Shanghai')::DATE;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_practice_alert_business_date ON public.practice_alerts;
CREATE TRIGGER trg_practice_alert_business_date
BEFORE INSERT OR UPDATE OF created_at, business_date ON public.practice_alerts
FOR EACH ROW
EXECUTE FUNCTION public.set_practice_alert_business_date();

CREATE TABLE IF NOT EXISTS public.practice_alerts_archive (
  id BIGINT NOT NULL,
  student_name TEXT,
  type TEXT,
  slot_start TEXT,
  slot_end TEXT,
  ignored BOOLEAN,
  resolved BOOLEAN,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  severity INTEGER,
  business_date DATE,
  resolved_at TIMESTAMPTZ,
  archived_at TIMESTAMPTZ,
  archive_reason TEXT NOT NULL DEFAULT '',
  archived_copy_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.practice_alerts_archive
  ADD COLUMN IF NOT EXISTS business_date DATE,
  ADD COLUMN IF NOT EXISTS resolved_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS archived_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS archive_reason TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS archived_copy_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE UNIQUE INDEX IF NOT EXISTS practice_alerts_archive_id_uq
  ON public.practice_alerts_archive (id);

UPDATE public.practice_alerts
SET resolved = TRUE,
    resolved_at = COALESCE(resolved_at, updated_at, created_at, NOW()),
    updated_at = NOW()
WHERE ignored IS FALSE
  AND resolved IS FALSE
  AND created_at < NOW() - INTERVAL '30 days';

UPDATE public.practice_alerts
SET archived_at = COALESCE(archived_at, NOW()),
    updated_at = NOW()
WHERE created_at < NOW() - INTERVAL '30 days'
  AND (ignored IS TRUE OR resolved IS TRUE);

DROP INDEX IF EXISTS public.uniq_practice_alerts_day_active;
DROP INDEX IF EXISTS public.uniq_practice_alerts_day;

INSERT INTO public.practice_alerts_archive (
  id, student_name, type, slot_start, slot_end, ignored, resolved,
  created_at, updated_at, severity, business_date, resolved_at, archived_at,
  archive_reason, archived_copy_at
)
SELECT
  id, student_name, type, slot_start, slot_end, ignored, resolved,
  created_at, updated_at, severity, business_date, resolved_at, archived_at,
  CASE
    WHEN ignored IS TRUE THEN 'ignored_retention'
    ELSE 'resolved_retention'
  END,
  NOW()
FROM public.practice_alerts
WHERE created_at < NOW() - INTERVAL '30 days'
  AND (ignored IS TRUE OR resolved IS TRUE)
ON CONFLICT (id) DO UPDATE
SET archive_reason = EXCLUDED.archive_reason,
    archived_copy_at = EXCLUDED.archived_copy_at;

DELETE FROM public.practice_alerts
WHERE created_at < NOW() - INTERVAL '30 days'
  AND (ignored IS TRUE OR resolved IS TRUE);

WITH duplicate_alerts AS (
  SELECT pa.*
  FROM public.practice_alerts pa
  JOIN (
    SELECT id
    FROM (
      SELECT
        id,
        ROW_NUMBER() OVER (
          PARTITION BY student_name, type, slot_start, slot_end, business_date
          ORDER BY
            (ignored IS FALSE AND resolved IS FALSE) DESC,
            updated_at DESC NULLS LAST,
            id DESC
        ) AS row_number
      FROM public.practice_alerts
    ) ranked
    WHERE row_number > 1
  ) duplicates ON duplicates.id = pa.id
)
INSERT INTO public.practice_alerts_archive (
  id, student_name, type, slot_start, slot_end, ignored, resolved,
  created_at, updated_at, severity, business_date, resolved_at, archived_at,
  archive_reason, archived_copy_at
)
SELECT
  pa.id, pa.student_name, pa.type, pa.slot_start, pa.slot_end, pa.ignored, pa.resolved,
  pa.created_at, pa.updated_at, pa.severity, pa.business_date, pa.resolved_at,
  COALESCE(pa.archived_at, NOW()),
  'duplicate_business_key', NOW()
FROM duplicate_alerts pa
ON CONFLICT (id) DO NOTHING;

WITH duplicate_ids AS (
  SELECT id
  FROM (
    SELECT
      id,
      ROW_NUMBER() OVER (
        PARTITION BY student_name, type, slot_start, slot_end, business_date
        ORDER BY
          (ignored IS FALSE AND resolved IS FALSE) DESC,
          updated_at DESC NULLS LAST,
          id DESC
      ) AS row_number
    FROM public.practice_alerts
  ) ranked
  WHERE row_number > 1
)
DELETE FROM public.practice_alerts pa
USING duplicate_ids d
WHERE pa.id = d.id;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_practice_alerts_business_key_active
  ON public.practice_alerts (student_name, type, slot_start, slot_end, business_date) NULLS NOT DISTINCT
  WHERE ignored IS FALSE AND resolved IS FALSE AND archived_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_practice_alerts_active_date
  ON public.practice_alerts (business_date, created_at DESC)
  WHERE ignored IS FALSE AND resolved IS FALSE AND archived_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_practice_alerts_student_slot
  ON public.practice_alerts (student_name, type, slot_start, slot_end, business_date);

CREATE OR REPLACE FUNCTION public.create_practice_alerts_batch(p_alerts JSONB)
RETURNS SETOF public.practice_alerts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF p_alerts IS NULL OR jsonb_typeof(p_alerts) <> 'array' THEN
    RAISE EXCEPTION '提醒列表必须是 JSON 数组';
  END IF;

  IF jsonb_array_length(p_alerts) > 1000 THEN
    RAISE EXCEPTION '单批提醒不能超过 1000 条';
  END IF;

  RETURN QUERY
  INSERT INTO public.practice_alerts (
    student_name, type, slot_start, slot_end, ignored, resolved,
    severity, business_date
  )
  SELECT
    NULLIF(BTRIM(item->>'student_name'), ''),
    item->>'type',
    NULLIF(BTRIM(item->>'slot_start'), ''),
    NULLIF(BTRIM(item->>'slot_end'), ''),
    FALSE,
    FALSE,
    CASE
      WHEN NULLIF(item->>'severity', '') IS NULL THEN NULL
      ELSE (item->>'severity')::INTEGER
    END,
    COALESCE(
      NULLIF(item->>'business_date', '')::DATE,
      (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
    )
  FROM jsonb_array_elements(p_alerts) AS entries(item)
  WHERE NULLIF(BTRIM(item->>'student_name'), '') IS NOT NULL
    AND item->>'type' IN ('absent', 'anomaly')
  ON CONFLICT DO NOTHING
  RETURNING *;
END;
$function$;

CREATE OR REPLACE FUNCTION public.reconcile_practice_alerts(
  p_business_date DATE,
  p_alerts JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_inserted INTEGER := 0;
  v_resolved INTEGER := 0;
  v_previous_lifecycle_write TEXT := current_setting(
    'app.practice_alerts_lifecycle_write',
    TRUE
  );
BEGIN
  IF p_business_date IS NULL THEN
    RAISE EXCEPTION '业务日期不能为空';
  END IF;

  IF p_alerts IS NULL OR jsonb_typeof(p_alerts) <> 'array' THEN
    RAISE EXCEPTION '提醒列表必须是 JSON 数组';
  END IF;

  PERFORM set_config('app.practice_alerts_lifecycle_write', 'on', TRUE);

  PERFORM pg_advisory_xact_lock(hashtext('practice-alerts:' || p_business_date::TEXT));

  CREATE TEMP TABLE _practice_alert_candidates (
    student_name TEXT NOT NULL,
    type TEXT NOT NULL,
    slot_start TEXT,
    slot_end TEXT,
    severity INTEGER,
    business_date DATE NOT NULL
  ) ON COMMIT DROP;

  INSERT INTO _practice_alert_candidates (
    student_name, type, slot_start, slot_end, severity, business_date
  )
  SELECT DISTINCT ON (
    NULLIF(BTRIM(item->>'student_name'), ''),
    item->>'type',
    NULLIF(BTRIM(item->>'slot_start'), ''),
    NULLIF(BTRIM(item->>'slot_end'), '')
  )
    NULLIF(BTRIM(item->>'student_name'), ''),
    item->>'type',
    NULLIF(BTRIM(item->>'slot_start'), ''),
    NULLIF(BTRIM(item->>'slot_end'), ''),
    CASE
      WHEN NULLIF(item->>'severity', '') IS NULL THEN NULL
      ELSE (item->>'severity')::INTEGER
    END,
    p_business_date
  FROM jsonb_array_elements(p_alerts) AS entries(item)
  WHERE NULLIF(BTRIM(item->>'student_name'), '') IS NOT NULL
    AND item->>'type' IN ('absent', 'anomaly');

  INSERT INTO public.practice_alerts (
    student_name, type, slot_start, slot_end, ignored, resolved,
    severity, business_date
  )
  SELECT
    student_name, type, slot_start, slot_end, FALSE, FALSE,
    severity, business_date
  FROM _practice_alert_candidates
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  UPDATE public.practice_alerts pa
  SET resolved = TRUE,
      resolved_at = COALESCE(pa.resolved_at, NOW()),
      updated_at = NOW()
  WHERE pa.business_date = p_business_date
    AND pa.ignored IS FALSE
    AND pa.resolved IS FALSE
    AND NOT EXISTS (
      SELECT 1
      FROM _practice_alert_candidates c
      WHERE c.student_name = pa.student_name
        AND c.type = pa.type
        AND c.slot_start IS NOT DISTINCT FROM pa.slot_start
        AND c.slot_end IS NOT DISTINCT FROM pa.slot_end
    );
  GET DIAGNOSTICS v_resolved = ROW_COUNT;

  PERFORM set_config(
    'app.practice_alerts_lifecycle_write',
    COALESCE(v_previous_lifecycle_write, ''),
    TRUE
  );

  RETURN jsonb_build_object(
    'business_date', p_business_date,
    'inserted', v_inserted,
    'resolved', v_resolved
  );
END;
$function$;

REVOKE ALL ON TABLE public.practice_alerts_archive FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_practice_alerts_batch(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reconcile_practice_alerts(DATE, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_practice_alerts_batch(JSONB) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reconcile_practice_alerts(DATE, JSONB) TO anon, authenticated;

COMMIT;
