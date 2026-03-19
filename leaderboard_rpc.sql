-- ============================================================
-- get_weekly_leaderboards()
-- 返回本周四个排行榜数据，供前端直接调用
-- 触发时机：每次 practice_sessions 有新记录（compute_student_score 触发后）
--
-- 返回字段：
--   board                 TEXT    榜单名: 综合榜 / 进步榜 / 稳定榜 / 守则榜
--   rank_no               INT     名次
--   student_name          TEXT    学生姓名
--   student_major         TEXT    专业
--   student_grade         TEXT    年级
--   display_score         NUMERIC 综合排名分（本周快照 or 基线值）
--   alpha                 NUMERIC 基线可信度 α
--   trend_score           NUMERIC 进步榜：(本周综合分 - 上周综合分) / 上周综合分 × 100（百分比涨幅）；其他榜：趋势分
--   mean_duration         NUMERIC 近期均练时长（分钟）
--   record_count          INT     历史总记录数
--   recent10_outlier_rate NUMERIC 近10条异常率
--   recent10_mean_dur     NUMERIC 近10条平均时长
--   recent10_count        INT     近10条记录数（12周内实际数）
-- ============================================================

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
AS $$
WITH
/* ── 本周一（北京时间） ── */
week_monday AS (
    SELECT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS monday
),

/* ── 近12周内最多10条有效 session（不过滤工作日，与前端口径一致） ── */
recent10 AS (
    SELECT
        student_name,
        COUNT(*)::INTEGER                                      AS cnt,
        ROUND(AVG((is_outlier)::INT)::NUMERIC, 4)             AS outlier_rate,
        ROUND(AVG(cleaned_duration)::NUMERIC, 2)              AS mean_dur
    FROM (
        SELECT
            student_name,
            is_outlier,
            cleaned_duration,
            ROW_NUMBER() OVER (PARTITION BY student_name ORDER BY session_start DESC) AS rn
        FROM public.practice_sessions
        WHERE cleaned_duration > 0
          AND session_start >= NOW() - INTERVAL '12 weeks'
    ) sub
    WHERE rn <= 10
    GROUP BY student_name
),

/* ── 本周练习次数（含周末，与前端 fetchActiveThisWeek 口径一致） ── */
week_cnt AS (
    SELECT
        student_name,
        COUNT(*)::INTEGER AS cnt
    FROM public.practice_sessions
    CROSS JOIN week_monday
    WHERE session_start >= monday::TIMESTAMPTZ
    GROUP BY student_name
),

/* ── 本周成长分快照 ── */
week_scores AS (
    SELECT
        ssh.student_name,
        ssh.composite_score,
        ssh.raw_score,
        ssh.trend_score,
        ssh.baseline_score,
        ssh.mean_duration,
        ssh.record_count::INTEGER,
        ssh.outlier_rate
    FROM public.student_score_history ssh
    CROSS JOIN week_monday wm
    WHERE ssh.snapshot_date = wm.monday
      AND ssh.composite_score > 0
),

/* ── 进步榜基准：最近 2 个活跃周的最高综合分
   取最大值而非最近一周，防止"节后低分周"或偶发低分周被当作基准导致涨幅虚高
   逻辑：本周之前最多回溯 12 周，找 composite_score > 0 的最近 2 周，取 MAX
   这样必须真正超越近期最佳表现才能上进步榜 ── */
last_week_scores AS (
    SELECT
        student_name,
        MAX(composite_score) AS lw_composite  -- 近2个有效周的最高分作为基准
    FROM (
        SELECT
            ssh.student_name,
            ssh.composite_score,
            ROW_NUMBER() OVER (
                PARTITION BY ssh.student_name
                ORDER BY ssh.snapshot_date DESC
            ) AS rn
        FROM public.student_score_history ssh
        CROSS JOIN week_monday wm
        WHERE ssh.snapshot_date <  wm.monday
          AND ssh.snapshot_date >= wm.monday - INTERVAL '12 weeks'
          AND ssh.composite_score > 0
    ) recent
    WHERE rn <= 2                              -- 只取最近 2 个有效周
    GROUP BY student_name
),

