-- 根据现有音符币流水重算 student_coins.semester_earned
--
-- 规则：
-- 1) auto_reward / compensation：按 amount 正向累加
-- 2) deduction：按 amount 负向冲减，但每一步最低不低于 0
-- 3) redemption：不影响 semester_earned
-- 4) legacy manual：
--    - amount > 0 视为补偿
--    - amount < 0 视为扣除
--    这是基于旧后台仅支持“增加 / 扣除”，尚未区分兑换的历史事实

WITH RECURSIVE ordered_tx AS (
    SELECT
        t.student_name,
        ROW_NUMBER() OVER (
            PARTITION BY t.student_name
            ORDER BY t.created_at ASC, t.id ASC
        ) AS rn,
        CASE
            WHEN t.transaction_type = 'redemption' THEN 0
            WHEN t.transaction_type IN ('auto_reward', 'compensation', 'deduction') THEN t.amount
            WHEN t.transaction_type = 'manual' THEN t.amount
            ELSE 0
        END AS semester_delta
    FROM public.coin_transactions t
),
replayed AS (
    SELECT
        o.student_name,
        o.rn,
        GREATEST(0, o.semester_delta) AS semester_earned
    FROM ordered_tx o
    WHERE o.rn = 1

    UNION ALL

    SELECT
        o.student_name,
        o.rn,
        GREATEST(0, r.semester_earned + o.semester_delta) AS semester_earned
    FROM replayed r
    JOIN ordered_tx o
      ON o.student_name = r.student_name
     AND o.rn = r.rn + 1
),
final_semester_earned AS (
    SELECT DISTINCT ON (r.student_name)
        r.student_name,
        r.semester_earned
    FROM replayed r
    ORDER BY r.student_name, r.rn DESC
),
target_values AS (
    SELECT
        sc.student_name,
        COALESCE(f.semester_earned, 0) AS new_semester_earned
    FROM public.student_coins sc
    LEFT JOIN (
        SELECT student_name, semester_earned
        FROM final_semester_earned
    ) f
      ON f.student_name = sc.student_name
)
UPDATE public.student_coins sc
SET semester_earned = t.new_semester_earned,
    updated_at = NOW()
FROM target_values t
WHERE sc.student_name = t.student_name
  AND sc.semester_earned IS DISTINCT FROM t.new_semester_earned;

-- 可选核对：
-- SELECT student_name, balance, semester_earned
-- FROM public.student_coins
-- ORDER BY semester_earned DESC, student_name ASC;
