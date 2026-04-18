-- ============================================================================
-- FIX-85: 异常率惩罚前移到 25% 即明显
--
-- 目标：
-- 1) 25% 异常率开始出现明显惩罚（约 0.85 系数）
-- 2) 25%~60% 区间惩罚更陡，避免“异常率不低仍高排名”
-- 3) 同步实时函数 + 历史回填函数口径
-- ============================================================================

DO $$
DECLARE
  fn_name TEXT;
  fn_oid OID;
  fn_def TEXT;
  patched TEXT;
  p_start INT;
  p_end INT;
  start_anchor TEXT := '  outlier_penalty := CASE';
  end_anchor   TEXT := '  END;';
  new_block TEXT := $b$
  outlier_penalty := CASE
    -- 0%~25%：线性惩罚，25% 时系数降到 0.85（明显）
    WHEN COALESCE(r.outlier_rate, 0.0) <= 0.25
      THEN 1.0 - 0.6 * COALESCE(r.outlier_rate, 0.0)

    -- 25%~60%：加速惩罚，60% 时约降到 0.50
    WHEN COALESCE(r.outlier_rate, 0.0) <= 0.60
      THEN 0.85 - 1.0 * (COALESCE(r.outlier_rate, 0.0) - 0.25)

    -- >60%：指数衰减，继续快速下压
    ELSE 0.50 * EXP(-3.0 * (COALESCE(r.outlier_rate, 0.0) - 0.60))
  END;
$b$;
BEGIN
  FOREACH fn_name IN ARRAY ARRAY[
    'public.compute_student_score(text)',
    'public.compute_student_score_as_of(text,date)'
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

-- 建议执行后全量重算
-- SELECT public.compute_student_score(student_name)
-- FROM public.student_baseline;

