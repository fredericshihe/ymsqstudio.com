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
--   trend_score           NUMERIC 进步榜：本周综合分 - 近期最高历史周综合分（绝对涨分，单位：分）；其他榜：趋势分
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

/* ── 近12周内最多10条有效工作日 session（与评分口径一致，周末不计榜） ── */
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
          AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    ) sub
    WHERE rn <= 10
    GROUP BY student_name
),

/* ── 本周工作日练习次数（与评分口径一致，周末不计榜） ── */
week_cnt AS (
    SELECT
        student_name,
        COUNT(*)::INTEGER AS cnt
    FROM public.practice_sessions
    CROSS JOIN week_monday
    WHERE session_start >= ((monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai')
      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
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

/* ── 综合榜 Top 10 名单：专项榜（进步/稳定/守则）排除这些学生
   设计原则：综合榜前十名已获最高荣誉，专项榜留给有特定优势的其他学生
   这样 4 个榜能展示更多不同的学生，激励效果更广泛 ── */
comp_top10 AS (
    SELECT student_name
    FROM comp
    WHERE rank_no <= 10
),

/* ── ② 进步榜：绝对分提升最大（FIX-63 科学最小门槛设计）
   设计原则：过滤条件只"防假"，不"防小"——小进步也是进步，由排名决定位次
   FIX-58: 改为绝对涨分排序，百分比仅作展示
   FIX-63: 取消分数绝对值门槛（lw_composite/display_score/alpha），
           只保留最小必要防护条件
   过滤条件（最小必要）：
     · 有历史对比数据（INNER JOIN last_week_scores，无快照则无从比较）
     · 本周练琴次数 ≥ 2（最低参与度，至少两次才算一周有效参与）
     · 绝对涨幅 > 0（有真实进步，哪怕 +1 分）
     · 近10条异常率 ≤ 0.50（防明显刷数据，宽容正常波动）
     · 不在综合榜 Top 10（FIX-65，保持榜单差异化）
   排序：绝对涨分 DESC → 本周综合分 DESC → 均时 DESC ── */
prog AS (
    SELECT
        '进步榜'::TEXT                                               AS board,
        RANK() OVER (
            ORDER BY (rp.display_score - lws.lw_composite)  DESC NULLS LAST,
                     rp.display_score                        DESC NULLS LAST,
                     rp.mean_duration                        DESC NULLS LAST
        )::INTEGER                                                   AS rank_no,
        rp.student_name, rp.student_major, rp.student_grade,
        rp.display_score, rp.alpha,
        /* trend_score 存绝对涨分（本周 - 近期最高历史周），供前端显示 "+X.X 分"
           注意：不用百分比——因实际涨幅通常 0.1~3 分，换算百分比后 ROUND 几乎全为 0.0% */
        ROUND((rp.display_score - lws.lw_composite)::NUMERIC, 1)     AS trend_score,
        rp.mean_duration, rp.record_count,
        r10.outlier_rate  AS recent10_outlier_rate,
        r10.mean_dur      AS recent10_mean_dur,
        r10.cnt           AS recent10_count
    FROM ranked_pool rp
    INNER JOIN last_week_scores lws ON lws.student_name = rp.student_name
    LEFT JOIN  recent10         r10 ON r10.student_name = rp.student_name
    WHERE (rp.display_score - lws.lw_composite)      >  0    -- 有任意正增长（排名决定位次）
      AND rp.week_sessions                            >= 2    -- 本周至少练 2 次
      AND COALESCE(r10.outlier_rate, 1)               <= 0.50 -- 防明显刷数据（宽容正常波动）
      AND rp.student_name NOT IN (SELECT student_name FROM comp_top10)  -- FIX-65
),

/* ── ③ 稳定榜 Top 6：练琴模式最可预测（FIX-64 概念修正）
   科学定义："稳定"= 练琴行为一致、可预测，而非练得最久
   排序：α DESC（可预测性/一致性）→ mean_dur DESC（同等稳定时，练得更长的排前）→ outlier_rate ASC
   过滤条件（最小防假）：
     · α ≥ 0.55（有足够历史数据支撑可信度评估）
     · 近10条 ≥ 8 条（有连续性记录积累，才能谈稳定）
     · 近10条异常率 ≤ 0.40（异常太多的练习模式称不上稳定）
   FIX-65: 综合榜 Top10 退出本榜 ── */
stable AS (
    SELECT
        '稳定榜'::TEXT                                               AS board,
        RANK() OVER (
            ORDER BY rp.alpha                  DESC NULLS LAST,  -- 一致性优先
                     COALESCE(r10.mean_dur, 0) DESC NULLS LAST,  -- 同等稳定时，时长更长排前
                     COALESCE(r10.outlier_rate, 1) ASC           -- 异常率作为最终区分
        )::INTEGER                                                   AS rank_no,
        rp.student_name, rp.student_major, rp.student_grade,
        rp.display_score, rp.alpha, rp.trend_score, rp.mean_duration, rp.record_count,
        r10.outlier_rate  AS recent10_outlier_rate,
        r10.mean_dur      AS recent10_mean_dur,
        r10.cnt           AS recent10_count
    FROM ranked_pool rp
    LEFT JOIN recent10 r10 ON r10.student_name = rp.student_name
    WHERE COALESCE(rp.alpha, 0)         >= 0.55  -- 有足够历史积累的可信度门槛
      AND COALESCE(r10.cnt, 0)          >= 8     -- 近12周至少8次有效记录（约每10天一次）
      AND COALESCE(r10.outlier_rate, 1) <= 0.40  -- 近10次中至多4次异常
      AND rp.student_name NOT IN (SELECT student_name FROM comp_top10)  -- FIX-65
),

/* ── ④ 守则榜 Top 6：遵守练习规则最好（FIX-64 次数门槛修正）
   科学定义："守则"= 出勤达标 + 练习内容合规（低异常率）+ 时长合格
   排序：outlier_rate ASC（异常最少）→ week_sessions DESC（出勤更多）→ mean_dur DESC（时长更长）
   过滤条件：
     · 本周练琴次数 ≥ 3（出勤达标：一周至少3天，体现"有在认真来"）
     · 近10条 ≥ 4 条（有足够历史记录评估合规性）
     · 近10条均时 > 25min（时长须达到最低练习标准，防走过场）
     · 近10条异常率 ≤ 0.50（异常多于一半则失去"守则"资格）
     · α ≥ 0.55（有数据积累，行为有据可查）
   FIX-65: 综合榜 Top10 退出本榜 ── */
rules AS (
    SELECT
        '守则榜'::TEXT                                               AS board,
        RANK() OVER (
            ORDER BY
                COALESCE(r10.outlier_rate, 1) ASC,   -- 异常最少者最守则
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
    WHERE rp.week_sessions              >= 3     -- 本周至少3次（合规出勤，非要求每天必到）
      AND COALESCE(r10.cnt, 0)          >= 4     -- 近12周至少4次有效记录
      AND COALESCE(r10.mean_dur, 0)     > 25    -- 平均时长须超25分钟（防走过场）
      AND COALESCE(r10.outlier_rate, 1) <= 0.50 -- 近10次中至多5次异常
      AND COALESCE(rp.alpha, 0)         >= 0.55 -- 有足够历史数据
      AND rp.student_name NOT IN (SELECT student_name FROM comp_top10)  -- FIX-65
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
