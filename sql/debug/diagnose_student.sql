-- ============================================================
-- 学生数据诊断脚本 — 替换下方姓名后执行
-- ============================================================
DO $$ BEGIN RAISE NOTICE '======= 开始诊断 ======='; END $$;

-- ① 直接看 student_baseline 当前状态
SELECT
    student_name,
    record_count,
    mean_duration,
    alpha,
    is_cold_start,
    last_updated,
    NOW() - last_updated AS stale_since
FROM public.student_baseline
WHERE student_name = '梁书一';

-- ② 统计 practice_sessions 里的真实情况
SELECT
    COUNT(*)                                              AS total_sessions,
    COUNT(*) FILTER (WHERE cleaned_duration > 0)          AS valid_cleaned,
    COUNT(*) FILTER (WHERE cleaned_duration = 0)          AS zero_cleaned,
    COUNT(*) FILTER (
        WHERE EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0,6)
    )                                                     AS weekday_sessions,
    COUNT(*) FILTER (
        WHERE EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0,6)
          AND cleaned_duration > 0
    )                                                     AS weekday_valid,   -- 这才是 record_count 应该等于的值
    COUNT(*) FILTER (
        WHERE EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') IN (0,6)
    )                                                     AS weekend_sessions,
    MIN(session_start AT TIME ZONE 'Asia/Shanghai')       AS first_session,
    MAX(session_start AT TIME ZONE 'Asia/Shanghai')       AS last_session
FROM public.practice_sessions
WHERE student_name = '梁书一';

-- ③ 列出所有记录详情（看每条的 DOW、cleaned_duration、is_outlier）
SELECT
    TO_CHAR(session_start AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI') AS session_bjt,
    TO_CHAR(session_start AT TIME ZONE 'Asia/Shanghai', 'Dy') AS weekday,
    EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai')::INT          AS dow,
    raw_duration,
    cleaned_duration,
    is_outlier,
    outlier_reason
FROM public.practice_sessions
WHERE student_name = '梁书一'
ORDER BY session_start DESC;

-- ④ 手动执行一次 compute_baseline，看更新后 record_count 是否变正常
-- （先不执行，只做诊断）
-- SELECT public.compute_baseline('梁书一');
-- SELECT record_count, last_updated FROM public.student_baseline WHERE student_name = '梁书一';
