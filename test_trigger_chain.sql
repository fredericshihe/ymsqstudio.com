-- ============================================================
-- 触发链端到端测试脚本
-- 验证：新练琴记录 → composite_score 更新 → 排行榜变化
--
-- 三个测试层级（由安全到完整）：
--   【测试一】只读诊断  — 零风险，验证触发链函数是否可调用
--   【测试二】手动触发  — 零风险，模拟触发链中段，不写假数据
--   【测试三】完整端到端 — 写入真实测试记录，验证完整链路
-- ============================================================


-- ════════════════════════════════════════════════════════════
-- 【测试一】只读诊断：触发链函数存在性 & SECURITY DEFINER 核查
-- 风险：零  预期耗时：<1s
-- ════════════════════════════════════════════════════════════

-- 1A. 三个触发器函数全部存在且为 SECURITY DEFINER？
SELECT
    proname                                                          AS "函数名",
    CASE prosecdef WHEN true THEN '✅ SECURITY DEFINER' ELSE '❌ 缺少' END AS "安全模式",
    CASE
        WHEN proname = 'trigger_insert_session'
         AND pg_get_functiondef(oid) LIKE $q$%AT TIME ZONE 'Asia/Shanghai')::TIME%$q$
            THEN '✅ FIX-72 时区已修正'
        WHEN proname = 'trigger_update_student_baseline'
         AND pg_get_functiondef(oid) NOT LIKE '%v_live_count%'
            THEN '✅ FIX-71 每次必触发'
        WHEN proname = 'trigger_compute_student_score'
         AND pg_get_functiondef(oid) LIKE '%compute_and_store_w_score%'
            THEN '✅ FIX-23 含W分更新'
        ELSE '⚠️  请检查版本'
    END                                                              AS "版本特征"
FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
  AND proname IN (
      'trigger_insert_session',
      'trigger_update_student_baseline',
      'trigger_compute_student_score'
  )
ORDER BY proname;


-- 1B. 三条触发器绑定正确？
SELECT
    tg.tgname                AS "触发器名",
    c.relname                AS "所属表",
    CASE tg.tgtype & 28
        WHEN 4  THEN 'INSERT'
        WHEN 16 THEN 'UPDATE'
        WHEN 20 THEN 'INSERT+UPDATE'  -- 4+16
        WHEN 28 THEN 'INSERT+UPDATE+DELETE'
        ELSE (tg.tgtype & 28)::TEXT
    END                      AS "监听事件",
    p.proname                AS "触发函数",
    CASE tg.tgenabled WHEN 'O' THEN '✅ 启用' ELSE '❌ 禁用' END AS "状态"
FROM pg_trigger tg
JOIN pg_class c     ON c.oid = tg.tgrelid
JOIN pg_proc  p     ON p.oid = tg.tgfoid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND NOT tg.tgisinternal
  AND c.relname IN ('practice_logs', 'practice_sessions', 'student_baseline')
ORDER BY c.relname;
-- 预期：
--   practice_logs      INSERT       trigger_insert_session        ✅
--   practice_sessions  INSERT+UPDATE trigger_update_student_baseline ✅
--   student_baseline   UPDATE        trigger_compute_student_score  ✅


-- ════════════════════════════════════════════════════════════
-- 【测试二】手动触发链中段：验证 baseline→score 计算是否正常
-- 风险：零（不写假数据，直接调用函数）
-- 操作：选一个真实学生，手动触发 update_student_baseline
-- ════════════════════════════════════════════════════════════

-- 2A. 先记录测试前的状态（替换 '张三' 为任意有练琴记录的学生）
SELECT
    student_name,
    composite_score                                            AS "测试前综合分",
    last_updated                                               AS "测试前更新时间",
    NOW() AT TIME ZONE 'Asia/Shanghai'                         AS "当前北京时间"
FROM public.student_baseline
WHERE student_name = '张三';   -- ← 替换为真实学生姓名


-- 2B. 手动触发 baseline 重算（模拟触发链第2→3环）
-- 这会触发 student_baseline UPDATE → trigger_compute_student_score → compute_student_score
SELECT public.update_student_baseline('张三');  -- ← 同上，替换学生姓名


-- 2C. 等2-3秒后，查看分数是否更新（last_updated 应变为刚才的时间）
SELECT
    student_name,
    composite_score                                            AS "测试后综合分",
    last_updated                                               AS "测试后更新时间",
    CASE
        WHEN last_updated > NOW() - INTERVAL '10 seconds'
            THEN '✅ 触发链正常：分数已实时更新'
        ELSE '❌ 触发链异常：last_updated 未刷新'
    END                                                        AS "诊断结果"
