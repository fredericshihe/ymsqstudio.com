-- ============================================================
-- 迁移：composite_score 从 INT 改为 NUMERIC(6,1)
-- 目的：保留小数点后一位，使排行榜分数更有区分度（如 62.3 vs 62.0）
-- 影响表：student_score_history、student_baseline
-- 注意：现有整数数据（如 62）自动转为 62.0，无精度损失
-- ============================================================

-- 1. 历史快照表
ALTER TABLE public.student_score_history
    ALTER COLUMN composite_score TYPE NUMERIC(6,1)
    USING ROUND(composite_score::NUMERIC, 1);

-- 2. 基线表
ALTER TABLE public.student_baseline
    ALTER COLUMN composite_score TYPE NUMERIC(6,1)
    USING ROUND(composite_score::NUMERIC, 1);

-- 3. 同步更新 compute_student_score 和 compute_student_score_as_of 函数
--    （需要先 DROP 再 CREATE，因为返回类型从 INT 改为 NUMERIC）
--    → 请在本 SQL 执行完成后，重新部署 fix44_46_score_functions.sql

-- 4. 验证（运行后应看到 NUMERIC 类型）
SELECT
    column_name,
    data_type,
    numeric_precision,
    numeric_scale
FROM information_schema.columns
WHERE table_name IN ('student_score_history', 'student_baseline')
  AND column_name = 'composite_score'
ORDER BY table_name;
