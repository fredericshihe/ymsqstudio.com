-- ============================================================
-- 历史音符币还原模拟  （粘贴到 Supabase SQL Editor 执行）
-- 文件：simulate_historical_coins.sql
--
-- 数据范围：student_score_history 最早记录 → 2026-02-15 之前
--   全量 17 个有效周（2025-10-13 ~ 2026-02-02）
--   分段 13 个有效周（2025-11-03 ~ 2026-01-26）
--
-- 奖励规则（与 reward_weekly_coins() 完全一致）：
--   名次        综合榜   稳定榜   守则榜   进步榜
--   第 1 名      100      50       45       40
--   第 2–3 名     80      35       30       25
--   第 4–6 名     60      20       18       15
--   第 7–10 名    40      —        —        —
--
-- 三段查询（选择其中一段的最终 SELECT 执行即可）：
--   §1 全量汇总（默认激活）
--   §2 分段汇总  2025-11-01 ~ 2026-02-01（取消注释后替换末尾 SELECT）
--   §3 每周明细（取消注释后替换末尾 SELECT）
-- ============================================================

WITH

/* ─────────────────────────────────────────────────────────
   A. 目标周列表：全部历史中 composite_score > 0 且 < 2026-02-15
   ───────────────────────────────────────────────────────── */
all_weeks AS (
    SELECT DISTINCT snapshot_date AS week_monday
    FROM public.student_score_history
    WHERE composite_score > 0
      AND snapshot_date < '2026-02-15'::DATE
),

/* ─────────────────────────────────────────────────────────
   B. 每周每学生练琴次数（北京时间 TRUNC 对齐 snapshot_date）
   ───────────────────────────────────────────────────────── */
hist_week_cnt AS (
    SELECT
        DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE AS week_monday,
        ps.student_name,
        COUNT(*)::INTEGER AS week_sessions
    FROM public.practice_sessions ps
    WHERE ps.session_start < '2026-02-15'::DATE::TIMESTAMPTZ
    GROUP BY 1, 2
),

/* ─────────────────────────────────────────────────────────
   C. 每周结束时的 recent10 指标
      取该周结束（week_monday + 7天）前、最多回溯12周的最近10条有效 session
   ───────────────────────────────────────────────────────── */
hist_recent10_raw AS (
    SELECT
        aw.week_monday,
        ps.student_name,
        ps.is_outlier,
        ps.cleaned_duration,
        ROW_NUMBER() OVER (
            PARTITION BY aw.week_monday, ps.student_name
            ORDER BY ps.session_start DESC
        ) AS rn
    FROM all_weeks aw
    JOIN public.practice_sessions ps
        ON ps.session_start <  (aw.week_monday + INTERVAL '7 days')
       AND ps.session_start >= (aw.week_monday - INTERVAL '84 days')
       AND ps.cleaned_duration > 0
),
hist_recent10 AS (
    SELECT
        week_monday,
        student_name,
        COUNT(*)::INTEGER                               AS r10_cnt,
        ROUND(AVG((is_outlier)::INT)::NUMERIC, 4)      AS r10_outlier,
        ROUND(AVG(cleaned_duration)::NUMERIC, 2)       AS r10_mean_dur
    FROM hist_recent10_raw
    WHERE rn <= 10
    GROUP BY week_monday, student_name
),

/* ─────────────────────────────────────────────────────────
   D. 每周得分快照（来自 student_score_history）
   ───────────────────────────────────────────────────────── */
hist_scores AS (
    SELECT
        snapshot_date         AS week_monday,
        student_name,
        composite_score       AS display_score,
        alpha,
        mean_duration,
        record_count::INTEGER
    FROM public.student_score_history
    WHERE composite_score > 0
      AND snapshot_date < '2026-02-15'::DATE
),

/* ─────────────────────────────────────────────────────────
   E. 进步榜基准：该周之前最近 2 个有效周的最高综合分（防低分周虚高）
   ───────────────────────────────────────────────────────── */
hist_prog_baseline_raw AS (
    SELECT
        aw.week_monday                     AS curr_week,
        ssh.student_name,
        ssh.composite_score,
        ROW_NUMBER() OVER (
            PARTITION BY aw.week_monday, ssh.student_name
            ORDER BY ssh.snapshot_date DESC
        ) AS rn
    FROM all_weeks aw
    JOIN public.student_score_history ssh
        ON ssh.snapshot_date <  aw.week_monday
       AND ssh.snapshot_date >= aw.week_monday - INTERVAL '84 days'
       AND ssh.composite_score > 0
),
hist_prog_baseline AS (
    SELECT
        curr_week          AS week_monday,
        student_name,
        MAX(composite_score) AS lw_composite
    FROM hist_prog_baseline_raw
    WHERE rn <= 2
    GROUP BY curr_week, student_name
),

