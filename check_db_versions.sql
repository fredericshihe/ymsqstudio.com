-- ============================================================
-- 数据库函数版本核查脚本
-- 在 Supabase SQL Editor 中运行，检查每个函数是否已部署最新版本
-- 结果说明：
--   status = '✅ 最新' — 已部署，包含最新修复标记
--   status = '❌ 需重新部署' — 数据库中是旧版本，需执行对应 SQL 文件
--   status = '⚠️  函数不存在' — 数据库中找不到该函数
-- ============================================================

WITH func_defs AS (
    -- 同名函数可能有多个重载签名，聚合为一段文本再做字符串匹配
    SELECT proname AS func_name,
           string_agg(pg_get_functiondef(oid), E'\n') AS def
    FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace
      AND proname IN (
          'compute_student_score',
          'compute_student_score_as_of',
          'compute_baseline_as_of',
          'compute_baseline',
          'clean_duration',
          'backfill_score_history',
          'trigger_insert_session',
          'compute_and_store_w_score',
          'get_weekly_leaderboards',
          'run_weekly_score_update',
          'trigger_update_student_baseline'
      )
    GROUP BY proname
),

checks AS (
    -- ① compute_student_score
    -- 最新版：fix44_46_score_functions.sql
    -- FIX-57 特征：新生 W=70%（w_week  := 0.70）
    -- FIX-56 特征：资深学生 w_baseline := 0.22
    SELECT
        'compute_student_score'              AS func_name,
        'fix44_46_score_functions.sql'       AS latest_file,
        'FIX-57（新生W=70%，quality用贝叶斯均值）' AS latest_fix,
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM func_defs WHERE func_name = 'compute_student_score')
                THEN '⚠️  函数不存在'
            WHEN (SELECT def FROM func_defs WHERE func_name = 'compute_student_score')
                 LIKE '%w_week  := 0.70%'
                THEN '✅ 最新'
            ELSE '❌ 需重新部署'
        END AS status

    UNION ALL

    -- ② compute_student_score_as_of
    -- 最新版：fix44_46_score_functions.sql
    -- FIX-57 特征：w_week := 0.70（新生权重）
    SELECT
        'compute_student_score_as_of',
        'fix44_46_score_functions.sql',
        'FIX-57（新生W=70%，quality用贝叶斯均值）',
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM func_defs WHERE func_name = 'compute_student_score_as_of')
                THEN '⚠️  函数不存在'
            WHEN (SELECT def FROM func_defs WHERE func_name = 'compute_student_score_as_of')
                 LIKE '%w_week  := 0.70%'
                THEN '✅ 最新'
            ELSE '❌ 需重新部署'
        END

    UNION ALL

    -- ③ compute_baseline_as_of
    -- 最新版：fix55_baseline_weekday_filter.sql
    -- FIX-55 特征：DOW 过滤（NOT IN (0, 6)）出现 6 次以上
    SELECT
        'compute_baseline_as_of',
        'fix55_baseline_weekday_filter.sql',
        'FIX-55（全面过滤周末数据）',
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM func_defs WHERE func_name = 'compute_baseline_as_of')
                THEN '⚠️  函数不存在'
            WHEN (
                SELECT LENGTH(def) - LENGTH(REPLACE(def, 'NOT IN (0, 6)', ''))
                FROM func_defs WHERE func_name = 'compute_baseline_as_of'
            ) / LENGTH('NOT IN (0, 6)') >= 6
                THEN '✅ 最新'
            ELSE '❌ 需重新部署'
        END

    UNION ALL

    -- ④ clean_duration
    -- 最新版：fix53_clean_duration.sql
    -- FIX-53-H 特征：global_cap_returning（停练归来标记）
    SELECT
        'clean_duration',
        'fix53_clean_duration.sql',
        'FIX-53-H（停练归来降级检测）',
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM func_defs WHERE func_name = 'clean_duration')
                THEN '⚠️  函数不存在'
            WHEN (SELECT def FROM func_defs WHERE func_name = 'clean_duration')
                 LIKE '%global_cap_returning%'
                THEN '✅ 最新'
            ELSE '❌ 需重新部署'
        END

    UNION ALL

    -- ⑤ backfill_score_history
    -- 最新版：fix53_backfill_update.sql
    -- FIX-53-F 特征：backfill 结束后自动调用 compute_and_store_w_score
    SELECT
        'backfill_score_history',
        'fix53_backfill_update.sql',
        'FIX-53-F（backfill后自动刷新W分）',
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM func_defs WHERE func_name = 'backfill_score_history')
                THEN '⚠️  函数不存在'
            WHEN (SELECT def FROM func_defs WHERE func_name = 'backfill_score_history')
                 LIKE '%compute_and_store_w_score%'
                THEN '✅ 最新'
            ELSE '❌ 需重新部署'
        END

    UNION ALL

    -- ⑥ trigger_insert_session
    -- 最新版：fix_stale_cleaned_duration.sql (FIX-51)
    -- FIX-51 特征：先 DELETE 重复记录再 RETURN NEW
    SELECT
        'trigger_insert_session',
        'fix_stale_cleaned_duration.sql',
        'FIX-51（防脏数据：先DELETE再INSERT）',
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM func_defs WHERE func_name = 'trigger_insert_session')
                THEN '⚠️  函数不存在'
            WHEN (SELECT def FROM func_defs WHERE func_name = 'trigger_insert_session')
                 LIKE '%DELETE%session_start%'
                THEN '✅ 最新'
            ELSE '❌ 需重新部署'
        END

    UNION ALL

    -- ⑦ compute_and_store_w_score
    -- 最新版：fix54_w_score_sunday.sql
    -- FIX-54 特征：周日(DOW=0)映射为5个工作日（WHEN 0 THEN 5）
    SELECT
        'compute_and_store_w_score',
        'fix54_w_score_sunday.sql',
        'FIX-54（周日DOW=0修复）',
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM func_defs WHERE func_name = 'compute_and_store_w_score')
                THEN '⚠️  函数不存在'
            WHEN (SELECT def FROM func_defs WHERE func_name = 'compute_and_store_w_score')
                 LIKE '%WHEN 0 THEN 5%'
                THEN '✅ 最新'
            ELSE '❌ 需重新部署'
        END

    UNION ALL

    -- ⑧ get_weekly_leaderboards
    -- 最新版：leaderboard_rpc.sql
    -- FIX-65 特征：comp_top10（综合榜Top10退出专项榜）
    -- FIX-58 特征：绝对涨分排序等
    SELECT
        'get_weekly_leaderboards',
        'leaderboard_rpc.sql',
        'FIX-65（Top10退专项榜）+ FIX-58（绝对涨分排序）',
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM func_defs WHERE func_name = 'get_weekly_leaderboards')
                THEN '⚠️  函数不存在'
            WHEN (SELECT def FROM func_defs WHERE func_name = 'get_weekly_leaderboards')
                 LIKE '%comp_top10%'
                THEN '✅ 最新'
            ELSE '❌ 需重新部署'
        END

    UNION ALL

    -- ⑨ run_weekly_score_update
    -- 最新版：baseline_fixes_v1.sql（FIX-8 修复分数倒退）
    -- FIX-8 特征：第④步归一化 student_baseline.composite_score（raw_score NOT NULL 保护）
    SELECT
        'run_weekly_score_update',
        'baseline_fixes_v1.sql',
        'FIX-8（防分数倒退）',
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM func_defs WHERE func_name = 'run_weekly_score_update')
                THEN '⚠️  函数不存在'
            WHEN (SELECT def FROM func_defs WHERE func_name = 'run_weekly_score_update')
                 LIKE '%raw_score IS NOT NULL%'
                THEN '✅ 最新'
            ELSE '❌ 需重新部署'
        END

    UNION ALL

    -- ⑩ trigger_update_student_baseline
    -- 最新版：baseline_fixes_v1.sql（FIX-9 修复触发器计数基准）
    -- FIX-9 特征：v_live_count（实时有效记录数变量）
    SELECT
        'trigger_update_student_baseline',
        'baseline_fixes_v1.sql',
        'FIX-9（实时记录数计数）',
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM func_defs WHERE func_name = 'trigger_update_student_baseline')
                THEN '⚠️  函数不存在'
            WHEN (SELECT def FROM func_defs WHERE func_name = 'trigger_update_student_baseline')
                 LIKE '%v_live_count%'
                THEN '✅ 最新'
            ELSE '❌ 需重新部署'
        END
)

SELECT
    func_name       AS "函数名",
    status          AS "状态",
    latest_fix      AS "最新版本特征",
    latest_file     AS "需执行的文件（如需重新部署）"
FROM checks
ORDER BY
    CASE status
        WHEN '❌ 需重新部署' THEN 1
        WHEN '⚠️  函数不存在' THEN 2
        ELSE 3
    END,
    func_name;
