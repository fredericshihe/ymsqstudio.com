-- ============================================================================
-- FIX-82: 回填 student_baseline.personal_best（与历史快照一致）
-- 目的：
-- 1) 修复详情页“历史最高综合排名分”与历史数据不一致
-- 2) 统一 personal_best 口径为历史最高 composite_score（保留 1 位小数）
-- ============================================================================

BEGIN;

WITH hist_best AS (
  SELECT
    h.student_name,
    ROUND(MAX(h.composite_score))::INT AS best_score
  FROM public.student_score_history h
  WHERE h.composite_score IS NOT NULL
  GROUP BY h.student_name
),
target AS (
  SELECT
    sb.student_name,
    ROUND(COALESCE(hb.best_score::NUMERIC, sb.composite_score))::INT AS expected_best
  FROM public.student_baseline sb
  LEFT JOIN hist_best hb ON hb.student_name = sb.student_name
)
UPDATE public.student_baseline sb
SET personal_best = t.expected_best
FROM target t
WHERE sb.student_name = t.student_name
  AND sb.personal_best IS DISTINCT FROM t.expected_best;

COMMIT;

-- 验收：
-- SELECT COUNT(*) FROM (
--   WITH hist_best AS (
--     SELECT student_name, ROUND(MAX(composite_score))::INT AS best_score
--     FROM public.student_score_history
--     WHERE composite_score IS NOT NULL
--     GROUP BY student_name
--   )
--   SELECT sb.student_name
--   FROM public.student_baseline sb
--   LEFT JOIN hist_best hb ON hb.student_name = sb.student_name
--   WHERE sb.personal_best IS DISTINCT FROM ROUND(COALESCE(hb.best_score::NUMERIC, sb.composite_score))::INT
-- ) x;
