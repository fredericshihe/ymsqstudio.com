-- ============================================================================
-- 回测脚本：历史评分合理性核对 + 综合榜霸榜风险量化
-- 文件：backtest_score_reasonableness.sql
-- 适用：PostgreSQL / Supabase SQL Editor
--
-- 用途：
-- 1) 核对历史快照中的 raw/composite 一致性与分值范围
-- 2) 纯只读回测（不调用会写库的 VOID 函数）
-- 3) 评估综合榜长期霸榜风险（连冠、占比、头名分差）
--
-- 默认窗口：最近 26 周，可在 params 中调整
-- ============================================================================

-- ---------------------------------------------------------------------------
-- A) 总体健康检查（摘要）
-- ---------------------------------------------------------------------------
WITH params AS (
  SELECT
    26::INT         AS lookback_weeks,
    0.20::NUMERIC   AS composite_tolerance    -- composite 与 raw*100 允许误差
),
scope AS (
  SELECT h.*
  FROM public.student_score_history h
  CROSS JOIN params p
  WHERE h.snapshot_date >= (
    DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
    - (p.lookback_weeks::TEXT || ' weeks')::INTERVAL
  )
),
recalc AS (
  SELECT
    s.student_name,
    s.snapshot_date,
    s.raw_score            AS stored_raw_score,
    s.composite_score      AS stored_composite_score,
    ROUND((s.raw_score * 100)::NUMERIC, 1) AS expected_composite_from_raw
  FROM scope s
),
summary AS (
  SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (
      WHERE ABS(stored_composite_score - expected_composite_from_raw)
            > (SELECT composite_tolerance FROM params)
    ) AS cnt_raw_composite_mismatch,
    COUNT(*) FILTER (
      WHERE stored_raw_score < -0.001 OR stored_raw_score > 1.001
    ) AS cnt_raw_out_of_range,
    COUNT(*) FILTER (
      WHERE stored_composite_score < -0.1 OR stored_composite_score > 100.1
    ) AS cnt_composite_out_of_range,
    0::BIGINT AS cnt_recalc_missing,
    0::BIGINT AS cnt_raw_recalc_drift,
    0::BIGINT AS cnt_composite_recalc_drift
  FROM recalc
)
SELECT
  'rows_scanned'::TEXT AS check_name,
  total_rows::TEXT     AS result,
  '最近窗口内快照总行数'::TEXT AS note
FROM summary
UNION ALL
SELECT
  'raw_composite_mismatch',
  cnt_raw_composite_mismatch::TEXT,
  'stored_composite 与 ROUND(raw*100,1) 不一致行数'
FROM summary
UNION ALL
SELECT
  'raw_out_of_range',
  cnt_raw_out_of_range::TEXT,
  'raw_score 不在 [0,1] 的行数'
FROM summary
UNION ALL
SELECT
  'composite_out_of_range',
  cnt_composite_out_of_range::TEXT,
  'composite_score 不在 [0,100] 的行数'
FROM summary
UNION ALL
SELECT
  'recalc_missing',
  cnt_recalc_missing::TEXT,
  '当前脚本为只读版，此项固定为 0'
FROM summary
UNION ALL
SELECT
  'raw_recalc_drift',
  cnt_raw_recalc_drift::TEXT,
  '当前脚本为只读版，此项固定为 0'
FROM summary
UNION ALL
SELECT
  'composite_recalc_drift',
  cnt_composite_recalc_drift::TEXT,
  '当前脚本为只读版，此项固定为 0'
FROM summary
ORDER BY check_name;


-- ---------------------------------------------------------------------------
-- B) 异常明细（便于定位）
-- ---------------------------------------------------------------------------
WITH params AS (
  SELECT
    26::INT         AS lookback_weeks,
    0.20::NUMERIC   AS composite_tolerance
),
scope AS (
  SELECT h.*
  FROM public.student_score_history h
  CROSS JOIN params p
  WHERE h.snapshot_date >= (
    DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
    - (p.lookback_weeks::TEXT || ' weeks')::INTERVAL
  )
),
recalc AS (
  SELECT
    s.student_name,
    s.snapshot_date,
    s.raw_score,
    s.composite_score,
    ROUND((s.raw_score * 100)::NUMERIC, 1) AS expected_composite_from_raw,
    NULL::NUMERIC AS recomputed_raw_score,
    NULL::NUMERIC AS recomputed_composite_score
  FROM scope s
),
issues AS (
  SELECT
    'raw_composite_mismatch'::TEXT AS issue_type,
    student_name,
    snapshot_date,
    raw_score,
    composite_score,
    expected_composite_from_raw,
    recomputed_raw_score,
    recomputed_composite_score,
    ABS(composite_score - expected_composite_from_raw)::NUMERIC(10,4) AS delta
  FROM recalc
  WHERE ABS(composite_score - expected_composite_from_raw) > (SELECT composite_tolerance FROM params)

  UNION ALL

  SELECT
    'raw_out_of_range',
    student_name,
    snapshot_date,
    raw_score,
    composite_score,
    expected_composite_from_raw,
    recomputed_raw_score,
    recomputed_composite_score,
    NULL::NUMERIC(10,4) AS delta
  FROM recalc
  WHERE raw_score < -0.001 OR raw_score > 1.001

  UNION ALL

  SELECT
    'composite_out_of_range',
    student_name,
    snapshot_date,
    raw_score,
    composite_score,
    expected_composite_from_raw,
    recomputed_raw_score,
    recomputed_composite_score,
    NULL::NUMERIC(10,4) AS delta
  FROM recalc
  WHERE composite_score < -0.1 OR composite_score > 100.1

  -- 注意：compute_student_score_as_of 在多数版本是 RETURNS VOID（有副作用）
  -- 为避免回测脚本改写线上数据，这里不做“重算漂移”项。
)
SELECT *
FROM issues
ORDER BY snapshot_date DESC, issue_type, student_name
LIMIT 300;


