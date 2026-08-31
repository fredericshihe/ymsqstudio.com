WITH current_week AS (
  SELECT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS monday
),
active_students AS (
  SELECT DISTINCT ON (sd.name) sd.name
  FROM public.student_database sd
  WHERE COALESCE(sd.archived, FALSE) IS FALSE
    AND NULLIF(BTRIM(sd.name), '') IS NOT NULL
  ORDER BY sd.name, sd.updated_at DESC NULLS LAST, sd.id DESC
),
coverage AS (
  SELECT
    COUNT(*)::INTEGER AS active_students,
    COUNT(swt.student_name)::INTEGER AS locked_targets,
    COUNT(*) FILTER (WHERE swt.target_minutes IS NULL)::INTEGER AS missing_targets,
    COUNT(*) FILTER (WHERE swt.target_minutes NOT BETWEEN 270 AND 1500)::INTEGER AS invalid_targets
  FROM active_students active
  CROSS JOIN current_week week
  LEFT JOIN public.student_week_targets swt
    ON swt.student_name = active.name
   AND swt.week_monday = week.monday
),
consistency AS (
  SELECT
    COUNT(*) FILTER (
      WHERE ABS(context.final_target_week - swt.target_minutes::FLOAT8) > 0.001
    )::INTEGER AS context_mismatches,
    COUNT(*) FILTER (
      WHERE ABS(progress.week_target_minutes - swt.target_minutes) > 0.01
    )::INTEGER AS progress_mismatches
  FROM public.student_week_targets swt
  CROSS JOIN current_week week
  CROSS JOIN LATERAL public.get_rule_v2_week_target_context(swt.student_name, week.monday) context
  CROSS JOIN LATERAL public.get_student_week_progress_context(swt.student_name, week.monday, NULL) progress
  WHERE swt.week_monday = week.monday
),
next_week_preview AS (
  SELECT
    COUNT(*)::INTEGER AS preview_students,
    COUNT(*) FILTER (WHERE preview.final_target_week NOT BETWEEN 270 AND 1500)::INTEGER AS invalid_preview_targets,
    MAX(ABS(preview.final_target_week - current_target.target_minutes)
      / NULLIF(current_target.target_minutes, 0))::NUMERIC AS maximum_change_ratio
  FROM public.student_week_targets current_target
  CROSS JOIN current_week week
  CROSS JOIN LATERAL public.calculate_student_week_target(
    current_target.student_name,
    week.monday + 7
  ) preview
  WHERE current_target.week_monday = week.monday
)
SELECT
  TO_JSONB(coverage) AS coverage,
  TO_JSONB(consistency) AS consistency,
  TO_JSONB(next_week_preview) AS next_week_preview
FROM coverage, consistency, next_week_preview;

SELECT jobname, schedule, command, active
FROM cron.job
WHERE jobname IN (
  'refresh_student_week_targets_monday',
  'refresh_w_score_weekday_daily',
  'refresh_w_score_monday_bootstrap'
)
ORDER BY jobname;
