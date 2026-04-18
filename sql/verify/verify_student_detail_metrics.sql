-- ============================================================================
-- 学生详情页字段一致性核对（全量）
-- 只读脚本：用于排查 practiceanalyse 学生详情关键字段是否与底层数据一致
-- 重点：历史最高综合排名分（personal_best）
-- ============================================================================

-- 1) 历史最高综合排名分核对
-- 口径：max(student_score_history.composite_score)，若该生尚无历史则回退 student_baseline.composite_score
WITH hist_best AS (
  SELECT
    h.student_name,
    ROUND(MAX(h.composite_score))::INT AS hist_best_score
  FROM public.student_score_history h
  WHERE h.composite_score IS NOT NULL
  GROUP BY h.student_name
),
best_compare AS (
  SELECT
    sb.student_name,
    sb.personal_best AS baseline_personal_best,
    ROUND(COALESCE(hb.hist_best_score::NUMERIC, sb.composite_score))::INT AS expected_personal_best
  FROM public.student_baseline sb
  LEFT JOIN hist_best hb ON hb.student_name = sb.student_name
)
SELECT
  student_name,
  baseline_personal_best,
  expected_personal_best,
  (baseline_personal_best IS DISTINCT FROM expected_personal_best) AS is_mismatch
FROM best_compare
WHERE baseline_personal_best IS DISTINCT FROM expected_personal_best
ORDER BY student_name;


-- 2) 当前周“是否有练琴”核对（对应前端 has_week_snapshot 的判断基础）
WITH week_base AS (
  SELECT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::TIMESTAMP AS week_start
),
active_this_week AS (
  SELECT
    ps.student_name,
    COUNT(*) FILTER (
      WHERE EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
        AND ps.cleaned_duration > 0
    )::INT AS workday_valid_sessions
  FROM public.practice_sessions ps
  CROSS JOIN week_base wb
  WHERE ps.session_start >= wb.week_start
  GROUP BY ps.student_name
)
SELECT
  sb.student_name,
  COALESCE(a.workday_valid_sessions, 0) AS workday_valid_sessions_this_week,
  CASE WHEN COALESCE(a.workday_valid_sessions, 0) > 0 THEN false ELSE true END AS expected_has_week_snapshot
FROM public.student_baseline sb
LEFT JOIN active_this_week a ON a.student_name = sb.student_name
ORDER BY sb.student_name;


-- 3) record_count 核对（当前 baseline 值 vs 最近30条“工作日+有效时长>0”的真实条数）
WITH sess AS (
  SELECT
    ps.student_name,
    ps.session_start,
    ps.cleaned_duration,
    ROW_NUMBER() OVER (
      PARTITION BY ps.student_name
      ORDER BY ps.session_start DESC
    ) AS rn_all
  FROM public.practice_sessions ps
  WHERE ps.cleaned_duration > 0
    AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
),
top30 AS (
  SELECT student_name, COUNT(*)::INT AS expected_record_count
  FROM sess
  WHERE rn_all <= 30
  GROUP BY student_name
)
SELECT
  sb.student_name,
  sb.record_count AS baseline_record_count,
  COALESCE(t.expected_record_count, 0) AS expected_record_count,
  (sb.record_count IS DISTINCT FROM COALESCE(t.expected_record_count, 0)) AS is_mismatch
FROM public.student_baseline sb
LEFT JOIN top30 t ON t.student_name = sb.student_name
WHERE sb.record_count IS DISTINCT FROM COALESCE(t.expected_record_count, 0)
ORDER BY sb.student_name;


-- 4) mean_duration / outlier_rate 快速一致性巡检（按现有基线主口径做近似体检）
-- 注：若你的 baseline 采用更复杂清洗规则，本节用于“发现明显异常”，不是绝对等值断言。
WITH base_sess AS (
  SELECT
    ps.student_name,
    ps.session_start,
    ps.cleaned_duration,
    COALESCE(ps.is_outlier, false) AS is_outlier,
    ROW_NUMBER() OVER (
      PARTITION BY ps.student_name
      ORDER BY ps.session_start DESC
    ) AS rn_all
  FROM public.practice_sessions ps
  WHERE EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
),
top30 AS (
  SELECT *
  FROM base_sess
  WHERE rn_all <= 30
),
agg AS (
  SELECT
    student_name,
    AVG(CASE WHEN cleaned_duration > 0 THEN cleaned_duration END)::FLOAT8 AS expected_mean_duration,
    AVG(CASE WHEN cleaned_duration > 0 AND is_outlier THEN 1.0 ELSE 0.0 END)::FLOAT8 AS expected_outlier_rate
  FROM top30
  GROUP BY student_name
)
SELECT
  sb.student_name,
  sb.mean_duration,
  a.expected_mean_duration,
  sb.outlier_rate,
  a.expected_outlier_rate,
  ABS(COALESCE(sb.mean_duration, 0) - COALESCE(a.expected_mean_duration, 0)) AS mean_abs_diff,
  ABS(COALESCE(sb.outlier_rate, 0) - COALESCE(a.expected_outlier_rate, 0)) AS outlier_abs_diff
FROM public.student_baseline sb
LEFT JOIN agg a ON a.student_name = sb.student_name
WHERE ABS(COALESCE(sb.mean_duration, 0) - COALESCE(a.expected_mean_duration, 0)) > 5
   OR ABS(COALESCE(sb.outlier_rate, 0) - COALESCE(a.expected_outlier_rate, 0)) > 0.10
ORDER BY mean_abs_diff DESC, outlier_abs_diff DESC, sb.student_name;