-- ---------------------------------------------------------------------------
-- C) 综合榜“长期霸榜”风险回测（基于历史快照）
-- ---------------------------------------------------------------------------
WITH params AS (
  SELECT 52::INT AS lookback_weeks   -- 霸榜建议看更长窗口
),
scope AS (
  SELECT h.*
  FROM public.student_score_history h
  CROSS JOIN params p
  WHERE h.snapshot_date >= (
    DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
    - (p.lookback_weeks::TEXT || ' weeks')::INTERVAL
  )
    AND h.composite_score > 0
),
ranked AS (
  SELECT
    snapshot_date,
    student_name,
    composite_score,
    mean_duration,
    record_count,
    RANK() OVER (
      PARTITION BY snapshot_date
      ORDER BY composite_score DESC NULLS LAST,
               mean_duration DESC NULLS LAST,
               record_count DESC NULLS LAST
    ) AS rank_no
  FROM scope
),
top2 AS (
  SELECT
    snapshot_date,
    MAX(CASE WHEN rank_no = 1 THEN student_name END)    AS top1_student,
    MAX(CASE WHEN rank_no = 1 THEN composite_score END) AS top1_score,
    MAX(CASE WHEN rank_no = 2 THEN composite_score END) AS top2_score
  FROM ranked
  WHERE rank_no <= 2
  GROUP BY snapshot_date
),
top1_only AS (
  SELECT snapshot_date, top1_student
  FROM top2
  WHERE top1_student IS NOT NULL
),
streak_tag AS (
  SELECT
    top1_student,
    snapshot_date,
    (
      snapshot_date::TIMESTAMP
      - (ROW_NUMBER() OVER (PARTITION BY top1_student ORDER BY snapshot_date) * INTERVAL '7 day')
    ) AS grp_key
  FROM top1_only
),
streaks AS (
  SELECT
    top1_student AS student_name,
    MIN(snapshot_date) AS streak_start,
    MAX(snapshot_date) AS streak_end,
    COUNT(*)::INT      AS streak_weeks
  FROM streak_tag
  GROUP BY top1_student, grp_key
),
leader_share AS (
  SELECT
    top1_student AS student_name,
    COUNT(*)::INT AS champion_weeks
  FROM top1_only
  GROUP BY top1_student
),
overall AS (
  SELECT
    COUNT(*)::INT AS total_weeks,
    ROUND(AVG((top1_score - top2_score)::NUMERIC), 2) AS avg_top1_margin,
    ROUND(MAX((top1_score - top2_score)::NUMERIC), 2) AS max_top1_margin
  FROM top2
  WHERE top2_score IS NOT NULL
),
risk AS (
  SELECT
    o.total_weeks,
    o.avg_top1_margin,
    o.max_top1_margin,
    COALESCE((SELECT MAX(streak_weeks) FROM streaks), 0) AS max_streak_weeks,
    COALESCE((
      SELECT ROUND(MAX(champion_weeks::NUMERIC / NULLIF(o.total_weeks,0)), 4)
      FROM leader_share
    ), 0) AS max_champion_share
  FROM overall o
)
SELECT
  total_weeks,
  avg_top1_margin,
  max_top1_margin,
  max_streak_weeks,
  max_champion_share,
  CASE
    WHEN max_streak_weeks >= 8 OR max_champion_share >= 0.60 THEN 'HIGH'
    WHEN max_streak_weeks >= 5 OR max_champion_share >= 0.40 THEN 'MEDIUM'
    ELSE 'LOW'
  END AS dominance_risk_level
FROM risk;


-- ---------------------------------------------------------------------------
-- D) 霸榜明细（谁在连冠）
-- ---------------------------------------------------------------------------
WITH params AS (
  SELECT 52::INT AS lookback_weeks
),
scope AS (
  SELECT h.*
  FROM public.student_score_history h
  CROSS JOIN params p
  WHERE h.snapshot_date >= (
    DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE
    - (p.lookback_weeks::TEXT || ' weeks')::INTERVAL
  )
    AND h.composite_score > 0
),
ranked AS (
  SELECT
    snapshot_date,
    student_name,
    composite_score,
    mean_duration,
    record_count,
    RANK() OVER (
      PARTITION BY snapshot_date
      ORDER BY composite_score DESC NULLS LAST,
               mean_duration DESC NULLS LAST,
               record_count DESC NULLS LAST
    ) AS rank_no
  FROM scope
),
top1_only AS (
  SELECT snapshot_date, student_name
  FROM ranked
  WHERE rank_no = 1
),
streak_tag AS (
  SELECT
    student_name,
    snapshot_date,
    (
      snapshot_date::TIMESTAMP
      - (ROW_NUMBER() OVER (PARTITION BY student_name ORDER BY snapshot_date) * INTERVAL '7 day')
    ) AS grp_key
  FROM top1_only
),
streaks AS (
  SELECT
    student_name,
    MIN(snapshot_date) AS streak_start,
    MAX(snapshot_date) AS streak_end,
    COUNT(*)::INT      AS streak_weeks
  FROM streak_tag
  GROUP BY student_name, grp_key
)
SELECT *
FROM streaks
WHERE streak_weeks >= 3
ORDER BY streak_weeks DESC, streak_end DESC
LIMIT 100;

