-- ============================================================
-- 一键验证：学期管理精简是否生效
-- 目标：
-- 1) 梅纽因之星对象已移除（award_meiyin_star / meiyin_star_log）
-- 2) 学期重置函数仍可用（start_new_semester）
-- 3) 学期累计排行视图仍可用（vw_student_coin_balances 含 semester_earned）
-- 4) adjust_student_coins 仍包含正向金额累加 semester_earned 逻辑
-- ============================================================

WITH checks AS (
  SELECT
    'object_removed::award_meiyin_star'::text AS check_item,
    CASE
      WHEN to_regprocedure('public.award_meiyin_star(text,text,text)') IS NULL THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    COALESCE(to_regprocedure('public.award_meiyin_star(text,text,text)')::text, 'NULL') AS detail

  UNION ALL

  SELECT
    'object_removed::meiyin_star_log' AS check_item,
    CASE
      WHEN to_regclass('public.meiyin_star_log') IS NULL THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    COALESCE(to_regclass('public.meiyin_star_log')::text, 'NULL') AS detail

  UNION ALL

  SELECT
    'function_exists::start_new_semester' AS check_item,
    CASE
      WHEN to_regprocedure('public.start_new_semester(text)') IS NOT NULL THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    COALESCE(to_regprocedure('public.start_new_semester(text)')::text, 'NULL') AS detail

  UNION ALL

  SELECT
    'view_exists::vw_student_coin_balances' AS check_item,
    CASE
      WHEN to_regclass('public.vw_student_coin_balances') IS NOT NULL THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    COALESCE(to_regclass('public.vw_student_coin_balances')::text, 'NULL') AS detail

  UNION ALL

  SELECT
    'view_column::semester_earned' AS check_item,
    CASE
      WHEN EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'vw_student_coin_balances'
          AND column_name = 'semester_earned'
      ) THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    'public.vw_student_coin_balances.semester_earned' AS detail

  UNION ALL

  SELECT
    'function_logic::adjust_student_coins_has_semester_accumulate' AS check_item,
    CASE
      WHEN EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'adjust_student_coins'
          AND pg_get_functiondef(p.oid) ILIKE '%semester_earned%'
          AND pg_get_functiondef(p.oid) ILIKE '%WHEN p_amount > 0%'
      ) THEN 'PASS'
      ELSE 'FAIL'
    END AS status,
    'expect semester_earned += p_amount when p_amount > 0' AS detail

  UNION ALL

  SELECT
    'permission::start_new_semester_executable' AS check_item,
    CASE
      WHEN has_function_privilege(
        current_user,
        'public.start_new_semester(text)',
        'EXECUTE'
      ) THEN 'PASS'
      ELSE 'WARN'
    END AS status,
    'current_user=' || current_user AS detail
),
summary AS (
  SELECT
    COUNT(*) AS total_checks,
    COUNT(*) FILTER (WHERE status = 'PASS') AS pass_count,
    COUNT(*) FILTER (WHERE status = 'FAIL') AS fail_count,
    COUNT(*) FILTER (WHERE status = 'WARN') AS warn_count
  FROM checks
)
SELECT *
FROM checks
ORDER BY check_item;

WITH checks AS (
  SELECT
    'object_removed::award_meiyin_star'::text AS check_item,
    CASE
      WHEN to_regprocedure('public.award_meiyin_star(text,text,text)') IS NULL THEN 'PASS'
      ELSE 'FAIL'
    END AS status

  UNION ALL

  SELECT
    'object_removed::meiyin_star_log' AS check_item,
    CASE
      WHEN to_regclass('public.meiyin_star_log') IS NULL THEN 'PASS'
      ELSE 'FAIL'
    END AS status

  UNION ALL

  SELECT
    'function_exists::start_new_semester' AS check_item,
    CASE
      WHEN to_regprocedure('public.start_new_semester(text)') IS NOT NULL THEN 'PASS'
      ELSE 'FAIL'
    END AS status

  UNION ALL

  SELECT
    'view_exists::vw_student_coin_balances' AS check_item,
    CASE
      WHEN to_regclass('public.vw_student_coin_balances') IS NOT NULL THEN 'PASS'
      ELSE 'FAIL'
    END AS status

  UNION ALL

  SELECT
    'view_column::semester_earned' AS check_item,
    CASE
      WHEN EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'vw_student_coin_balances'
          AND column_name = 'semester_earned'
      ) THEN 'PASS'
      ELSE 'FAIL'
    END AS status

  UNION ALL

  SELECT
    'function_logic::adjust_student_coins_has_semester_accumulate' AS check_item,
    CASE
      WHEN EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'adjust_student_coins'
          AND pg_get_functiondef(p.oid) ILIKE '%semester_earned%'
          AND pg_get_functiondef(p.oid) ILIKE '%WHEN p_amount > 0%'
      ) THEN 'PASS'
      ELSE 'FAIL'
    END AS status

  UNION ALL

  SELECT
    'permission::start_new_semester_executable' AS check_item,
    CASE
      WHEN has_function_privilege(
        current_user,
        'public.start_new_semester(text)',
        'EXECUTE'
      ) THEN 'PASS'
      ELSE 'WARN'
    END AS status
),
summary AS (
  SELECT
    COUNT(*) AS total_checks,
    COUNT(*) FILTER (WHERE status = 'PASS') AS pass_count,
    COUNT(*) FILTER (WHERE status = 'FAIL') AS fail_count,
    COUNT(*) FILTER (WHERE status = 'WARN') AS warn_count
  FROM checks
)
SELECT
  total_checks,
  pass_count,
  fail_count,
  warn_count,
  ROUND(pass_count::numeric * 100 / NULLIF(total_checks, 0), 1) AS pass_rate_pct,
  CASE
    WHEN fail_count = 0 THEN '✅ 学期管理精简验证通过'
    ELSE '❌ 存在失败项，请按 check_item 排查'
  END AS verdict
FROM summary;

