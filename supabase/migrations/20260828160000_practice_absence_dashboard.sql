BEGIN;

-- Keep one precise row per student / scheduled slot, but stop treating
-- "the slot ended" and "the student later practised" as the same outcome.
ALTER TABLE public.practice_alerts
  ADD COLUMN IF NOT EXISTS lifecycle_status TEXT,
  ADD COLUMN IF NOT EXISTS resolution_reason TEXT,
  ADD COLUMN IF NOT EXISTS confirmed_absent_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS acknowledged_at TIMESTAMPTZ;

-- Install the expanded lifecycle guard before backfilling the new columns.
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
    IF NEW.ignored IS DISTINCT FROM OLD.ignored
       AND NOT (
         OLD.lifecycle_status = 'active'
         AND OLD.business_date = (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
         AND OLD.slot_end ~ '^([01]?[0-9]|2[0-3]):[0-5][0-9]'
         AND OLD.slot_end::TIME >= (NOW() AT TIME ZONE 'Asia/Shanghai')::TIME
       ) THEN
      RAISE EXCEPTION 'Only a currently active alert may be ignored directly';
    END IF;
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
         - 'lifecycle_status'
         - 'resolution_reason'
         - 'confirmed_absent_at'
         - 'acknowledged_at'
     ) = (
       to_jsonb(OLD)
         - 'ignored'
         - 'updated_at'
         - 'resolved'
         - 'resolved_at'
         - 'archived_at'
         - 'business_date'
         - 'lifecycle_status'
         - 'resolution_reason'
         - 'confirmed_absent_at'
         - 'acknowledged_at'
     ) THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'Only ignored and updated_at may be changed directly';
END;
$function$;

SELECT set_config('app.practice_alerts_lifecycle_write', 'on', TRUE);

