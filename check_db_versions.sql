-- ============================================================
-- 数据库函数 & 触发器 — 版本核查 + 全量 Dump 脚本
-- 在 Supabase SQL Editor 中运行
--
-- 本文件分为两部分：
--   【第一部分】全量 Dump：列出数据库中所有 public schema 的函数与触发器
--   【第二部分】版本核查：对比数据库部署版本与本地最新版本的特征标记
--
-- 状态说明：
--   ✅ 最新     — 已部署，包含最新修复标记
--   ❌ 需重新部署 — 数据库中是旧版本，需执行对应 SQL 文件
--   ⚠️  函数不存在 — 数据库中找不到该函数
-- ============================================================


-- ════════════════════════════════════════════════════════════
-- 【第一部分】全量 Dump — 在 Supabase 运行后对照本地最新文件
-- ════════════════════════════════════════════════════════════

-- ① 列出 public schema 下所有函数（含签名 + 最后修改时间）
SELECT
    p.proname                                  AS "函数名",
    pg_get_function_identity_arguments(p.oid)  AS "参数签名",
    t.typname                                  AS "返回类型",
    CASE p.prosecdef WHEN true THEN 'SECURITY DEFINER' ELSE '' END AS "安全模式",
    -- 最后 DDL 时间（pg_stat_user_functions 无法直接给，用 pg_depend 近似）
    obj_description(p.oid, 'pg_proc')          AS "备注"
FROM pg_proc p
JOIN pg_type t ON t.oid = p.prorettype
WHERE p.pronamespace = 'public'::regnamespace
  AND p.prokind IN ('f', 'p')   -- 普通函数 + 过程
ORDER BY p.proname;


-- ② 列出数据库中所有触发器（所属表 + 触发函数 + 触发时机）
SELECT
    tg.tgname                          AS "触发器名",
    c.relname                          AS "所属表",
    CASE tg.tgtype & 2  WHEN 2 THEN 'BEFORE' ELSE 'AFTER'  END AS "时机",
    CASE tg.tgtype & 28
        WHEN 4  THEN 'INSERT'
        WHEN 8  THEN 'DELETE'
        WHEN 16 THEN 'UPDATE'
        WHEN 20 THEN 'INSERT,DELETE'
        WHEN 28 THEN 'INSERT,UPDATE,DELETE'
        ELSE 'OTHER'
    END                                AS "事件",
    p.proname                          AS "触发函数",
    CASE tg.tgenabled WHEN 'O' THEN '✅ 启用' ELSE '❌ 禁用' END AS "状态"
FROM pg_trigger tg
JOIN pg_class   c ON c.oid   = tg.tgrelid
JOIN pg_proc    p ON p.oid   = tg.tgfoid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND NOT tg.tgisinternal
ORDER BY c.relname, tg.tgname;


-- ③ 导出核心函数完整定义（用于对照本地文件）
-- 将下列 IN (...) 中的函数名按需增减
SELECT
    proname   AS "函数名",
    pg_get_functiondef(oid) AS "完整定义"
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
      'trigger_update_student_baseline',
      'update_student_baseline',
      'set_auto_reward_enabled',
      'get_auto_reward_setting'
  )
ORDER BY proname;


-- ════════════════════════════════════════════════════════════
-- 【第二部分】版本核查 — 对照本地最新文件逐函数检查特征标记
-- ════════════════════════════════════════════════════════════

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
          'trigger_update_student_baseline',
          'get_auto_reward_setting'
      )
    GROUP BY proname
),

