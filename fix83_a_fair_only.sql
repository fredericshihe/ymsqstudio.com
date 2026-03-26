-- ============================================================================
-- FIX-83: A 维度公平性补丁（只改 A，不碰 W）
--
-- 目的：
-- 1) 避免“低均时但持续认真练习”学生的 A 分被硬清零
-- 2) 仅替换 quality_score 计算段，保留当前线上函数其余全部逻辑
--    （尤其保留你已部署的 W 相关优化）
--
-- 作用对象：
-- - public.compute_student_score(text)
-- - public.compute_student_score_as_of(text, date)
--
-- 使用方式：
-- 1) 直接执行本 SQL（会动态读取当前数据库函数定义并打补丁）
-- 2) 然后执行全量重算：
--    SELECT public.compute_student_score(student_name) FROM public.student_baseline;
-- ============================================================================

DO $$
DECLARE
  fn_name TEXT;
  fn_oid OID;
  fn_def TEXT;
  patched TEXT;
  start_anchor TEXT := 'quality_score :=';
  end_anchor   TEXT := 'a_score := LEAST(1.0,';
  p_start INT;
  p_end   INT;
  replacement TEXT := $r$
quality_score := GREATEST(
    GREATEST(0.0, LEAST(1.0,
      0.5 + (v_effective_mean - COALESCE(median_mean, 0.0))
          / (2.0 * pop_iqr)
    )),
    LEAST(0.35,
      0.22
      * LEAST(1.0, LN(GREATEST(COALESCE(r.record_count, 0), 0)::FLOAT8 + 1.0) / LN(31.0))
      * GREATEST(
          0.35,
          1.0
          - 0.60 * COALESCE(r.outlier_rate, 0.0)
          - 0.40 * COALESCE(r.short_session_rate, 0.0)
        )
    )
  );
$r$;
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
    p_end   := strpos(fn_def, end_anchor);

    IF p_start = 0 OR p_end = 0 OR p_end <= p_start THEN
      RAISE EXCEPTION
        'Patch anchors not found in %. Stop for safety (function body may differ).',
        fn_name;
    END IF;

    patched :=
      substr(fn_def, 1, p_start - 1)
      || replacement
      || substr(fn_def, p_end);

    IF patched = fn_def THEN
      RAISE EXCEPTION 'No changes applied for %', fn_name;
    END IF;

    EXECUTE patched;
    RAISE NOTICE 'Patched % successfully.', fn_name;
  END LOOP;
END
$$;


-- 可选验收1：梁书一 A 分是否脱离 0
-- SELECT student_name, accum_score, record_count, mean_duration, outlier_rate, short_session_rate
-- FROM public.student_baseline
-- WHERE student_name = '梁书一';

-- 可选验收2：全校 A=0 人数是否下降（且不是异常刷短时导致）
-- SELECT
--   COUNT(*) FILTER (WHERE accum_score = 0) AS a_zero_cnt,
--   COUNT(*) FILTER (WHERE accum_score > 0 AND accum_score < 0.15) AS a_low_cnt
-- FROM public.student_baseline;
