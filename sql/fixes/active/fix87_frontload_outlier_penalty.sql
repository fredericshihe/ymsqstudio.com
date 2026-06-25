-- ============================================================================
-- FIX-87: 异常率惩罚前移并显著加重 20%+ 区间
--
-- 目标：
-- 1) 0%~10% 保持轻惩罚，容忍偶发异常
-- 2) 10%~20% 开始明显拉开差距
-- 3) 20%~30% 进入强惩罚区，避免异常率不低仍长期霸榜
-- 4) 只改当前评分函数，不改历史发币表与历史榜单快照
-- ============================================================================

DO $$
DECLARE
  fn_name TEXT;
  fn_oid OID;
  fn_def TEXT;
  patched TEXT;
  p_start INT;
  p_end INT;
  start_anchor TEXT := '  v_outlier_penalty := CASE';
  end_anchor   TEXT := '  END;';
  new_block TEXT := $b$
  v_outlier_penalty := CASE
    -- 0%~10%：轻惩罚，允许少量偶发异常
    WHEN COALESCE(r.outlier_rate, 0.0) <= 0.10
      THEN 1.0 - 0.4 * COALESCE(r.outlier_rate, 0.0)

    -- 10%~20%：开始明显压分
    WHEN COALESCE(r.outlier_rate, 0.0) <= 0.20
      THEN 0.96 - 1.1 * (COALESCE(r.outlier_rate, 0.0) - 0.10)

    -- 20%~30%：进入强惩罚区，前排竞争会明显吃亏
    WHEN COALESCE(r.outlier_rate, 0.0) <= 0.30
      THEN 0.85 - 1.8 * (COALESCE(r.outlier_rate, 0.0) - 0.20)

    -- 30%~60%：继续快速下压
    WHEN COALESCE(r.outlier_rate, 0.0) <= 0.60
      THEN 0.67 - 1.4 * (COALESCE(r.outlier_rate, 0.0) - 0.30)

    -- >60%：指数衰减
    ELSE 0.25 * EXP(-3.0 * (COALESCE(r.outlier_rate, 0.0) - 0.60))
  END;
$b$;
BEGIN
  FOREACH fn_name IN ARRAY ARRAY[
    'public.compute_student_score_rule_v2_core(text,date)'
  ]
  LOOP
    fn_oid := to_regprocedure(fn_name);
    IF fn_oid IS NULL THEN
      RAISE EXCEPTION 'Function not found: %', fn_name;
    END IF;

    SELECT pg_get_functiondef(fn_oid) INTO fn_def;
    IF fn_def IS NULL OR fn_def = '' THEN
      RAISE EXCEPTION 'Cannot read function definition: %', fn_name;
    END IF;

    p_start := strpos(fn_def, start_anchor);
    IF p_start = 0 THEN
      RAISE EXCEPTION 'Start anchor not found in %', fn_name;
    END IF;

    p_end := strpos(substr(fn_def, p_start), end_anchor);
    IF p_end = 0 THEN
      RAISE EXCEPTION 'End anchor not found in %', fn_name;
    END IF;
    p_end := p_start + p_end + length(end_anchor) - 2;

    patched :=
      substr(fn_def, 1, p_start - 1)
      || new_block
      || substr(fn_def, p_end + 1);

    EXECUTE patched;
    RAISE NOTICE 'Patched %', fn_name;
  END LOOP;
END
$$;

-- 立即刷新当前周实时分，确保综合榜立刻反映新惩罚
SELECT public.refresh_all_w_scores();
