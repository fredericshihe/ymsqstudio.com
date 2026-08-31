BEGIN;

-- 榜单规则优化：
-- 1) 稳定榜先按基线可信度 α，再按最近 20 条记录的时长波动率（CV）排序；
--    平均时长仅作最低资格条件和末级并列项，避免“练得久”冒充“练得稳”。
-- 2) 守则榜按本周至少 3 个不同工作日参与，避免同一天拆分多次会话刷榜。
--    会话次数不再作为排名依据。

CREATE OR REPLACE FUNCTION public.get_weekly_leaderboards()
RETURNS TABLE (
  board                 TEXT,
  rank_no               INTEGER,
  student_name          TEXT,
  student_major         TEXT,
  student_grade         TEXT,
  display_score         NUMERIC,
  alpha                 NUMERIC,
  trend_score           NUMERIC,
  mean_duration         NUMERIC,
  record_count          INTEGER,
  recent10_outlier_rate NUMERIC,
  recent10_mean_dur     NUMERIC,
  recent10_count        INTEGER
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
WITH week_context AS (
  SELECT
    DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS monday,
    ((DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE::TIMESTAMP)
      AT TIME ZONE 'Asia/Shanghai') AS week_start,
    NOW() AS cutoff_at
),
current_students AS (
  SELECT DISTINCT ON (sd.name)
    sd.name AS student_name,
    COALESCE(NULLIF(BTRIM(sd.major), ''), sb.student_major) AS student_major,
    COALESCE(NULLIF(BTRIM(sd.grade), ''), sb.student_grade) AS student_grade
  FROM public.student_database sd
  JOIN public.student_baseline sb ON sb.student_name = sd.name
  WHERE COALESCE(sd.archived, FALSE) IS FALSE
    AND NULLIF(BTRIM(sd.name), '') IS NOT NULL
  ORDER BY sd.name, sd.updated_at DESC NULLS LAST, sd.id DESC
),
periods AS (
  SELECT
    cs.*,
    metrics.period_start,
    metrics.mean_duration,
    metrics.record_count,
    metrics.alpha
  FROM current_students cs
  CROSS JOIN week_context wc
  CROSS JOIN LATERAL public.get_student_score_period_metrics(cs.student_name, wc.monday) metrics
),
recent_ranked AS (
  SELECT
    p.student_name,
    ps.is_outlier,
    ps.cleaned_duration,
    ROW_NUMBER() OVER (PARTITION BY p.student_name ORDER BY ps.session_start DESC) AS rn
  FROM periods p
  CROSS JOIN week_context wc
  JOIN public.practice_sessions ps
    ON ps.student_name = p.student_name
   AND ps.cleaned_duration > 0
   AND ps.session_start >= p.period_start
   AND ps.session_start < wc.cutoff_at
   AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
),
recent20 AS (
  SELECT
    rr.student_name,
    COUNT(*)::INTEGER AS cnt,
    ROUND(AVG((rr.is_outlier)::INTEGER)::NUMERIC, 4) AS outlier_rate,
    ROUND(AVG(rr.cleaned_duration)::NUMERIC, 2) AS mean_dur,
    COALESCE(
      STDDEV_POP(rr.cleaned_duration) / NULLIF(AVG(rr.cleaned_duration), 0),
      0
    )::NUMERIC AS duration_cv
  FROM recent_ranked rr
  WHERE rr.rn <= 20
  GROUP BY rr.student_name
),
week_usage AS (
  SELECT
    p.student_name,
    COUNT(*)::INTEGER AS session_count,
    COUNT(DISTINCT (ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE)::INTEGER
      AS practice_days
  FROM periods p
  CROSS JOIN week_context wc
  JOIN public.practice_sessions ps
    ON ps.student_name = p.student_name
   AND ps.cleaned_duration > 0
   AND ps.session_start >= GREATEST(wc.week_start, p.period_start)
   AND ps.session_start < wc.cutoff_at
   AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  GROUP BY p.student_name
),
week_scores AS (
  SELECT
    ssh.student_name,
    ssh.composite_score,
    ssh.raw_score,
    ssh.trend_score,
    ssh.baseline_score
  FROM public.student_score_history ssh
  CROSS JOIN week_context wc
  JOIN week_usage wu ON wu.student_name = ssh.student_name
  WHERE ssh.snapshot_date = wc.monday
    AND ssh.composite_score > 0
),
last_week_scores AS (
  SELECT DISTINCT ON (ssh.student_name)
    ssh.student_name,
    ssh.composite_score AS previous_composite
  FROM public.student_score_history ssh
  JOIN periods p ON p.student_name = ssh.student_name
  CROSS JOIN week_context wc
  WHERE ssh.snapshot_date < wc.monday
    AND ssh.snapshot_date >= DATE_TRUNC(
      'week',
      p.period_start AT TIME ZONE 'Asia/Shanghai'
    )::DATE
    AND ssh.composite_score > 0
    AND EXISTS (
      SELECT 1
      FROM public.practice_sessions active_session
      WHERE active_session.student_name = ssh.student_name
        AND active_session.cleaned_duration > 0
        AND active_session.session_start >= GREATEST(
          p.period_start,
          (ssh.snapshot_date::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai'
        )
        AND active_session.session_start < (((ssh.snapshot_date + 7)::TIMESTAMP)
          AT TIME ZONE 'Asia/Shanghai')
        AND EXTRACT(DOW FROM active_session.session_start AT TIME ZONE 'Asia/Shanghai')
          NOT IN (0, 6)
    )
  ORDER BY ssh.student_name, ssh.snapshot_date DESC
),
ranked_pool AS (
  SELECT
    p.student_name,
    p.student_major,
    p.student_grade,
    ws.composite_score AS display_score,
    p.alpha,
    ws.trend_score,
    p.mean_duration,
    p.record_count,
    wu.session_count AS week_sessions,
    wu.practice_days
  FROM periods p
  JOIN week_usage wu ON wu.student_name = p.student_name
  JOIN week_scores ws ON ws.student_name = p.student_name
  WHERE ws.composite_score > 0
),
comp AS (
  SELECT
    '综合榜'::TEXT AS board,
    RANK() OVER (
      ORDER BY rp.display_score DESC NULLS LAST,
               rp.mean_duration DESC NULLS LAST,
               rp.record_count DESC NULLS LAST
    )::INTEGER AS rank_no,
    rp.student_name,
    rp.student_major,
    rp.student_grade,
    rp.display_score,
    rp.alpha::NUMERIC,
    rp.trend_score,
    rp.mean_duration::NUMERIC,
    rp.record_count,
    r20.outlier_rate AS recent10_outlier_rate,
    r20.mean_dur AS recent10_mean_dur,
    r20.cnt AS recent10_count
  FROM ranked_pool rp
  LEFT JOIN recent20 r20 ON r20.student_name = rp.student_name
),
comp_top10 AS (
  SELECT c.student_name
  FROM comp c
  WHERE c.rank_no <= 10
),
progress AS (
  SELECT
    '进步榜'::TEXT AS board,
    RANK() OVER (
      ORDER BY (rp.display_score - lws.previous_composite) DESC NULLS LAST,
               rp.display_score DESC NULLS LAST,
               rp.mean_duration DESC NULLS LAST
    )::INTEGER AS rank_no,
    rp.student_name,
    rp.student_major,
    rp.student_grade,
    rp.display_score,
    rp.alpha::NUMERIC,
    ROUND((rp.display_score - lws.previous_composite)::NUMERIC, 1) AS trend_score,
    rp.mean_duration::NUMERIC,
    rp.record_count,
    r20.outlier_rate AS recent10_outlier_rate,
    r20.mean_dur AS recent10_mean_dur,
    r20.cnt AS recent10_count
  FROM ranked_pool rp
  JOIN last_week_scores lws ON lws.student_name = rp.student_name
  LEFT JOIN recent20 r20 ON r20.student_name = rp.student_name
  WHERE rp.display_score - lws.previous_composite >= 1.0
    AND rp.week_sessions >= 2
    AND COALESCE(r20.cnt, 0) >= 4
    AND COALESCE(r20.outlier_rate, 1) <= 0.20
    AND rp.student_name NOT IN (SELECT ct.student_name FROM comp_top10 ct)
),
stable AS (
  SELECT
    '稳定榜'::TEXT AS board,
    RANK() OVER (
      ORDER BY COALESCE(rp.alpha, 0) DESC,
               COALESCE(r20.duration_cv, 1) ASC,
               COALESCE(r20.outlier_rate, 1) ASC,
               COALESCE(r20.mean_dur, 0) DESC
    )::INTEGER AS rank_no,
    rp.student_name,
    rp.student_major,
    rp.student_grade,
    rp.display_score,
    rp.alpha::NUMERIC,
    rp.trend_score,
    rp.mean_duration::NUMERIC,
    rp.record_count,
    r20.outlier_rate AS recent10_outlier_rate,
    r20.mean_dur AS recent10_mean_dur,
    r20.cnt AS recent10_count
  FROM ranked_pool rp
  LEFT JOIN recent20 r20 ON r20.student_name = rp.student_name
  WHERE COALESCE(rp.alpha, 0) >= 0.60
    AND COALESCE(r20.cnt, 0) >= 8
    AND COALESCE(r20.outlier_rate, 1) <= 0.20
    AND COALESCE(r20.mean_dur, 0) >= 30
    AND rp.student_name NOT IN (SELECT ct.student_name FROM comp_top10 ct)
),
rules AS (
  SELECT
    '守则榜'::TEXT AS board,
    RANK() OVER (
      ORDER BY COALESCE(r20.outlier_rate, 1) ASC,
               rp.practice_days DESC,
               COALESCE(r20.mean_dur, 0) DESC
    )::INTEGER AS rank_no,
    rp.student_name,
    rp.student_major,
    rp.student_grade,
    rp.display_score,
    rp.alpha::NUMERIC,
    rp.trend_score,
    rp.mean_duration::NUMERIC,
    rp.record_count,
    r20.outlier_rate AS recent10_outlier_rate,
    r20.mean_dur AS recent10_mean_dur,
    r20.cnt AS recent10_count
  FROM ranked_pool rp
  LEFT JOIN recent20 r20 ON r20.student_name = rp.student_name
  WHERE rp.practice_days >= 3
    AND COALESCE(r20.cnt, 0) >= 5
    AND COALESCE(r20.mean_dur, 0) >= 30
    AND COALESCE(r20.outlier_rate, 1) <= 0.20
    AND COALESCE(rp.alpha, 0) >= 0.60
    AND rp.student_name NOT IN (SELECT ct.student_name FROM comp_top10 ct)
)
SELECT * FROM comp
UNION ALL
SELECT * FROM progress
UNION ALL
SELECT * FROM stable
UNION ALL
SELECT * FROM rules
ORDER BY board, rank_no;
$function$;

REVOKE ALL ON FUNCTION public.get_weekly_leaderboards() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_weekly_leaderboards() TO anon, authenticated;

COMMENT ON FUNCTION public.get_weekly_leaderboards() IS
  '实时周榜：稳定榜按 α、时长波动率、异常率排序；守则榜要求本周至少 3 个不同工作日，避免拆分会话刷榜。';

NOTIFY pgrst, 'reload schema';

COMMIT;