/* ─────────────────────────────────────────────────────────
   F. 综合候选池
   ───────────────────────────────────────────────────────── */
hist_pool AS (
    SELECT
        hwc.week_monday,
        hwc.student_name,
        hs.display_score,
        hs.alpha,
        hs.mean_duration,
        hs.record_count,
        hwc.week_sessions,
        COALESCE(hr.r10_outlier,  1) AS r10_outlier,
        COALESCE(hr.r10_mean_dur, 0) AS r10_mean_dur,
        COALESCE(hr.r10_cnt,      0) AS r10_cnt
    FROM hist_week_cnt hwc
    JOIN hist_scores hs
        ON  hs.week_monday  = hwc.week_monday
        AND hs.student_name = hwc.student_name
    LEFT JOIN hist_recent10 hr
        ON  hr.week_monday  = hwc.week_monday
        AND hr.student_name = hwc.student_name
),

/* ─────────────────────────────────────────────────────────
   G. 四榜排名
   ───────────────────────────────────────────────────────── */

-- ① 综合榜
board_comp AS (
    SELECT week_monday, student_name, '综合榜'::TEXT AS board,
        RANK() OVER (
            PARTITION BY week_monday
            ORDER BY display_score DESC NULLS LAST,
                     mean_duration  DESC NULLS LAST,
                     record_count   DESC NULLS LAST
        )::INTEGER AS rank_no
    FROM hist_pool
),

-- ② 稳定榜（近10次均时最长，α 为次级）
board_stable AS (
    SELECT week_monday, student_name, '稳定榜'::TEXT AS board,
        RANK() OVER (
            PARTITION BY week_monday
            ORDER BY r10_mean_dur DESC NULLS LAST,
                     alpha         DESC NULLS LAST
        )::INTEGER AS rank_no
    FROM hist_pool
    WHERE alpha        >= 0.65
      AND r10_cnt      >= 10
      AND r10_outlier  <= 0.35
),

-- ③ 守则榜（异常率最低，本周次数为次级）
board_rules AS (
    SELECT week_monday, student_name, '守则榜'::TEXT AS board,
        RANK() OVER (
            PARTITION BY week_monday
            ORDER BY r10_outlier  ASC,
                     week_sessions DESC NULLS LAST,
                     r10_mean_dur  DESC
        )::INTEGER AS rank_no
    FROM hist_pool
    WHERE r10_cnt      >= 5
      AND r10_mean_dur  > 30
      AND r10_outlier  <= 0.50
      AND alpha        >= 0.60
      AND week_sessions >= 5
),

-- ④ 进步榜（相对涨幅百分比最大）
board_prog AS (
    SELECT hp.week_monday, hp.student_name, '进步榜'::TEXT AS board,
        RANK() OVER (
            PARTITION BY hp.week_monday
            ORDER BY (hp.display_score - pb.lw_composite) / pb.lw_composite * 100 DESC NULLS LAST,
                     hp.display_score DESC NULLS LAST,
                     hp.mean_duration DESC NULLS LAST
        )::INTEGER AS rank_no
    FROM hist_pool hp
    INNER JOIN hist_prog_baseline pb
        ON  pb.week_monday  = hp.week_monday
        AND pb.student_name = hp.student_name
    WHERE hp.display_score  > pb.lw_composite
      AND pb.lw_composite  >= 10
      AND hp.alpha          >= 0.50
      AND hp.r10_outlier   <= 0.70
      AND hp.display_score >= 15
),

/* ─────────────────────────────────────────────────────────
   H. 合并四榜 + 按规则计算音符币
   ───────────────────────────────────────────────────────── */
