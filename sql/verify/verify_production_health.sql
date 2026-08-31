-- 生产后端健康核验（只读）
-- 注意：函数调用使用显式周一日期，不使用 DEFAULT 作为实参。

WITH active_students AS (
  SELECT DISTINCT ON (student.name) student.name
  FROM public.student_database student
  WHERE COALESCE(student.archived, FALSE) IS FALSE
    AND NULLIF(BTRIM(student.name), '') IS NOT NULL
  ORDER BY student.name, student.updated_at DESC NULLS LAST, student.id DESC
),
current_targets AS (
  SELECT target.*
  FROM public.student_week_targets target
  WHERE target.week_monday = DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
),
leaderboards AS MATERIALIZED (
  SELECT * FROM public.get_weekly_leaderboards()
),
decline AS MATERIALIZED (
  SELECT *
  FROM public.get_weekly_decline_leaderboard(
    DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
  )
),
sample_student AS (
  SELECT active.name
  FROM active_students active
  JOIN public.student_baseline baseline ON baseline.student_name = active.name
  ORDER BY active.name
  LIMIT 1
),
sample_progress AS (
  SELECT progress.*
  FROM sample_student sample
  CROSS JOIN LATERAL public.get_student_week_progress_context(
    sample.name,
    DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE,
    (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
  ) progress
),
latest_cron_runs AS (
  SELECT
    job.jobname,
    run.status,
    run.start_time,
    run.end_time,
    run.return_message
  FROM cron.job job
  LEFT JOIN LATERAL (
    SELECT details.status, details.start_time, details.end_time, details.return_message
    FROM cron.job_run_details details
    WHERE details.jobid = job.jobid
    ORDER BY details.start_time DESC
    LIMIT 1
  ) run ON TRUE
  WHERE job.jobname IN (
    'refresh_w_score_weekday_daily',
    'refresh_w_score_before_weekly_lock',
    'backup_weekly_leaderboards_job',
    'reward_weekly_coins_job',
    'weekly_score_update_job'
  )
)
SELECT
  jsonb_build_object(
    'active_students', (SELECT COUNT(*) FROM active_students),
    'current_week_targets', (SELECT COUNT(*) FROM current_targets),
    'missing_current_targets', (
      SELECT COUNT(*)
      FROM active_students active
      LEFT JOIN current_targets target ON target.student_name = active.name
      WHERE target.student_name IS NULL
    ),
    'missing_target_sample', (
      SELECT COALESCE(jsonb_agg(name ORDER BY name), '[]'::JSONB)
      FROM (
        SELECT active.name
        FROM active_students active
        LEFT JOIN current_targets target ON target.student_name = active.name
        WHERE target.student_name IS NULL
        ORDER BY active.name
        LIMIT 10
      ) missing
    ),
    'target_sources', (
      SELECT COALESCE(jsonb_object_agg(source, row_count), '{}'::JSONB)
      FROM (
        SELECT COALESCE(target.calculation_source, 'unknown') AS source, COUNT(*) AS row_count
        FROM current_targets target
        GROUP BY COALESCE(target.calculation_source, 'unknown')
      ) grouped_sources
    )
  ) AS target_health,
  jsonb_build_object(
    'board_counts', (
      SELECT COALESCE(jsonb_object_agg(board, row_count), '{}'::JSONB)
      FROM (
        SELECT board, COUNT(*) AS row_count
        FROM leaderboards
        GROUP BY board
      ) grouped_boards
    ),
    'composite_distinct_ranks', (
      SELECT COALESCE(jsonb_agg(rank_no ORDER BY rank_no), '[]'::JSONB)
      FROM (
        SELECT DISTINCT rank_no
        FROM leaderboards
        WHERE board = '综合榜'
      ) ranks
    ),
    'composite_has_second_rank', EXISTS (
      SELECT 1 FROM leaderboards WHERE board = '综合榜' AND rank_no = 2
    ),
    'composite_rank_has_no_gaps', COALESCE((
      SELECT MAX(rank_no) = COUNT(DISTINCT rank_no)
      FROM leaderboards
      WHERE board = '综合榜'
    ), TRUE),
    'archived_or_deleted_students_in_boards', (
      SELECT COUNT(*)
      FROM leaderboards board_row
      WHERE NOT EXISTS (
        SELECT 1
        FROM active_students active
        WHERE active.name = board_row.student_name
      )
    ),
    'decline_rows', (SELECT COUNT(*) FROM decline),
    'archived_or_deleted_students_in_decline', (
      SELECT COUNT(*)
      FROM decline decline_row
      WHERE NOT EXISTS (
        SELECT 1
        FROM active_students active
        WHERE active.name = decline_row.student_name
      )
    )
  ) AS leaderboard_health,
  jsonb_build_object(
    'sample_student', (SELECT name FROM sample_student),
    'context_returned', EXISTS (SELECT 1 FROM sample_progress),
    'context', (SELECT TO_JSONB(sample_progress) FROM sample_progress),
    'realtime_trigger_calls_w_score',
      pg_get_functiondef('public.trigger_compute_student_score()'::REGPROCEDURE)
        ILIKE '%compute_and_store_w_score%'
  ) AS realtime_health,
  (
    SELECT COALESCE(
      jsonb_agg(TO_JSONB(latest_cron_runs) ORDER BY jobname),
      '[]'::JSONB
    )
    FROM latest_cron_runs
  ) AS latest_cron_runs;