/* ── 综合排行榜候选池：本周有练琴 + composite_score > 0 ── */
ranked_pool AS (
    SELECT
        wc.student_name,
        sb.student_major,
        sb.student_grade,
        /* display_score：本周快照优先，否则用基线存档值 */
        COALESCE(ws.composite_score, sb.composite_score)          AS display_score,
        sb.alpha,
        ws.trend_score,
        COALESCE(ws.mean_duration, sb.mean_duration)              AS mean_duration,
        COALESCE(ws.record_count, sb.record_count)::INTEGER        AS record_count,
        wc.cnt                                                    AS week_sessions
    FROM week_cnt wc
    JOIN public.student_baseline sb ON sb.student_name = wc.student_name
    LEFT JOIN week_scores ws        ON ws.student_name = wc.student_name
    WHERE COALESCE(ws.composite_score, sb.composite_score, 0) > 0
),

/* ── ① 综合榜：按 display_score 降序，同分时依次用 mean_duration、record_count 区分 ── */
comp AS (
    SELECT
        '综合榜'::TEXT                                               AS board,
        RANK() OVER (
            ORDER BY rp.display_score   DESC NULLS LAST,
                     rp.mean_duration   DESC NULLS LAST,
                     rp.record_count    DESC NULLS LAST
        )::INTEGER                                                   AS rank_no,
        rp.student_name, rp.student_major, rp.student_grade,
        rp.display_score, rp.alpha, rp.trend_score, rp.mean_duration, rp.record_count,
        r10.outlier_rate  AS recent10_outlier_rate,
        r10.mean_dur      AS recent10_mean_dur,
        r10.cnt           AS recent10_count
    FROM ranked_pool rp
    LEFT JOIN recent10 r10 ON r10.student_name = rp.student_name
),

/* ── ② 进步榜：本周综合分相对上周涨幅（%）最大
   排序：(本周 - 上周) / 上周 × 100 DESC（百分比涨幅）
   trend_score 列复用为百分比涨幅，前端展示 "+XX.X%"
   过滤：必须上周有数据且 ≥ 10 分 + 本周真的比上周进步 + α ≥ 0.50 + 近10条异常率 ≤ 0.70 + 综合分 ≥ 15 ── */
prog AS (
    SELECT
        '进步榜'::TEXT                                               AS board,
        RANK() OVER (
            ORDER BY (rp.display_score - lws.lw_composite)
                     / lws.lw_composite * 100              DESC NULLS LAST,
                     rp.display_score                       DESC NULLS LAST,
                     rp.mean_duration                       DESC NULLS LAST
        )::INTEGER                                                   AS rank_no,
        rp.student_name, rp.student_major, rp.student_grade,
        rp.display_score, rp.alpha,
        /* trend_score 复用为百分比涨幅，保留1位小数，前端显示 "+XX.X%" */
        ROUND((rp.display_score - lws.lw_composite)
              / lws.lw_composite * 100, 1)                           AS trend_score,
        rp.mean_duration, rp.record_count,
        r10.outlier_rate  AS recent10_outlier_rate,
        r10.mean_dur      AS recent10_mean_dur,
        r10.cnt           AS recent10_count
    FROM ranked_pool rp
    INNER JOIN last_week_scores lws ON lws.student_name = rp.student_name
    LEFT JOIN  recent10         r10 ON r10.student_name = rp.student_name
    WHERE (rp.display_score - lws.lw_composite)      > 0
      AND lws.lw_composite                            >= 10   -- 防止基数过小导致百分比虚高
      AND COALESCE(rp.alpha, 0)                       >= 0.50
      AND COALESCE(r10.outlier_rate, 1)               <= 0.70
      AND rp.display_score                            >= 15
),