checks AS (

    -- ① compute_student_score
    -- 最新版：fix44_46_score_functions.sql
    -- FIX-70 特征：RETURNS TABLE(composite_score NUMERIC, ...) + w_week := 0.70（FIX-57）
    SELECT
        'compute_student_score'              AS func_name,
        'fix44_46_score_functions.sql'       AS latest_file,
        'FIX-70（返回 NUMERIC）+ FIX-57（新生W=70%）' AS latest_fix,
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM func_defs WHERE func_name = 'compute_student_score')
                THEN '⚠️  函数不存在'
            WHEN (SELECT def FROM func_defs WHERE func_name = 'compute_student_score')
                 LIKE '%w_week  := 0.70%'
             AND (SELECT def FROM func_defs WHERE func_name = 'compute_student_score')
                 LIKE '%RETURNS TABLE(composite_score NUMERIC%'
                THEN '✅ 最新'
            ELSE '❌ 需重新部署'
        END AS status

    UNION ALL

    -- ② compute_student_score_as_of
    -- 最新版：fix44_46_score_functions.sql
    -- FIX-70 特征：返回 NUMERIC；FIX-57 特征：w_week := 0.70
    SELECT
        'compute_student_score_as_of',
        'fix44_46_score_functions.sql',
        'FIX-70（返回 NUMERIC）+ FIX-57（新生W=70%）',
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
    -- FIX-55 特征：NOT IN (0, 6) 出现 ≥6 次（全面过滤周末）
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
    -- FIX-53-H 特征：global_cap_returning（停练归来降级检测）
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
    -- FIX-62 特征：backfill 后先重刷基线（ROUND((raw_score * 100)::NUMERIC, 1)）
    SELECT
        'backfill_score_history',
        'fix53_backfill_update.sql',
        'FIX-62（backfill后重刷基线）+ FIX-70（NUMERIC精度）',
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM func_defs WHERE func_name = 'backfill_score_history')
                THEN '⚠️  函数不存在'
            WHEN (SELECT def FROM func_defs WHERE func_name = 'backfill_score_history')
                 LIKE '%raw_score * 100)::NUMERIC, 1%'
                THEN '✅ 最新'
            ELSE '❌ 需重新部署'
        END

    UNION ALL

    -- ⑥ trigger_insert_session
    -- 最新版：fix_stale_cleaned_duration.sql
    -- FIX-72 特征：AT TIME ZONE 'Asia/Shanghai')::TIME（正确时区转换）
    -- FIX-51B 特征：先 DELETE 同 (student, session_start) 再 INSERT
    SELECT
        'trigger_insert_session',
        'fix_stale_cleaned_duration.sql',
        'FIX-72（时区Bug修正）+ FIX-51B（防脏数据DELETE）',
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM func_defs WHERE func_name = 'trigger_insert_session')
                THEN '⚠️  函数不存在'
            WHEN (SELECT def FROM func_defs WHERE func_name = 'trigger_insert_session')
                 LIKE "%AT TIME ZONE 'Asia/Shanghai')::TIME%"
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
    -- FIX-69 特征：绝对涨分（display_score - lws.lw_composite）::NUMERIC, 1）
    -- FIX-65 特征：comp_top10（综合榜Top10退出专项榜）
    SELECT
        'get_weekly_leaderboards',
        'leaderboard_rpc.sql',
        'FIX-69（绝对涨分）+ FIX-65（Top10退专项榜）',
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM func_defs WHERE func_name = 'get_weekly_leaderboards')
                THEN '⚠️  函数不存在'
            WHEN (SELECT def FROM func_defs WHERE func_name = 'get_weekly_leaderboards')
                 LIKE '%comp_top10%'
             AND (SELECT def FROM func_defs WHERE func_name = 'get_weekly_leaderboards')
                 LIKE '%display_score - lws.lw_composite%'
                THEN '✅ 最新'
            ELSE '❌ 需重新部署'
        END

    UNION ALL

    -- ⑨ run_weekly_score_update
    -- 最新版：fix60_weekly_update_and_baseline_trigger.sql
    -- FIX-8 特征：raw_score IS NOT NULL 保护（防分数倒退）
    SELECT
        'run_weekly_score_update',
        'fix60_weekly_update_and_baseline_trigger.sql',
        'FIX-8（防分数倒退，raw_score IS NOT NULL 保护）',
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
    -- 最新版：fix60_weekly_update_and_baseline_trigger.sql
    -- FIX-71 特征：函数体只有 PERFORM public.update_student_baseline(NEW.student_name)
    --              不再有 v_live_count 等动态间隔变量
    SELECT
        'trigger_update_student_baseline',
        'fix60_weekly_update_and_baseline_trigger.sql',
        'FIX-71（每次练琴必触发，删除动态间隔逻辑）',
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM func_defs WHERE func_name = 'trigger_update_student_baseline')
                THEN '⚠️  函数不存在'
            -- FIX-71 后函数不含 v_live_count，旧版含有
            WHEN (SELECT def FROM func_defs WHERE func_name = 'trigger_update_student_baseline')
                 NOT LIKE '%v_live_count%'
             AND (SELECT def FROM func_defs WHERE func_name = 'trigger_update_student_baseline')
                 LIKE '%update_student_baseline(NEW.student_name)%'
                THEN '✅ 最新'
            ELSE '❌ 需重新部署'
        END

    UNION ALL

    -- ⑪ get_auto_reward_setting
    -- 最新版：fix_auto_reward_rls.sql
    -- FIX-68 特征：SECURITY DEFINER + auto_coin_reward_enabled
    SELECT
        'get_auto_reward_setting',
        'fix_auto_reward_rls.sql',
        'FIX-68（SECURITY DEFINER 绕过 RLS）',
        CASE
            WHEN NOT EXISTS (SELECT 1 FROM func_defs WHERE func_name = 'get_auto_reward_setting')
                THEN '⚠️  函数不存在'
            WHEN (SELECT def FROM func_defs WHERE func_name = 'get_auto_reward_setting')
                 LIKE '%auto_coin_reward_enabled%'
                THEN '✅ 最新'
            ELSE '❌ 需重新部署'
        END
)

SELECT
    func_name       AS "函数名",
    status          AS "状态",
    latest_fix      AS "最新版本特征 / Fix ID",
    latest_file     AS "本地对应文件（❌时需重新部署）"
FROM checks
ORDER BY
    CASE status
        WHEN '❌ 需重新部署' THEN 1
        WHEN '⚠️  函数不存在' THEN 2
        ELSE 3
    END,
    func_name;