all_boards AS (
    SELECT * FROM board_comp
    UNION ALL SELECT * FROM board_stable
    UNION ALL SELECT * FROM board_rules
    UNION ALL SELECT * FROM board_prog
),
coin_awards AS (
    SELECT
        week_monday,
        board,
        rank_no,
        student_name,
        CASE
            WHEN board = '综合榜' THEN
                CASE WHEN rank_no = 1               THEN 100
                     WHEN rank_no BETWEEN 2 AND  3  THEN  80
                     WHEN rank_no BETWEEN 4 AND  6  THEN  60
                     WHEN rank_no BETWEEN 7 AND 10  THEN  40
                     ELSE 0 END
            WHEN board = '稳定榜' THEN
                CASE WHEN rank_no = 1               THEN  50
                     WHEN rank_no BETWEEN 2 AND  3  THEN  35
                     WHEN rank_no BETWEEN 4 AND  6  THEN  20
                     ELSE 0 END
            WHEN board = '守则榜' THEN
                CASE WHEN rank_no = 1               THEN  45
                     WHEN rank_no BETWEEN 2 AND  3  THEN  30
                     WHEN rank_no BETWEEN 4 AND  6  THEN  18
                     ELSE 0 END
            WHEN board = '进步榜' THEN
                CASE WHEN rank_no = 1               THEN  40
                     WHEN rank_no BETWEEN 2 AND  3  THEN  25
                     WHEN rank_no BETWEEN 4 AND  6  THEN  15
                     ELSE 0 END
            ELSE 0
        END AS coins
    FROM all_boards
)

/* ================================================================
   §1  全量汇总：所有历史（2025-10-13 ~ 2026-02-02，共17周）
       直接运行下方 SELECT，查看每位学生历史应得音符币
   ================================================================ */
SELECT
    student_name                                                    AS "学生",
    SUM(coins)                                                      AS "历史总音符币",
    COUNT(DISTINCT week_monday) FILTER (WHERE coins > 0)           AS "上榜总周次",
    COUNT(*)  FILTER (WHERE board = '综合榜' AND coins > 0)        AS "综合榜次",
    COUNT(*)  FILTER (WHERE board = '稳定榜' AND coins > 0)        AS "稳定榜次",
    COUNT(*)  FILTER (WHERE board = '守则榜' AND coins > 0)        AS "守则榜次",
    COUNT(*)  FILTER (WHERE board = '进步榜' AND coins > 0)        AS "进步榜次",
    SUM(coins) FILTER (WHERE board = '综合榜')                     AS "综合榜币",
    SUM(coins) FILTER (WHERE board = '稳定榜')                     AS "稳定榜币",
    SUM(coins) FILTER (WHERE board = '守则榜')                     AS "守则榜币",
    SUM(coins) FILTER (WHERE board = '进步榜')                     AS "进步榜币",
    MIN(rank_no) FILTER (WHERE board = '综合榜' AND coins > 0)     AS "综合最佳名次"
FROM coin_awards
WHERE coins > 0
GROUP BY student_name
ORDER BY SUM(coins) DESC;


/* ================================================================
   §2  分段汇总：2025-11-01 ~ 2026-02-01（共13周）
       用下方 SELECT 替换上方 §1 的 SELECT 后运行
   ================================================================
SELECT
    student_name                                                    AS "学生",
    SUM(coins)                                                      AS "期间总音符币",
    COUNT(DISTINCT week_monday) FILTER (WHERE coins > 0)           AS "期间上榜周次",
    COUNT(*)  FILTER (WHERE board = '综合榜' AND coins > 0)        AS "综合榜次",
    COUNT(*)  FILTER (WHERE board = '稳定榜' AND coins > 0)        AS "稳定榜次",
    COUNT(*)  FILTER (WHERE board = '守则榜' AND coins > 0)        AS "守则榜次",
    COUNT(*)  FILTER (WHERE board = '进步榜' AND coins > 0)        AS "进步榜次",
    SUM(coins) FILTER (WHERE board = '综合榜')                     AS "综合榜币",
    SUM(coins) FILTER (WHERE board = '稳定榜')                     AS "稳定榜币",
    SUM(coins) FILTER (WHERE board = '守则榜')                     AS "守则榜币",
    SUM(coins) FILTER (WHERE board = '进步榜')                     AS "进步榜币"
FROM coin_awards
WHERE coins > 0
  AND week_monday >= '2025-11-03'::DATE   -- 2025-11-01 所在周的周一
  AND week_monday <  '2026-02-02'::DATE   -- 2026-02-01 所在周的下一个周一
GROUP BY student_name
ORDER BY SUM(coins) DESC;
*/


/* ================================================================
   §3  每周明细：查看每一周每位学生的具体上榜及得币情况
       用下方 SELECT 替换上方 §1 的 SELECT 后运行
   ================================================================
SELECT
    TO_CHAR(week_monday, 'YYYY-MM-DD')  AS "周一日期",
    board                               AS "榜单",
    rank_no                             AS "名次",
    student_name                        AS "学生",
    coins                               AS "应得音符币"
FROM coin_awards
WHERE coins > 0
ORDER BY week_monday ASC, board, rank_no;
*/