/* ── ③ 稳定榜 Top 6：近10次均时最长（代表持续踏实练习），并列时 α 降序
   过滤：α ≥ 0.65 + 近10条 ≥ 10 条 + 近10条异常率 ≤ 0.35 ── */
stable AS (
    SELECT
        '稳定榜'::TEXT                                               AS board,
        RANK() OVER (
            ORDER BY COALESCE(r10.mean_dur, 0) DESC NULLS LAST,
                     rp.alpha                  DESC NULLS LAST
        )::INTEGER                                                   AS rank_no,
        rp.student_name, rp.student_major, rp.student_grade,
        rp.display_score, rp.alpha, rp.trend_score, rp.mean_duration, rp.record_count,
        r10.outlier_rate  AS recent10_outlier_rate,
        r10.mean_dur      AS recent10_mean_dur,
        r10.cnt           AS recent10_count
    FROM ranked_pool rp
    LEFT JOIN recent10 r10 ON r10.student_name = rp.student_name
    WHERE COALESCE(rp.alpha, 0)         >= 0.65
      AND COALESCE(r10.cnt, 0)          >= 10
      AND COALESCE(r10.outlier_rate, 1) <= 0.35
),

/* ── ④ 守则榜 Top 6：近10条异常率最低（ASC），并列时本周练琴次数↓、均时↓
   过滤：近10条 ≥ 5条 + 均时 > 30min + 异常率 ≤ 50% + α ≥ 0.60 + 本周 ≥ 5 次 ── */
rules AS (
    SELECT
        '守则榜'::TEXT                                               AS board,
        RANK() OVER (
            ORDER BY
                COALESCE(r10.outlier_rate, 1) ASC,
                rp.week_sessions              DESC NULLS LAST,
                COALESCE(r10.mean_dur, 0)     DESC
        )::INTEGER                                                   AS rank_no,
        rp.student_name, rp.student_major, rp.student_grade,
        rp.display_score, rp.alpha, rp.trend_score, rp.mean_duration, rp.record_count,
        r10.outlier_rate  AS recent10_outlier_rate,
        r10.mean_dur      AS recent10_mean_dur,
        r10.cnt           AS recent10_count
    FROM ranked_pool rp
    LEFT JOIN recent10 r10 ON r10.student_name = rp.student_name
    WHERE COALESCE(r10.cnt, 0)          >= 5
      AND COALESCE(r10.mean_dur, 0)     > 30
      AND COALESCE(r10.outlier_rate, 1) <= 0.50
      AND COALESCE(rp.alpha, 0)         >= 0.60
      AND rp.week_sessions              >= 5
)

SELECT board, rank_no, student_name, student_major, student_grade,
       display_score, alpha, trend_score, mean_duration, record_count,
       recent10_outlier_rate, recent10_mean_dur, recent10_count
FROM comp   -- 综合榜：全部入池学生均返回

UNION ALL
SELECT board, rank_no, student_name, student_major, student_grade,
       display_score, alpha, trend_score, mean_duration, record_count,
       recent10_outlier_rate, recent10_mean_dur, recent10_count
FROM prog   -- 进步榜：所有通过过滤条件的学生均返回

UNION ALL
SELECT board, rank_no, student_name, student_major, student_grade,
       display_score, alpha, trend_score, mean_duration, record_count,
       recent10_outlier_rate, recent10_mean_dur, recent10_count
FROM stable -- 稳定榜：所有通过过滤条件的学生均返回

UNION ALL
SELECT board, rank_no, student_name, student_major, student_grade,
       display_score, alpha, trend_score, mean_duration, record_count,
       recent10_outlier_rate, recent10_mean_dur, recent10_count
FROM rules  -- 守则榜：所有通过过滤条件的学生均返回

ORDER BY board, rank_no;
$$;

-- 授权 anon/authenticated 均可调用
GRANT EXECUTE ON FUNCTION public.get_weekly_leaderboards() TO anon, authenticated;
