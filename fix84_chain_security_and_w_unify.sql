-- ============================================================================
-- FIX-84: 链路安全与 W 口径统一补丁
--
-- 包含三项修复：
-- 1) 权限收口：收回 anon/authenticated 对发币与开关函数执行权
-- 2) W 统一入口：compute_student_score 内部改为使用 get_personalized_w_daily_ref
-- 3) 运维防回退：建议后续仅用 fix83/fix84 做增量，不直接整包执行旧脚本
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 1) 权限收口：仅 service_role 可执行
-- --------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.set_auto_reward_enabled(BOOLEAN) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.reward_weekly_coins() FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.set_auto_reward_enabled(BOOLEAN) TO service_role;
GRANT  EXECUTE ON FUNCTION public.reward_weekly_coins() TO service_role;

COMMIT;

-- --------------------------------------------------------------------------
-- 2) 动态补丁 compute_student_score：W 改用 FIX-81 个性化日均基准
-- --------------------------------------------------------------------------
DO $$
DECLARE
  fn_oid OID;
  fn_def TEXT;
  patched TEXT;

  p_decl INT;
  p_w_start INT;
  p_w_end INT;

  decl_anchor TEXT := '  v_weekly_ratio       FLOAT8;';
  w_start_anchor TEXT := '  -- 11. W 维度';
  w_end_anchor TEXT := '  -- 12. 动态权重';

  decl_inject TEXT := E'  v_weekly_ratio       FLOAT8;\n  v_w_daily_ref        FLOAT8;';

  w_block TEXT := $w$
  -- 11. W 维度（与 FIX-81 统一口径）
  --     本周工作日实际时长 / (个性化 w_daily_ref × 已过工作日天数)
  -- ══════════════════════════════════════════════════════════════
  SELECT COALESCE(SUM(cleaned_duration), 0) INTO v_weekly_minutes
  FROM public.practice_sessions
  WHERE student_name    = p_student_name
    AND session_start   >= v_week_start_bjt
    AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

  v_dow          := EXTRACT(DOW FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INT;
  v_elapsed_days := CASE v_dow WHEN 0 THEN 5 WHEN 6 THEN 5 ELSE v_dow END;

  SELECT w_daily_ref
  INTO v_w_daily_ref
  FROM public.get_personalized_w_daily_ref(p_student_name);

  IF v_w_daily_ref IS NULL OR v_w_daily_ref <= 0 THEN
    v_w_daily_ref := GREATEST(v_effective_mean, 30.0);
  END IF;

  IF v_elapsed_days > 0 AND v_w_daily_ref > 0 THEN
    v_weekly_ratio := v_weekly_minutes::FLOAT8
                    / NULLIF(v_w_daily_ref * v_elapsed_days, 0.0);
    v_w_score := GREATEST(0.0, LEAST(1.0,
      1.0 / (1.0 + EXP(-3.0 * (COALESCE(v_weekly_ratio, 0.0) - 0.5)))));
  END IF;

$w$;
BEGIN
  fn_oid := to_regprocedure('public.compute_student_score(text)');
  IF fn_oid IS NULL THEN
    RAISE EXCEPTION 'Function not found: public.compute_student_score(text)';
  END IF;

  SELECT pg_get_functiondef(fn_oid) INTO fn_def;
  IF fn_def IS NULL OR fn_def = '' THEN
    RAISE EXCEPTION 'Cannot read function definition: public.compute_student_score(text)';
  END IF;

  -- 2.1 注入变量声明（如果尚未存在）
  IF strpos(fn_def, 'v_w_daily_ref') = 0 THEN
    p_decl := strpos(fn_def, decl_anchor);
    IF p_decl = 0 THEN
      RAISE EXCEPTION 'Declaration anchor not found in compute_student_score';
    END IF;
    fn_def :=
      substr(fn_def, 1, p_decl - 1)
      || decl_inject
      || substr(fn_def, p_decl + length(decl_anchor));
  END IF;

  -- 2.2 替换 W 维度块
  p_w_start := strpos(fn_def, w_start_anchor);
  p_w_end   := strpos(fn_def, w_end_anchor);
  IF p_w_start = 0 OR p_w_end = 0 OR p_w_end <= p_w_start THEN
    RAISE EXCEPTION 'W block anchors not found in compute_student_score';
  END IF;

  patched :=
    substr(fn_def, 1, p_w_start - 1)
    || w_block
    || substr(fn_def, p_w_end);

  EXECUTE patched;
  RAISE NOTICE 'Patched compute_student_score W block successfully.';
END
$$;

-- --------------------------------------------------------------------------
-- 3) 可选：上线后全量重算（手动执行）
-- --------------------------------------------------------------------------
-- SELECT public.compute_student_score(student_name) FROM public.student_baseline;

