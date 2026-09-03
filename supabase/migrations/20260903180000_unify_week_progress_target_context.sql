BEGIN;

CREATE OR REPLACE FUNCTION public.get_rule_v2_week_target_context(
  p_student_name TEXT,
  p_week_monday  DATE DEFAULT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
)
RETURNS TABLE (
  final_target_week    FLOAT8,
  personal_target_week FLOAT8,
  major_floor_week     FLOAT8,
  personal_week_ref    FLOAT8,
  peer_week_ref        FLOAT8,
  effective_mean       FLOAT8
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT
    target.final_target_week,
    target.personal_target_week,
    target.major_floor_week,
    target.personal_week_ref,
    target.peer_week_ref,
    target.effective_mean
  FROM public.calculate_student_week_target(p_student_name, p_week_monday) target;
$function$;

REVOKE ALL ON FUNCTION public.get_rule_v2_week_target_context(TEXT, DATE)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_rule_v2_week_target_context(TEXT, DATE)
TO anon, authenticated;

COMMENT ON FUNCTION public.get_rule_v2_week_target_context(TEXT, DATE) IS
'Compatibility wrapper for the latest student weekly target calculation. Keeps W progress, target explanations, score refreshes, and leaderboard calculations on one target policy.';

NOTIFY pgrst, 'reload schema';

COMMIT;