FROM public.student_baseline
WHERE student_name = '张三';


-- 2D. 同时确认 student_score_history 也写入了本周快照
SELECT
    student_name,
    snapshot_date,
    composite_score,
    raw_score,
    trend_score
FROM public.student_score_history
WHERE student_name = '张三'
ORDER BY snapshot_date DESC
LIMIT 3;


-- ════════════════════════════════════════════════════════════
-- 【测试三】完整端到端：插入真实测试记录，验证完整链路
-- 风险：低（会创建一条真实 practice_session，可事后删除）
-- 前提：先部署 fix_stale_cleaned_duration.sql（FIX-73 SECURITY DEFINER 版本）
-- ════════════════════════════════════════════════════════════

-- 3A. 记录测试前状态 & 当前所在排行榜名次
WITH before_state AS (
    SELECT student_name, composite_score, last_updated
    FROM public.student_baseline
    WHERE student_name = '张三'
),
before_rank AS (
    SELECT student_name, rank_no, display_score
    FROM public.get_weekly_leaderboards()
    WHERE board = '综合榜' AND student_name = '张三'
)
SELECT
    b.student_name,
    b.composite_score  AS "测试前综合分",
    b.last_updated     AS "测试前更新时间",
    r.rank_no          AS "测试前排名（综合榜）"
FROM before_state b
LEFT JOIN before_rank r USING (student_name);


-- 3B. 插入测试登记 + 登出记录（模拟学生练琴 40 分钟）
-- ⚠️ 替换以下变量：
--   v_student   = 真实学生姓名
--   v_room      = 真实琴房名（如 M211）
--   v_major     = 学生专业（如 钢琴）
--   v_grade     = 学生年级（如 大一）
DO $$
DECLARE
    v_student TEXT := '张三';    -- ← 替换
    v_room    TEXT := 'M211';   -- ← 替换
    v_major   TEXT := '钢琴';   -- ← 替换
    v_grade   TEXT := '大一';   -- ← 替换
    v_assign_time TIMESTAMPTZ := NOW() - INTERVAL '40 minutes';
    v_clear_time  TIMESTAMPTZ := NOW();
BEGIN
    -- 插入 assign（登记）
    INSERT INTO public.practice_logs
        (student_name, student_major, student_grade, room_name, action, created_at)
    VALUES
        (v_student, v_major, v_grade, v_room, 'assign', v_assign_time);

    -- 插入 clear（登出）→ 触发 trigger_insert_session → 触发完整链
    INSERT INTO public.practice_logs
        (student_name, student_major, student_grade, room_name, action, created_at)
    VALUES
        (v_student, v_major, v_grade, v_room, 'clear', v_clear_time);

    RAISE NOTICE '测试记录已插入：% @ %，时长约40分钟', v_student, v_room;
END;
$$;


-- 3C. 等3-5秒后运行（等待触发链完成），检查完整链路结果
SELECT
    '① practice_sessions'                AS "检查点",
    student_name,
    session_start::TEXT,
    raw_duration::TEXT || ' 分钟'        AS "原始时长",
    cleaned_duration::TEXT || ' 分钟'    AS "清洁时长",
    is_outlier::TEXT                     AS "是否异常",
    outlier_reason                       AS "异常原因"
FROM public.practice_sessions
WHERE student_name = '张三'              -- ← 替换
ORDER BY session_start DESC LIMIT 1

UNION ALL

SELECT
    '② student_baseline（分数更新）',
    student_name,
    last_updated::TEXT,
    composite_score::TEXT || ' 分',
    raw_score::TEXT,
    CASE WHEN last_updated > NOW() - INTERVAL '30 seconds'
         THEN '✅ 已实时更新' ELSE '❌ 未更新' END,
    NULL
FROM public.student_baseline
WHERE student_name = '张三';             -- ← 替换


-- 3D. 查看排行榜是否已反映新分数
SELECT
    board      AS "榜单",
    rank_no    AS "名次",
    student_name,
    display_score AS "当前综合分",
    trend_score   AS "进步分 / 趋势"
FROM public.get_weekly_leaderboards()
WHERE student_name = '张三'              -- ← 替换
ORDER BY board;


-- 3E. （可选）测试完毕后清除测试数据
-- ⚠️ 谨慎：会删除刚才插入的 practice_logs 和对应 practice_sessions
-- DELETE FROM public.practice_logs
-- WHERE student_name = '张三'
--   AND created_at > NOW() - INTERVAL '10 minutes';
-- DELETE FROM public.practice_sessions
-- WHERE student_name = '张三'
--   AND session_start > NOW() - INTERVAL '10 minutes';
