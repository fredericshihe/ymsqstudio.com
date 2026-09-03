BEGIN;

CREATE OR REPLACE FUNCTION public.get_student_score_semester_context(
  p_student_name TEXT,
  p_as_of         TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (
  score_semester_started_at      TIMESTAMPTZ,
  score_semester_monday          DATE,
  student_score_period_started_at TIMESTAMPTZ,
  student_score_period_monday    DATE,
  valid_practice_days            INTEGER
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
WITH current_profile AS (
  SELECT
    COALESCE(NULLIF(BTRIM(student.major), ''), baseline.student_major) AS major
  FROM public.student_database student
  LEFT JOIN public.student_baseline baseline
    ON baseline.student_name = student.name
  WHERE student.name = p_student_name
    AND COALESCE(student.archived, FALSE) IS FALSE
    AND NULLIF(BTRIM(student.name), '') IS NOT NULL
  ORDER BY student.updated_at DESC NULLS LAST, student.id DESC
  LIMIT 1
),
semester_context AS (
  SELECT public.get_score_semester_start(p_as_of) AS started_at
),
period_context AS (
  SELECT public.get_student_score_period_start_at(
    p_student_name,
    p_as_of
  ) AS started_at
),
target_policy AS (
  SELECT policy.valid_practice_days
  FROM current_profile profile
  JOIN public.practice_target_policies policy
    ON policy.enabled
   AND (
     policy.major_pattern = '*'
     OR COALESCE(profile.major, '') ILIKE '%' || policy.major_pattern || '%'
   )
  ORDER BY policy.priority DESC, LENGTH(policy.major_pattern) DESC
  LIMIT 1
)
SELECT
  semester.started_at,
  DATE_TRUNC(
    'week',
    COALESCE(semester.started_at, p_as_of) AT TIME ZONE 'Asia/Shanghai'
  )::DATE,
  COALESCE(period.started_at, semester.started_at),
  DATE_TRUNC(
    'week',
    COALESCE(period.started_at, semester.started_at, p_as_of)
      AT TIME ZONE 'Asia/Shanghai'
  )::DATE,
  COALESCE(policy.valid_practice_days, 4)
FROM current_profile profile
CROSS JOIN semester_context semester
CROSS JOIN period_context period
LEFT JOIN target_policy policy ON TRUE;
$function$;

REVOKE ALL ON FUNCTION public.get_student_score_semester_context(TEXT, TIMESTAMPTZ)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_student_score_semester_context(TEXT, TIMESTAMPTZ)
TO anon, authenticated;

COMMENT ON FUNCTION public.get_student_score_semester_context(TEXT, TIMESTAMPTZ) IS
'Returns the active score semester, the student effective score period, and the major policy valid-practice-day threshold for frontend detail views.';

NOTIFY pgrst, 'reload schema';

COMMIT;