UPDATE public.practice_alerts
SET lifecycle_status = CASE
      WHEN ignored IS TRUE THEN 'ignored'
      WHEN resolved IS TRUE THEN 'cleared'
      WHEN business_date < (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE THEN 'confirmed_absent'
      WHEN slot_end ~ '^([01]?[0-9]|2[0-3]):[0-5][0-9]'
       AND slot_end::TIME < (NOW() AT TIME ZONE 'Asia/Shanghai')::TIME THEN 'confirmed_absent'
      ELSE 'active'
    END,
    resolution_reason = CASE
      WHEN ignored IS TRUE THEN COALESCE(resolution_reason, 'legacy_ignored')
      WHEN resolved IS TRUE THEN COALESCE(resolution_reason, 'legacy_resolved')
      ELSE resolution_reason
    END,
    confirmed_absent_at = CASE
      WHEN ignored IS FALSE
       AND resolved IS FALSE
       AND (
         business_date < (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
         OR (
           slot_end ~ '^([01]?[0-9]|2[0-3]):[0-5][0-9]'
           AND slot_end::TIME < (NOW() AT TIME ZONE 'Asia/Shanghai')::TIME
         )
       )
      THEN COALESCE(confirmed_absent_at, resolved_at, updated_at, created_at, NOW())
      ELSE confirmed_absent_at
    END
WHERE lifecycle_status IS NULL;

ALTER TABLE public.practice_alerts
  ALTER COLUMN lifecycle_status SET DEFAULT 'active',
  ALTER COLUMN lifecycle_status SET NOT NULL;

ALTER TABLE public.practice_alerts
  DROP CONSTRAINT IF EXISTS practice_alerts_lifecycle_status_check;

ALTER TABLE public.practice_alerts
  ADD CONSTRAINT practice_alerts_lifecycle_status_check
  CHECK (lifecycle_status IN (
    'active', 'confirmed_absent', 'cleared_present', 'cleared', 'ignored', 'archived'
  ));

ALTER TABLE public.practice_alerts_archive
  ADD COLUMN IF NOT EXISTS lifecycle_status TEXT,
  ADD COLUMN IF NOT EXISTS resolution_reason TEXT,
  ADD COLUMN IF NOT EXISTS confirmed_absent_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS acknowledged_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS public.practice_alert_settings (
  singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton IS TRUE),
  monitored_grades TEXT[] NOT NULL DEFAULT ARRAY[
    'G1','G2','G3','G4','G5','G6','G7','G8','G9'
  ]::TEXT[],
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.practice_alert_settings (singleton, monitored_grades)
VALUES (
  TRUE,
  ARRAY['G1','G2','G3','G4','G5','G6','G7','G8','G9']::TEXT[]
)
ON CONFLICT (singleton) DO NOTHING;

CREATE OR REPLACE FUNCTION public.normalize_practice_grade(p_grade TEXT)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
PARALLEL SAFE
AS $function$
  SELECT CASE
    WHEN BTRIM(COALESCE(p_grade, '')) ~* '^g\s*[0-9]+$'
      THEN 'G' || REGEXP_REPLACE(BTRIM(p_grade), '[^0-9]', '', 'g')
    ELSE BTRIM(COALESCE(p_grade, ''))
  END;
$function$;

CREATE OR REPLACE FUNCTION public.practice_grade_is_monitored(
  p_grade TEXT,
  p_monitored_grades TEXT[]
)
RETURNS BOOLEAN
LANGUAGE SQL
IMMUTABLE
PARALLEL SAFE
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM unnest(COALESCE(p_monitored_grades, ARRAY[]::TEXT[])) selected(raw_grade)
    CROSS JOIN LATERAL (
      SELECT public.normalize_practice_grade(selected.raw_grade) AS grade
    ) normalized_selected
    CROSS JOIN LATERAL (
      SELECT public.normalize_practice_grade(p_grade) AS grade
    ) normalized_student
    WHERE normalized_student.grade = normalized_selected.grade
       OR (
         normalized_selected.grade ~ '^G[0-9]+$'
         AND (
           normalized_student.grade LIKE normalized_selected.grade || '-%'
           OR normalized_student.grade LIKE normalized_selected.grade || '.%'
         )
       )
  );
$function$;

CREATE OR REPLACE FUNCTION public.get_practice_alert_settings()
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  WITH config AS (
    SELECT monitored_grades, updated_at
    FROM public.practice_alert_settings
    WHERE singleton IS TRUE
  ), available AS (
    SELECT DISTINCT public.normalize_practice_grade(grade) AS grade
    FROM public.student_database
    WHERE COALESCE(archived, FALSE) IS FALSE
      AND public.normalize_practice_grade(grade) <> ''
  )
  SELECT jsonb_build_object(
    'monitored_grades', COALESCE(
      (SELECT to_jsonb(monitored_grades) FROM config),
      to_jsonb(ARRAY['G1','G2','G3','G4','G5','G6','G7','G8','G9']::TEXT[])
    ),
    'available_grades', COALESCE(
      (SELECT jsonb_agg(grade ORDER BY grade) FROM available),
      '[]'::JSONB
    ),
    'updated_at', (SELECT updated_at FROM config)
  );
$function$;

CREATE OR REPLACE FUNCTION public.save_practice_alert_settings(p_monitored_grades TEXT[])
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_grades TEXT[];
BEGIN
  IF p_monitored_grades IS NULL THEN
    RAISE EXCEPTION '监测年级列表不能为空';
  END IF;

  IF cardinality(p_monitored_grades) > 50 THEN
    RAISE EXCEPTION '监测年级不能超过 50 个';
  END IF;

  SELECT COALESCE(array_agg(grade ORDER BY grade), ARRAY[]::TEXT[])
  INTO v_grades
  FROM (
    SELECT DISTINCT public.normalize_practice_grade(value) AS grade
    FROM unnest(p_monitored_grades) AS values_list(value)
    WHERE public.normalize_practice_grade(value) <> ''
      AND char_length(public.normalize_practice_grade(value)) <= 30
  ) normalized;

  INSERT INTO public.practice_alert_settings (singleton, monitored_grades, updated_at)
  VALUES (TRUE, v_grades, NOW())
  ON CONFLICT (singleton) DO UPDATE
  SET monitored_grades = EXCLUDED.monitored_grades,
      updated_at = EXCLUDED.updated_at;

  RETURN public.get_practice_alert_settings();
END;
$function$;

-- The former partial unique index allowed a resolved row and a later active
-- row for the same business key. Preserve those legacy duplicates in the
-- archive, then keep a single canonical row for future status transitions.
WITH duplicate_rows AS (
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
            (ignored IS FALSE AND lifecycle_status IN ('active', 'confirmed_absent')) DESC,
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
  archive_reason, archived_copy_at, lifecycle_status, resolution_reason,
  confirmed_absent_at, acknowledged_at
)
SELECT
  id, student_name, type, slot_start, slot_end, ignored, resolved,
  created_at, updated_at, severity, business_date, resolved_at,
  COALESCE(archived_at, NOW()), 'duplicate_lifecycle_upgrade', NOW(),
  lifecycle_status, resolution_reason, confirmed_absent_at, acknowledged_at
FROM duplicate_rows
ON CONFLICT (id) DO NOTHING;

WITH duplicate_ids AS (
  SELECT id
  FROM (
    SELECT
      id,
      ROW_NUMBER() OVER (
        PARTITION BY student_name, type, slot_start, slot_end, business_date
        ORDER BY
          (ignored IS FALSE AND lifecycle_status IN ('active', 'confirmed_absent')) DESC,
          updated_at DESC NULLS LAST,
          id DESC
      ) AS row_number
    FROM public.practice_alerts
  ) ranked
  WHERE row_number > 1
)
DELETE FROM public.practice_alerts pa
USING duplicate_ids duplicates
WHERE pa.id = duplicates.id;

DROP INDEX IF EXISTS public.uniq_practice_alerts_business_key_active;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_practice_alerts_business_key
  ON public.practice_alerts (
    student_name, type, slot_start, slot_end, business_date
  ) NULLS NOT DISTINCT;

CREATE INDEX IF NOT EXISTS idx_practice_alerts_dashboard
  ON public.practice_alerts (business_date, lifecycle_status, acknowledged_at)
  WHERE ignored IS FALSE AND archived_at IS NULL;

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
  v_updated INTEGER := 0;
  v_cleared INTEGER := 0;
  v_complete_lifecycle BOOLEAN := FALSE;
  v_previous_lifecycle_write TEXT := current_setting(
    'app.practice_alerts_lifecycle_write', TRUE
  );
BEGIN
  IF p_business_date IS NULL THEN
    RAISE EXCEPTION '业务日期不能为空';
  END IF;

  IF p_alerts IS NULL OR jsonb_typeof(p_alerts) <> 'array' THEN
    RAISE EXCEPTION '提醒列表必须是 JSON 数组';
  END IF;

  IF jsonb_array_length(p_alerts) > 2000 THEN
    RAISE EXCEPTION '单批提醒不能超过 2000 条';
  END IF;

  -- Old clients only submit the currently running slot and therefore cannot
  -- safely decide that an elapsed absence is no longer valid. Only protocol
  -- v2 candidates are authoritative for clearing rows missing from the batch.
  SELECT COALESCE(BOOL_AND(item->>'client_version' = '2'), FALSE)
  INTO v_complete_lifecycle
  FROM jsonb_array_elements(p_alerts) AS entries(item);

  PERFORM set_config('app.practice_alerts_lifecycle_write', 'on', TRUE);
  PERFORM pg_advisory_xact_lock(hashtext('practice-alerts:' || p_business_date::TEXT));

  CREATE TEMP TABLE _practice_alert_candidates (
    student_name TEXT NOT NULL,
    type TEXT NOT NULL,
    slot_start TEXT,
    slot_end TEXT,
    severity INTEGER,
    lifecycle_status TEXT NOT NULL,
    business_date DATE NOT NULL,
    PRIMARY KEY (student_name, type, slot_start, slot_end)
  ) ON COMMIT DROP;

  INSERT INTO _practice_alert_candidates (
    student_name, type, slot_start, slot_end, severity,
    lifecycle_status, business_date
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
    CASE
      WHEN item->>'lifecycle_status' = 'confirmed_absent' THEN 'confirmed_absent'
      ELSE 'active'
    END,
    p_business_date
  FROM jsonb_array_elements(p_alerts) AS entries(item)
  JOIN public.student_database sd
    ON sd.name = NULLIF(BTRIM(item->>'student_name'), '')
   AND COALESCE(sd.archived, FALSE) IS FALSE
  CROSS JOIN public.practice_alert_settings settings
  WHERE settings.singleton IS TRUE
    AND public.practice_grade_is_monitored(sd.grade, settings.monitored_grades)
    AND NULLIF(BTRIM(item->>'student_name'), '') IS NOT NULL
    AND NULLIF(BTRIM(item->>'slot_start'), '') IS NOT NULL
    AND NULLIF(BTRIM(item->>'slot_end'), '') IS NOT NULL
    AND item->>'type' = 'absent';

  UPDATE public.practice_alerts pa
  SET lifecycle_status = c.lifecycle_status,
      resolved = FALSE,
      resolved_at = NULL,
      resolution_reason = NULL,
      confirmed_absent_at = CASE
        WHEN c.lifecycle_status = 'confirmed_absent'
          THEN COALESCE(pa.confirmed_absent_at, NOW())
        ELSE NULL
      END,
      acknowledged_at = CASE
        WHEN pa.lifecycle_status = c.lifecycle_status
         AND c.lifecycle_status = 'confirmed_absent'
          THEN pa.acknowledged_at
        ELSE NULL
      END,
      severity = COALESCE(c.severity, pa.severity),
      updated_at = NOW()
  FROM _practice_alert_candidates c
  WHERE pa.student_name = c.student_name
    AND pa.type = c.type
    AND pa.slot_start IS NOT DISTINCT FROM c.slot_start
    AND pa.slot_end IS NOT DISTINCT FROM c.slot_end
    AND pa.business_date = c.business_date
    AND pa.ignored IS FALSE
    AND (
      pa.lifecycle_status IS DISTINCT FROM c.lifecycle_status
      OR pa.resolved IS TRUE
      OR pa.resolution_reason IS NOT NULL
    );
  GET DIAGNOSTICS v_updated = ROW_COUNT;

  INSERT INTO public.practice_alerts (
    student_name, type, slot_start, slot_end, ignored, resolved,
    severity, business_date, lifecycle_status, confirmed_absent_at
  )
  SELECT
    c.student_name, c.type, c.slot_start, c.slot_end, FALSE, FALSE,
    c.severity, c.business_date, c.lifecycle_status,
    CASE WHEN c.lifecycle_status = 'confirmed_absent' THEN NOW() ELSE NULL END
  FROM _practice_alert_candidates c
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.practice_alerts pa
    WHERE pa.student_name = c.student_name
      AND pa.type = c.type
      AND pa.slot_start IS NOT DISTINCT FROM c.slot_start
      AND pa.slot_end IS NOT DISTINCT FROM c.slot_end
      AND pa.business_date = c.business_date
  );
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  -- Only clear students whose current grade is still monitored. Excluding a
  -- grade removes it from the dashboard without rewriting or deleting history.
  UPDATE public.practice_alerts pa
  SET lifecycle_status = 'cleared_present',
      resolved = TRUE,
      resolved_at = COALESCE(pa.resolved_at, NOW()),
      resolution_reason = 'practice_recorded',
      updated_at = NOW()
  FROM public.student_database sd
  CROSS JOIN public.practice_alert_settings settings
  WHERE settings.singleton IS TRUE
    AND sd.name = pa.student_name
    AND COALESCE(sd.archived, FALSE) IS FALSE
    AND public.practice_grade_is_monitored(sd.grade, settings.monitored_grades)
    AND pa.business_date = p_business_date
    AND pa.type = 'absent'
    AND pa.ignored IS FALSE
    AND pa.archived_at IS NULL
    AND pa.lifecycle_status IN ('active', 'confirmed_absent')
    AND v_complete_lifecycle
    AND NOT EXISTS (
      SELECT 1
      FROM _practice_alert_candidates c
      WHERE c.student_name = pa.student_name
        AND c.type = pa.type
        AND c.slot_start IS NOT DISTINCT FROM pa.slot_start
        AND c.slot_end IS NOT DISTINCT FROM pa.slot_end
    );
  GET DIAGNOSTICS v_cleared = ROW_COUNT;

  PERFORM set_config(
    'app.practice_alerts_lifecycle_write',
    COALESCE(v_previous_lifecycle_write, ''), TRUE
  );

  RETURN jsonb_build_object(
    'business_date', p_business_date,
    'inserted', v_inserted,
    'updated', v_updated,
    'cleared_present', v_cleared,
    'complete_lifecycle', v_complete_lifecycle
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

CREATE OR REPLACE FUNCTION public.get_practice_alert_summary(p_business_date DATE)
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  WITH monitored AS (
    SELECT
      pa.*,
      sd.grade,
      sd.major
    FROM public.practice_alerts pa
    JOIN public.student_database sd
      ON sd.name = pa.student_name
     AND COALESCE(sd.archived, FALSE) IS FALSE
    CROSS JOIN public.practice_alert_settings settings
    WHERE settings.singleton IS TRUE
      AND pa.business_date = p_business_date
      AND pa.type = 'absent'
      AND pa.ignored IS FALSE
      AND pa.archived_at IS NULL
      AND pa.lifecycle_status IN ('active', 'confirmed_absent')
      AND public.practice_grade_is_monitored(sd.grade, settings.monitored_grades)
  )
  SELECT jsonb_build_object(
    'business_date', p_business_date,
    'active_students', COUNT(DISTINCT student_name) FILTER (
      WHERE lifecycle_status = 'active'
    ),
    'active_slots', COUNT(*) FILTER (WHERE lifecycle_status = 'active'),
    'active_slot_start', MIN(slot_start) FILTER (WHERE lifecycle_status = 'active'),
    'active_slot_end', MAX(slot_end) FILTER (WHERE lifecycle_status = 'active'),
    'confirmed_students', COUNT(DISTINCT student_name) FILTER (
      WHERE lifecycle_status = 'confirmed_absent'
    ),
    'confirmed_slots', COUNT(*) FILTER (
      WHERE lifecycle_status = 'confirmed_absent'
    ),
    'unread_students', COUNT(DISTINCT student_name) FILTER (
      WHERE lifecycle_status = 'confirmed_absent' AND acknowledged_at IS NULL
    )
  )
  FROM monitored;
$function$;

DROP FUNCTION IF EXISTS public.get_practice_alert_details(
  DATE, TEXT, TEXT, TEXT[], TEXT[], INTEGER, INTEGER
);

CREATE OR REPLACE FUNCTION public.get_practice_alert_details(
  p_business_date DATE,
  p_status TEXT DEFAULT 'active',
  p_search TEXT DEFAULT NULL,
  p_grades TEXT[] DEFAULT NULL,
  p_majors TEXT[] DEFAULT NULL,
  p_slot_start TEXT DEFAULT NULL,
  p_slot_end TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
  student_name TEXT,
  grade TEXT,
  major TEXT,
  alert_count BIGINT,
  unread BOOLEAN,
  slot_ranges JSONB,
  alert_ids BIGINT[],
  total_students BIGINT
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  WITH filtered AS (
    SELECT pa.*, COALESCE(sd.grade, '') AS grade, COALESCE(sd.major, '') AS major
    FROM public.practice_alerts pa
    JOIN public.student_database sd
      ON sd.name = pa.student_name
     AND COALESCE(sd.archived, FALSE) IS FALSE
    CROSS JOIN public.practice_alert_settings settings
    WHERE settings.singleton IS TRUE
      AND pa.business_date = p_business_date
      AND pa.type = 'absent'
      AND pa.ignored IS FALSE
      AND pa.archived_at IS NULL
      AND pa.lifecycle_status = CASE
        WHEN p_status = 'confirmed_absent' THEN 'confirmed_absent'
        ELSE 'active'
      END
      AND public.practice_grade_is_monitored(sd.grade, settings.monitored_grades)
      AND (
        NULLIF(BTRIM(COALESCE(p_search, '')), '') IS NULL
        OR pa.student_name ILIKE '%' || BTRIM(p_search) || '%'
      )
      AND (
        COALESCE(cardinality(p_grades), 0) = 0
        OR public.normalize_practice_grade(sd.grade) = ANY(p_grades)
      )
      AND (
        COALESCE(cardinality(p_majors), 0) = 0
        OR sd.major = ANY(p_majors)
      )
      AND (
        NULLIF(BTRIM(COALESCE(p_slot_start, '')), '') IS NULL
        OR pa.slot_start = BTRIM(p_slot_start)
      )
      AND (
        NULLIF(BTRIM(COALESCE(p_slot_end, '')), '') IS NULL
        OR pa.slot_end = BTRIM(p_slot_end)
      )
  ), grouped AS (
    SELECT
      f.student_name,
      MAX(f.grade) AS grade,
      MAX(f.major) AS major,
      COUNT(*) AS alert_count,
      BOOL_OR(
        f.lifecycle_status = 'confirmed_absent'
        AND f.acknowledged_at IS NULL
      ) AS unread,
      jsonb_agg(
        jsonb_build_object(
          'id', f.id,
          'start', f.slot_start,
          'end', f.slot_end,
          'acknowledged_at', f.acknowledged_at
        ) ORDER BY f.slot_start, f.slot_end
      ) AS slot_ranges,
      array_agg(f.id ORDER BY f.slot_start, f.slot_end) AS alert_ids
    FROM filtered f
    GROUP BY f.student_name
  )
  SELECT
    g.student_name,
    g.grade,
    g.major,
    g.alert_count,
    g.unread,
    g.slot_ranges,
    g.alert_ids,
    COUNT(*) OVER() AS total_students
  FROM grouped g
  ORDER BY g.unread DESC, g.grade, g.student_name
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$function$;

DROP FUNCTION IF EXISTS public.acknowledge_practice_absences(
  DATE, TEXT, TEXT[], TEXT[]
);

CREATE OR REPLACE FUNCTION public.acknowledge_practice_absences(
  p_business_date DATE,
  p_search TEXT DEFAULT NULL,
  p_grades TEXT[] DEFAULT NULL,
  p_majors TEXT[] DEFAULT NULL,
  p_slot_start TEXT DEFAULT NULL,
  p_slot_end TEXT DEFAULT NULL
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
  v_updated INTEGER := 0;
BEGIN
  PERFORM set_config('app.practice_alerts_lifecycle_write', 'on', TRUE);

  UPDATE public.practice_alerts pa
  SET acknowledged_at = COALESCE(pa.acknowledged_at, NOW()),
      updated_at = NOW()
  FROM public.student_database sd
  CROSS JOIN public.practice_alert_settings settings
  WHERE settings.singleton IS TRUE
    AND sd.name = pa.student_name
    AND COALESCE(sd.archived, FALSE) IS FALSE
    AND pa.business_date = p_business_date
    AND pa.type = 'absent'
    AND pa.lifecycle_status = 'confirmed_absent'
    AND pa.ignored IS FALSE
    AND pa.archived_at IS NULL
    AND pa.acknowledged_at IS NULL
    AND public.practice_grade_is_monitored(sd.grade, settings.monitored_grades)
    AND (
      NULLIF(BTRIM(COALESCE(p_search, '')), '') IS NULL
      OR pa.student_name ILIKE '%' || BTRIM(p_search) || '%'
    )
    AND (
      COALESCE(cardinality(p_grades), 0) = 0
      OR public.normalize_practice_grade(sd.grade) = ANY(p_grades)
    )
    AND (
      COALESCE(cardinality(p_majors), 0) = 0
      OR sd.major = ANY(p_majors)
    )
    AND (
      NULLIF(BTRIM(COALESCE(p_slot_start, '')), '') IS NULL
      OR pa.slot_start = BTRIM(p_slot_start)
    )
    AND (
      NULLIF(BTRIM(COALESCE(p_slot_end, '')), '') IS NULL
      OR pa.slot_end = BTRIM(p_slot_end)
    );
  GET DIAGNOSTICS v_updated = ROW_COUNT;

  PERFORM set_config(
    'app.practice_alerts_lifecycle_write',
    COALESCE(v_previous_lifecycle_write, ''), TRUE
  );

  RETURN jsonb_build_object('acknowledged', v_updated);
EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config(
      'app.practice_alerts_lifecycle_write',
      COALESCE(v_previous_lifecycle_write, ''), TRUE
    );
    RAISE;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_practice_alert(p_alert_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_previous_lifecycle_write TEXT := current_setting(
    'app.practice_alerts_lifecycle_write', TRUE
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
      lifecycle_status = 'cleared_present',
      resolution_reason = 'practice_recorded',
      updated_at = NOW()
  WHERE id = p_alert_id
    AND ignored IS FALSE
    AND lifecycle_status = 'active'
    -- Legacy pages used this RPC both for genuine arrival and merely because
    -- the slot ended. Never let an old client erase an elapsed absence; the
    -- v2 reconciliation path will still clear it when a real log overlaps.
    AND business_date = (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
    AND slot_end ~ '^([01]?[0-9]|2[0-3]):[0-5][0-9]'
    AND slot_end::TIME >= (NOW() AT TIME ZONE 'Asia/Shanghai')::TIME
    AND archived_at IS NULL;
  GET DIAGNOSTICS v_updated = ROW_COUNT;

  PERFORM set_config(
    'app.practice_alerts_lifecycle_write',
    COALESCE(v_previous_lifecycle_write, ''), TRUE
  );

  RETURN jsonb_build_object('id', p_alert_id, 'updated', v_updated > 0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_practice_alerts(p_alert_ids BIGINT[])
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_previous_lifecycle_write TEXT := current_setting(
    'app.practice_alerts_lifecycle_write', TRUE
  );
  v_requested INTEGER := COALESCE(cardinality(p_alert_ids), 0);
  v_resolved INTEGER := 0;
BEGIN
  IF p_alert_ids IS NULL OR v_requested > 1000 THEN
    RAISE EXCEPTION '提醒 ID 列表无效';
  END IF;

  PERFORM set_config('app.practice_alerts_lifecycle_write', 'on', TRUE);

  UPDATE public.practice_alerts
  SET resolved = TRUE,
      resolved_at = COALESCE(resolved_at, NOW()),
      lifecycle_status = 'cleared_present',
      resolution_reason = 'practice_recorded',
      updated_at = NOW()
  WHERE id = ANY(p_alert_ids)
    AND ignored IS FALSE
    AND lifecycle_status = 'active'
    AND business_date = (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
    AND slot_end ~ '^([01]?[0-9]|2[0-3]):[0-5][0-9]'
    AND slot_end::TIME >= (NOW() AT TIME ZONE 'Asia/Shanghai')::TIME
    AND archived_at IS NULL;
  GET DIAGNOSTICS v_resolved = ROW_COUNT;

  PERFORM set_config(
    'app.practice_alerts_lifecycle_write',
    COALESCE(v_previous_lifecycle_write, ''), TRUE
  );

  RETURN jsonb_build_object('requested', v_requested, 'resolved', v_resolved);
END;
$function$;

REVOKE ALL ON TABLE public.practice_alert_settings FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.normalize_practice_grade(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.practice_grade_is_monitored(TEXT, TEXT[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_practice_alert_settings() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_practice_alert_settings(TEXT[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reconcile_practice_alerts(DATE, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_practice_alert_summary(DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_practice_alert_details(DATE, TEXT, TEXT, TEXT[], TEXT[], TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.acknowledge_practice_absences(DATE, TEXT, TEXT[], TEXT[], TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.resolve_practice_alert(BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.resolve_practice_alerts(BIGINT[]) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_practice_alert_settings() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_practice_alert_settings(TEXT[]) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reconcile_practice_alerts(DATE, JSONB) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_practice_alert_summary(DATE) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_practice_alert_details(DATE, TEXT, TEXT, TEXT[], TEXT[], TEXT, TEXT, INTEGER, INTEGER) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.acknowledge_practice_absences(DATE, TEXT, TEXT[], TEXT[], TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_practice_alert(BIGINT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_practice_alerts(BIGINT[]) TO anon, authenticated;
GRANT SELECT ON TABLE public.practice_alert_settings TO anon, authenticated;

DO $block$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (
       SELECT 1
       FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime'
         AND schemaname = 'public'
         AND tablename = 'practice_alert_settings'
     ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.practice_alert_settings;
  END IF;
END;
$block$;

NOTIFY pgrst, 'reload schema';

COMMIT;
