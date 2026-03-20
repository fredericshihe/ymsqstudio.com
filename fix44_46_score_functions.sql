-- ============================================================
-- FIX-44：B/T 维度引入绝对水平分量（65% 变化 + 35% 绝对水平）
-- FIX-45：跳过（数据证明同专业 50% 下限对本校学生群体无影响）
-- FIX-46：B/T 假期间隔中性化（跨越 3/4 周的对比向 0.5 拉近）
--
-- 目标：
--   1. 稳定高量学生（本校日均≈全校中位数，因此 level 分量有限但仍有提升）
--   2. 全局 B 中位数从 0.351 提升到约 0.41（受益 71/146 人，49%）
--   3. 寒假等长假返校后 B/T 不再被压至 0.002，而是向 0.5 中性值靠拢
--
-- 受影响函数：
--   public.compute_student_score(p_student_name TEXT)
--   public.compute_student_score_as_of(p_student_name TEXT, p_snapshot_date DATE)
--
-- 部署后执行：
--   SELECT public.backfill_score_history();
--   SELECT public.compute_student_score(student_name)
--     FROM public.student_baseline
--     WHERE composite_score > 0 OR last_updated IS NOT NULL;
--   SELECT public.compute_and_store_w_score(student_name)
--     FROM public.student_baseline;
-- ============================================================


-- ============================================================
-- 函数一：compute_student_score  (实时触发版)
-- ============================================================
CREATE OR REPLACE FUNCTION public.compute_student_score(p_student_name TEXT)
RETURNS TABLE(composite_score NUMERIC, raw_score FLOAT8)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  -- ── A 维度同专业统计
  median_mean          FLOAT8;
  p25_mean             FLOAT8;
  p75_mean             FLOAT8;
  pop_iqr              FLOAT8;
  quality_score        FLOAT8;

  -- ── 学生基线记录
  r                    RECORD;

  -- ── FIX-37: 贝叶斯收缩
  v_major              TEXT;
  v_major_count        INT;
  v_shrink_alpha       FLOAT8;
  v_effective_mean     FLOAT8;

  -- ── 历史深度
  hist_count           INTEGER := 0;

  -- ── 五维分数
  b_score              FLOAT8  := 0.5;
  t_score              FLOAT8  := 0.5;
  m_score              FLOAT8  := 0.5;
  a_score              FLOAT8  := 0.0;
  v_w_score            FLOAT8  := 0.5;  -- 局部变量改名避免与列名歧义（FIX-53）

  -- ── FIX-44: 同专业周中位数（B/T level 分量参照）
  v_peer_median_weekly FLOAT8;

  -- ── B 维度 (FIX-34-A)
  v_week1_mins         FLOAT8;
  v_week2_mins         FLOAT8;
  v_week1_start        DATE;
  v_week2_start        DATE;
  b_change             FLOAT8  := 0.5;
  b_level              FLOAT8  := 0.5;
  b_gap_weeks          FLOAT8;
  b_neutralize         FLOAT8;

  -- ── T 维度 (FIX-43 块对比)
  v_recent_avg         FLOAT8;
  v_older_avg          FLOAT8;
  n_t_weeks            INTEGER;
  v_t_recent_start     DATE;     -- FIX-46: 近块最早周一
  v_t_older_end        DATE;     -- FIX-46: 远块最晚周一
  t_change             FLOAT8  := 0.5;
  t_level              FLOAT8  := 0.5;
  t_gap_weeks          FLOAT8;
  t_neutralize         FLOAT8;

  -- ── M 维度 (FIX-34-B + FIX-42: 阈值60%)
  m_rec                RECORD;
  m_weight             FLOAT8;
  m_total_weight       FLOAT8  := 0.0;
  m_weighted_sum       FLOAT8  := 0.0;
  m_wk_num             INTEGER := 0;
  m_weeks_met          INTEGER := 0;

  -- ── 异常率惩罚 (FIX-40)
  outlier_penalty      FLOAT8;

  -- ── 高峰衰退 (FIX-31)
  v_peak_weekly_avg    FLOAT8  := 0;
  v_recent_4w_avg      FLOAT8  := 0;
  v_peak_decay         FLOAT8  := 1.0;

  -- ── 动态权重 (FIX-20)
  w_baseline           FLOAT8;
  w_trend              FLOAT8;
  w_momentum           FLOAT8;
  w_accum              FLOAT8;
  w_week               FLOAT8;

  -- ── 合成
  composite_raw        FLOAT8;
  v_composite_score    NUMERIC;
  v_raw_score          FLOAT8;

  -- ── 置信度
  score_conf           FLOAT8  := 0.5;

  -- ── 成长加速度
  v_growth_velocity    FLOAT8  := 0.0;
  vel_rec              RECORD;
  v_vel_cnt4           INT     := 0;
  v_vel_sum4           FLOAT8  := 0.0;
  v_vel_cnt8           INT     := 0;
  v_vel_sum8           FLOAT8  := 0.0;

  -- ── 时间基准 (FIX-27)
  v_week_monday        DATE;
  v_week_start_bjt     TIMESTAMPTZ;
  v_has_session        BOOLEAN;

  -- ── W 维度
  v_weekly_minutes     FLOAT8;
  v_elapsed_days       INT;
  v_weekly_ratio       FLOAT8;
  v_dow                INT;

  -- ── 停琴判断
  v_last_bjt           TIMESTAMPTZ;
  v_days_inactive      INT     := 0;

BEGIN
  -- ══════════════════════════════════════════════════════════════
  -- 1. 时间基准 (FIX-27: 北京时间周一 00:00 TIMESTAMPTZ)
  -- ══════════════════════════════════════════════════════════════
  v_week_monday    := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
  v_week_start_bjt := (v_week_monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';

  -- ══════════════════════════════════════════════════════════════
  -- 2. 读取学生基线
  -- ══════════════════════════════════════════════════════════════
  SELECT * INTO r FROM public.student_baseline WHERE student_name = p_student_name;
  IF NOT FOUND THEN RETURN; END IF;
  v_major := r.student_major;

  -- ══════════════════════════════════════════════════════════════
  -- 3. 停琴冻结检查 (FIX-12/19: 只看工作日)
  -- ══════════════════════════════════════════════════════════════
  SELECT MAX(session_start) INTO v_last_bjt
  FROM public.practice_sessions
  WHERE student_name = p_student_name
    AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

  v_days_inactive := EXTRACT(DAYS FROM
    (NOW() - COALESCE(v_last_bjt, NOW() - INTERVAL '999 days')))::INT;

  IF v_days_inactive > 30 THEN
    -- FIX-53: 保留停练学生最后一次有效分数（原为写0，与FIX-12"冻结保留"设计相悖）
    INSERT INTO public.student_score_history (
      student_name, snapshot_date, composite_score, raw_score,
      baseline_score, trend_score, momentum_score, accum_score,
      outlier_rate, short_session_rate, mean_duration, record_count
    ) VALUES (
      p_student_name, v_week_monday,
      COALESCE(r.composite_score, 0), COALESCE(r.raw_score, 0.0),
      NULL, NULL, NULL, NULL,
      r.outlier_rate, r.short_session_rate, r.mean_duration, r.record_count
    ) ON CONFLICT DO NOTHING;
    RETURN QUERY SELECT COALESCE(r.composite_score, 0), COALESCE(r.raw_score, 0.0)::FLOAT8;
    RETURN;
  END IF;

  -- ══════════════════════════════════════════════════════════════
  -- 4. 本周有无工作日练琴 (FIX-15/19)
  -- ══════════════════════════════════════════════════════════════
  SELECT EXISTS (
    SELECT 1 FROM public.practice_sessions
    WHERE student_name    = p_student_name
      AND cleaned_duration > 0
      AND session_start   >= v_week_start_bjt
      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  ) INTO v_has_session;

  IF NOT v_has_session THEN
    INSERT INTO public.student_score_history (
      student_name, snapshot_date, composite_score, raw_score,
      baseline_score, trend_score, momentum_score, accum_score,
      outlier_rate, short_session_rate, mean_duration, record_count
    ) VALUES (
      p_student_name, v_week_monday, 0, 0.0,
      NULL, NULL, NULL, NULL,
      r.outlier_rate, r.short_session_rate, r.mean_duration, r.record_count
    ) ON CONFLICT DO NOTHING;
    RETURN QUERY SELECT 0, 0.0::FLOAT8;
    RETURN;
  END IF;

  -- ══════════════════════════════════════════════════════════════
  -- 5. 历史深度（有练琴的活跃周数，用于权重决策）
  -- ══════════════════════════════════════════════════════════════
  SELECT COUNT(*) INTO hist_count
  FROM public.student_score_history sh
  WHERE sh.student_name    = p_student_name
    AND sh.composite_score > 0
    AND sh.snapshot_date   < v_week_monday;

  -- ══════════════════════════════════════════════════════════════
  -- 6. 同专业统计 + 贝叶斯收缩 (FIX-37)
  -- ══════════════════════════════════════════════════════════════
  SELECT COUNT(*) INTO v_major_count
  FROM public.student_baseline
  WHERE student_major = v_major AND mean_duration > 0;

  IF v_major_count >= 5 THEN
    SELECT
      PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY mean_duration),
      PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY mean_duration),
      PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY mean_duration)
    INTO median_mean, p25_mean, p75_mean
    FROM public.student_baseline
    WHERE mean_duration IS NOT NULL AND mean_duration > 0
      AND student_major = v_major;
  ELSE
    SELECT
      PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY mean_duration),
      PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY mean_duration),
      PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY mean_duration)
    INTO median_mean, p25_mean, p75_mean
    FROM public.student_baseline
    WHERE mean_duration IS NOT NULL AND mean_duration > 0;
  END IF;

  pop_iqr := GREATEST(COALESCE(p75_mean, 0) - COALESCE(p25_mean, 0), 1.0);

  -- 贝叶斯收缩：新生向中位数靠拢，15 条记录后完全信任个人值
  v_shrink_alpha   := LEAST(1.0, r.record_count::FLOAT8 / 15.0);
  v_effective_mean := v_shrink_alpha * COALESCE(r.mean_duration, 0.0)
                    + (1.0 - v_shrink_alpha) * COALESCE(median_mean, 30.0);
  v_effective_mean := GREATEST(v_effective_mean, 15.0);

  -- FIX-44: 同专业周中位数 = 个人绝对水平的对比基准
  v_peer_median_weekly := COALESCE(median_mean, 30.0) * 5.0;

  -- ══════════════════════════════════════════════════════════════
  -- 7. A 维度：同专业积累质量 × 记录数 → LN 归一化
  --    FIX-57: quality_score 改用 v_effective_mean（贝叶斯收缩后均值）
  --      旧版用原始 mean_duration：新生前几次若练习较短则 quality_score→0，
  --      A 分直接归零，拉低综合分最多 13 分。
  --      v_effective_mean 在 record_count=0 时等于全班中位数，
  --      随记录数增加逐渐信任个人值（15条后完全个人化），
  --      与 B/T/M/W 保持一致的贝叶斯保护逻辑。
  -- ══════════════════════════════════════════════════════════════
  quality_score := GREATEST(0.0, LEAST(1.0,
    0.5 + (v_effective_mean - COALESCE(median_mean, 0.0))
        / (2.0 * pop_iqr)));
  a_score := LEAST(1.0,
    LN(GREATEST(COALESCE(r.record_count, 0), 0)::FLOAT8 * quality_score + 1.0)
    / LN(31.0));

  -- ══════════════════════════════════════════════════════════════
  -- 8. B 维度 (FIX-34-A + FIX-44 + FIX-46)
  --    近1活跃工作日周 vs 前1活跃工作日周 工作日总时长对比
  --    FIX-44: 65% 变化分量 + 35% 绝对水平分量
  --    FIX-46: 间隔 > 3 周（假期）时对变化分量做中性化
  -- ══════════════════════════════════════════════════════════════
  SELECT
    SUM(CASE WHEN rn = 1 THEN cleaned_duration ELSE 0 END),
    SUM(CASE WHEN rn = 2 THEN cleaned_duration ELSE 0 END),
    MIN(CASE WHEN rn = 1 THEN week_start END),
    MIN(CASE WHEN rn = 2 THEN week_start END)
  INTO v_week1_mins, v_week2_mins, v_week1_start, v_week2_start
  FROM (
    SELECT
      ps.cleaned_duration,
      DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE AS week_start,
      DENSE_RANK() OVER (
        ORDER BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai') DESC
      ) AS rn
    FROM public.practice_sessions ps
    WHERE ps.student_name     = p_student_name
      AND ps.cleaned_duration > 0
      AND ps.session_start    < v_week_start_bjt
      AND ps.session_start   >= v_week_start_bjt - INTERVAL '8 weeks'
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  ) sub
  WHERE rn <= 2;

  IF COALESCE(v_week1_mins, 0) > 0 THEN
    -- 绝对水平分量：近活跃周 vs 同专业周中位数
    b_level := 1.0 / (1.0 + EXP(
      -3.0 * (v_week1_mins - v_peer_median_weekly)
      / GREATEST(v_peer_median_weekly, 150.0)
    ));

    IF COALESCE(v_week2_mins, 0) > 0 THEN
      -- 变化分量：近活跃周 vs 前活跃周
      b_change := 1.0 / (1.0 + EXP(
        -3.0 * (v_week1_mins - v_week2_mins)
        / GREATEST(v_effective_mean * 5.0, 150.0)
      ));

      -- FIX-46: 假期间隔中性化
      --   两个活跃周之间超过 3 周 → 说明中间有长假
      --   gap 每超过 1 周额外中性化 15%，最多 70%
      IF v_week1_start IS NOT NULL AND v_week2_start IS NOT NULL THEN
        b_gap_weeks := (v_week1_start - v_week2_start)::FLOAT8 / 7.0;
        IF b_gap_weeks > 3.0 THEN
          b_neutralize := LEAST(0.70, (b_gap_weeks - 3.0) * 0.15);
          b_change := b_change * (1.0 - b_neutralize) + 0.5 * b_neutralize;
        END IF;
      END IF;
    END IF;

    -- FIX-56: 混合（变化分量权重 80%，绝对水平分量权重 20%）
    --   降低绝对水平优势，让 B 更侧重"相对自身是否改善"而非练量高低
    b_score := 0.80 * b_change + 0.20 * b_level;
  END IF;

  -- ══════════════════════════════════════════════════════════════
  -- 9. T 维度 (FIX-43 块对比 + FIX-44 + FIX-46)
  --    近2活跃周均值 vs 前2活跃周均值，20周上限
  --    FIX-44: 65% 变化分量 + 35% 绝对水平分量
  --    FIX-46: 近块与远块间隔 > 4 周时对变化分量做中性化
  -- ══════════════════════════════════════════════════════════════
  SELECT
    AVG(CASE WHEN rn <= 2 THEN weekly_mins END),
    AVG(CASE WHEN rn  > 2 THEN weekly_mins END),
    COUNT(*),
    MIN(CASE WHEN rn <= 2 THEN week_start END),   -- 近块最早周（FIX-46）
    MAX(CASE WHEN rn  > 2 THEN week_start END)    -- 远块最晚周（FIX-46）
  INTO v_recent_avg, v_older_avg, n_t_weeks, v_t_recent_start, v_t_older_end
  FROM (
    SELECT
      SUM(ps.cleaned_duration) AS weekly_mins,
      DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE AS week_start,
      ROW_NUMBER() OVER (
        ORDER BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai') DESC
      ) AS rn
    FROM public.practice_sessions ps
    WHERE ps.student_name     = p_student_name
      AND ps.cleaned_duration > 0
      AND ps.session_start    < v_week_start_bjt
      AND ps.session_start   >= v_week_start_bjt - INTERVAL '20 weeks'
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    GROUP BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')
    HAVING SUM(ps.cleaned_duration) > 0
    ORDER BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai') DESC
    LIMIT 4
  ) sub;

  IF v_recent_avg IS NOT NULL THEN
    -- 绝对水平分量：近块均值 vs 同专业周中位数
    t_level := 1.0 / (1.0 + EXP(
      -3.0 * (v_recent_avg - v_peer_median_weekly)
      / GREATEST(v_peer_median_weekly, 150.0)
    ));

    IF v_older_avg IS NOT NULL THEN
      -- 变化分量（FIX-43: 块对比）
      t_change := 1.0 / (1.0 + EXP(
        -3.0 * (v_recent_avg - v_older_avg)
        / GREATEST(v_effective_mean * 5.0, 150.0)
      ));

      -- FIX-46: 近块最早周 vs 远块最晚周 的间隔
      --   > 4 周说明中间有假期，变化分量向 0.5 中性化
      IF v_t_recent_start IS NOT NULL AND v_t_older_end IS NOT NULL THEN
        t_gap_weeks := (v_t_recent_start - v_t_older_end)::FLOAT8 / 7.0;
        IF t_gap_weeks > 4.0 THEN
          t_neutralize := LEAST(0.60, (t_gap_weeks - 4.0) * 0.10);
          t_change := t_change * (1.0 - t_neutralize) + 0.5 * t_neutralize;
        END IF;
      END IF;
    END IF;

    -- FIX-56: 混合（<3 活跃周时 t_change 保持 0.5 默认值）
    --   变化分量 80%，绝对水平分量 20%（与 B 保持一致）
    t_score := 0.80 * t_change + 0.20 * t_level;
  END IF;

  -- ══════════════════════════════════════════════════════════════
  -- 10. M 维度 (FIX-52 修订版: 12周窗口内最近4活跃周 + 固定分母2.34)
  --     设计原则：
  --       ① 12周活跃周窗口：假期零练习的周不计入，不惩罚正常假期
  --       ② 固定分母2.34：活跃周 < 4 时分数自然降低（解决原"全满分"bug）
  --       ③ 12周时间约束：防止追溯太远的旧数据（新生/稀疏练习有意义区分）
  --   放假回来首周：取假期前最近4活跃周，不得0分 ✓
  --   新生/极少练：< 4 活跃周，分数低于1.0，有区分度 ✓
  -- ══════════════════════════════════════════════════════════════
  FOR m_rec IN
    SELECT SUM(ps.cleaned_duration) AS weekly_mins
    FROM public.practice_sessions ps
    WHERE ps.student_name     = p_student_name
      AND ps.cleaned_duration > 0
      AND ps.session_start    < v_week_start_bjt
      AND ps.session_start   >= v_week_start_bjt - INTERVAL '12 weeks'
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    GROUP BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')
    HAVING SUM(ps.cleaned_duration) > 0
    ORDER BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai') DESC
    LIMIT 4
  LOOP
    m_wk_num       := m_wk_num + 1;
    m_weight       := POWER(0.65, m_wk_num - 1);
    m_total_weight := m_total_weight + m_weight;
    -- FIX-56: 达标线 = 个人日均 × 5天 × 100%（提高达标难度，恢复 M 区分度）
    --   旧 60%：任何规律练琴学生均可轻松满分，M 丧失区分度
    --   新 100%：需达到自己的周均水平，真正衡量"是否保持了应有的练习强度"
    IF m_rec.weekly_mins >= GREATEST(v_effective_mean, 30.0) * 5.0 * 1.00 THEN
      m_weighted_sum := m_weighted_sum + m_weight;
      m_weeks_met   := m_weeks_met + 1;
    END IF;
  END LOOP;

  -- 固定分母2.34（满4活跃周权重之和）
  -- m_wk_num < 4：数据不足，无法判断规律性 → 中性冷启动0.5
  --   · 新生（只有1-3周数据）：不惩罚也不奖励，等积累足够数据
  --   · 放假后长期未练（12周内 < 4 活跃周）：同样给中性分，不影响整体排名
  -- m_wk_num = 4：有足够数据，按实际达标情况评分
  m_score := CASE
    WHEN m_wk_num < 4 THEN 0.5
    ELSE m_weighted_sum / 2.34
  END;

  -- ══════════════════════════════════════════════════════════════
  -- 11. W 维度 (FIX-20/26/27/32/37)
  --     本周工作日实际时长 / (v_effective_mean × 已过工作日天数)
  -- ══════════════════════════════════════════════════════════════
  SELECT COALESCE(SUM(cleaned_duration), 0) INTO v_weekly_minutes
  FROM public.practice_sessions
  WHERE student_name    = p_student_name
    AND session_start   >= v_week_start_bjt
    AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

  v_dow          := EXTRACT(DOW FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INT;
  -- FIX-53: 周日(DOW=0)应视为本周已过5个工作日，而非0（旧值导致W分恒=0.5）
  v_elapsed_days := CASE v_dow WHEN 0 THEN 5 WHEN 6 THEN 5 ELSE v_dow END;

  IF v_elapsed_days > 0 AND v_effective_mean > 0 THEN
    v_weekly_ratio := v_weekly_minutes::FLOAT8
                    / NULLIF(GREATEST(v_effective_mean, 30.0) * v_elapsed_days, 0.0);
    v_w_score := GREATEST(0.0, LEAST(1.0,
      1.0 / (1.0 + EXP(-3.0 * (COALESCE(v_weekly_ratio, 0.0) - 0.5)))));
  END IF;

  -- ══════════════════════════════════════════════════════════════
  -- 12. 动态权重 (FIX-20 + FIX-56)
  -- ══════════════════════════════════════════════════════════════
  IF hist_count < 4 THEN
    -- FIX-57: 新生阶段 A 权重 25→10%，W 50→70%
    --   新生 A 分天然偏低（记录数少），25% 权重不合理
    --   改为让 W（本周实际表现）主导，完全按当周努力程度评价
    w_baseline := 0.08; w_trend := 0.08; w_momentum := 0.04;
    w_accum    := 0.10; w_week  := 0.70;
  ELSIF hist_count < 12 THEN
    w_baseline := 0.20; w_trend := 0.20; w_momentum := 0.10;
    w_accum    := 0.15; w_week  := 0.35;
  ELSE
    -- FIX-56: W 25→30%，B/T 各 25→22%，A 10→11%
    w_baseline := 0.22; w_trend := 0.22; w_momentum := 0.15;
    w_accum    := 0.11; w_week  := 0.30;
  END IF;

  -- ══════════════════════════════════════════════════════════════
  -- 13. 异常率惩罚 (FIX-40: 折点 60%，指数衰减 k=3.0)
  -- ══════════════════════════════════════════════════════════════
  outlier_penalty := CASE
    WHEN COALESCE(r.outlier_rate, 0.0) <= 0.60
      THEN 1.0 - 0.4 * COALESCE(r.outlier_rate, 0.0)
    ELSE 0.76 * EXP(-3.0 * (COALESCE(r.outlier_rate, 0.0) - 0.60))
  END;

  -- ══════════════════════════════════════════════════════════════
  -- 14. 高峰衰退惩罚 (FIX-31-A/B/C + FIX-32: peak_decay)
  -- ══════════════════════════════════════════════════════════════
  -- 近16周最佳4周均值（按周总量降序取TOP4）
  SELECT COALESCE(AVG(weekly_total), GREATEST(r.mean_duration, 30.0) * 5.0)
  INTO v_peak_weekly_avg
  FROM (
    SELECT SUM(ps.cleaned_duration) AS weekly_total
    FROM public.practice_sessions ps
    WHERE ps.student_name   = p_student_name
      AND ps.session_start  >= v_week_start_bjt - INTERVAL '16 weeks'
      AND ps.session_start  <  v_week_start_bjt
      AND ps.cleaned_duration > 0
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    GROUP BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')
    ORDER BY SUM(ps.cleaned_duration) DESC
    LIMIT 4
  ) top4;

  -- FIX-53: 改用贝叶斯收缩后的 v_effective_mean，与 B/T/M/W 保持一致，防止新生旧均值绕过贝叶斯保护
  v_peak_weekly_avg := COALESCE(v_peak_weekly_avg, GREATEST(v_effective_mean, 30.0) * 5.0);
  -- cap: 不超过历史均值 × 1.6，防止集训高峰拉高阈值（FIX-31-A cap）
  v_peak_weekly_avg := LEAST(v_peak_weekly_avg,
                             GREATEST(v_effective_mean, 30.0) * 5.0 * 1.6);

  -- 近4活跃周均值（FIX-31-C修正：按日期倒序取最近4个活跃周，非日历窗口）
  SELECT COALESCE(AVG(weekly_total), v_peak_weekly_avg)
  INTO v_recent_4w_avg
  FROM (
    SELECT SUM(ps.cleaned_duration) AS weekly_total
    FROM public.practice_sessions ps
    WHERE ps.student_name   = p_student_name
      AND ps.session_start  >= v_week_start_bjt - INTERVAL '16 weeks'
      AND ps.session_start  <  v_week_start_bjt
      AND ps.cleaned_duration > 0
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    GROUP BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')
    ORDER BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai') DESC
    LIMIT 4
  ) recent4;

  -- peak_decay 系数（FIX-32: 与 W 职责分离）
  v_peak_decay := CASE
    WHEN v_peak_weekly_avg <= 0 OR hist_count < 4      THEN 1.0
    WHEN v_recent_4w_avg   >= v_peak_weekly_avg * 0.70 THEN 1.0
    ELSE GREATEST(0.5, v_recent_4w_avg / (v_peak_weekly_avg * 0.70))
  END;

  -- ══════════════════════════════════════════════════════════════
  -- 15. 综合分合成
  -- ══════════════════════════════════════════════════════════════
  composite_raw :=
      w_baseline * b_score
    + w_trend    * t_score
    + w_momentum * m_score
    + w_accum    * a_score
    + w_week     * v_w_score;

  composite_raw := GREATEST(0.0, LEAST(1.0,
    composite_raw * outlier_penalty * v_peak_decay));

  -- ══════════════════════════════════════════════════════════════
  -- 16. 置信度
  -- ══════════════════════════════════════════════════════════════
  score_conf := GREATEST(0.0, LEAST(1.0,
      LEAST(1.0, hist_count::FLOAT8 / 12.0) * 0.5
    + (CASE
        WHEN v_days_inactive <= 7  THEN 1.0
        WHEN v_days_inactive <= 14 THEN 0.7
        WHEN v_days_inactive <= 21 THEN 0.4
        ELSE 0.2
      END) * 0.3
    + (1.0 - COALESCE(r.outlier_rate, 0.0) * 0.5) * 0.2
  ));

  -- ══════════════════════════════════════════════════════════════
  -- 17. 成长加速度（近4周均分 − 前4周均分，归一化到 ±1）
  -- ══════════════════════════════════════════════════════════════
  FOR vel_rec IN
    SELECT sh.composite_score::FLOAT8 AS sc
    FROM public.student_score_history sh
    WHERE sh.student_name    = p_student_name
      AND sh.composite_score > 0
      AND sh.snapshot_date   < v_week_monday
    ORDER BY sh.snapshot_date DESC
    LIMIT 8
  LOOP
    v_vel_cnt8 := v_vel_cnt8 + 1;
    v_vel_sum8 := v_vel_sum8 + vel_rec.sc;
    IF v_vel_cnt8 <= 4 THEN
      v_vel_cnt4 := v_vel_cnt4 + 1;
      v_vel_sum4 := v_vel_sum4 + vel_rec.sc;
    END IF;
  END LOOP;

  IF v_vel_cnt4 > 0 AND v_vel_cnt8 > 4 THEN
    v_growth_velocity :=
      (v_vel_sum4 / v_vel_cnt4
       - (v_vel_sum8 - v_vel_sum4) / (v_vel_cnt8 - v_vel_cnt4))
      / 100.0;
  END IF;

  -- ══════════════════════════════════════════════════════════════
  -- 18. 写入 student_score_history & 更新 student_baseline
  -- ══════════════════════════════════════════════════════════════
  v_composite_score := ROUND((composite_raw * 100)::NUMERIC, 1);
  v_raw_score       := composite_raw;

  PERFORM set_config('app.computing_score', 'true', true);

  INSERT INTO public.student_score_history (
    student_name, snapshot_date,
    composite_score, raw_score,
    baseline_score, trend_score, momentum_score, accum_score,
    outlier_rate, short_session_rate, mean_duration, record_count
  ) VALUES (
    p_student_name, v_week_monday,
    v_composite_score, v_raw_score,
    b_score, t_score, m_score, a_score,
    r.outlier_rate, r.short_session_rate, r.mean_duration, r.record_count
  ) ON CONFLICT (student_name, snapshot_date) DO UPDATE SET
    composite_score    = EXCLUDED.composite_score,
    raw_score          = EXCLUDED.raw_score,
    baseline_score     = EXCLUDED.baseline_score,
    trend_score        = EXCLUDED.trend_score,
    momentum_score     = EXCLUDED.momentum_score,
    accum_score        = EXCLUDED.accum_score,
    outlier_rate       = EXCLUDED.outlier_rate,
    short_session_rate = EXCLUDED.short_session_rate,
    mean_duration      = EXCLUDED.mean_duration,
    record_count       = EXCLUDED.record_count;

  -- FIX-53: 同步写入 w_score，与 compute_and_store_w_score 保持一致，消除双源偏差
  UPDATE public.student_baseline SET
    composite_score  = v_composite_score,
    raw_score        = v_raw_score,
    baseline_score   = b_score,
    trend_score      = t_score,
    momentum_score   = m_score,
    accum_score      = a_score,
    w_score          = v_w_score,
    score_confidence = score_conf,
    growth_velocity  = v_growth_velocity,
    weeks_improving  = m_weeks_met,
    last_updated     = NOW()
  WHERE student_name = p_student_name;

  PERFORM set_config('app.computing_score', 'false', true);

  RETURN QUERY SELECT v_composite_score, v_raw_score;
END;
$$;


-- ============================================================
-- 函数二：compute_student_score_as_of  (历史回填版)
-- ============================================================
CREATE OR REPLACE FUNCTION public.compute_student_score_as_of(
  p_student_name  TEXT,
  p_snapshot_date DATE
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  -- ── A 维度同专业统计
  median_mean          FLOAT8;
  p25_mean             FLOAT8;
  p75_mean             FLOAT8;
  pop_iqr              FLOAT8;
  quality_score        FLOAT8;

  -- ── 学生基线（快照时刻）
  r                    RECORD;

  -- ── FIX-37: 贝叶斯收缩
  v_major              TEXT;
  v_major_count        INT;
  v_shrink_alpha       FLOAT8;
  v_effective_mean     FLOAT8;

  -- ── 历史深度
  hist_count           INTEGER := 0;

  -- ── 五维分数
  b_score              FLOAT8  := 0.5;
  t_score              FLOAT8  := 0.5;
  m_score              FLOAT8  := 0.5;
  a_score              FLOAT8  := 0.0;
  w_score              FLOAT8  := 0.5;

  -- ── FIX-44
  v_peer_median_weekly FLOAT8;

  -- ── B 维度
  v_week1_mins         FLOAT8;
  v_week2_mins         FLOAT8;
  v_week1_start        DATE;
  v_week2_start        DATE;
  b_change             FLOAT8  := 0.5;
  b_level              FLOAT8  := 0.5;
  b_gap_weeks          FLOAT8;
  b_neutralize         FLOAT8;

  -- ── T 维度 (FIX-43)
  v_recent_avg         FLOAT8;
  v_older_avg          FLOAT8;
  n_t_weeks            INTEGER;
  v_t_recent_start     DATE;
  v_t_older_end        DATE;
  t_change             FLOAT8  := 0.5;
  t_level              FLOAT8  := 0.5;
  t_gap_weeks          FLOAT8;
  t_neutralize         FLOAT8;

  -- ── M 维度
  m_rec                RECORD;
  m_weight             FLOAT8;
  m_total_weight       FLOAT8  := 0.0;
  m_weighted_sum       FLOAT8  := 0.0;
  m_wk_num             INTEGER := 0;
  m_weeks_met          INTEGER := 0;

  -- ── 惩罚
  outlier_penalty      FLOAT8;
  v_peak_weekly_avg    FLOAT8  := 0;
  v_recent_4w_avg      FLOAT8  := 0;
  v_peak_decay         FLOAT8  := 1.0;

  -- ── 权重
  w_baseline           FLOAT8;
  w_trend              FLOAT8;
  w_momentum           FLOAT8;
  w_accum              FLOAT8;
  w_week               FLOAT8;

  -- ── 合成
  composite_raw        FLOAT8;
  v_composite_score    NUMERIC;
  v_raw_score          FLOAT8;

  -- ── 置信度
  score_conf           FLOAT8  := 0.5;

  -- ── 时间基准
  v_week_monday        DATE;        -- = p_snapshot_date（应为周一）
  v_week_start_bjt     TIMESTAMPTZ;
  v_week_next_bjt      TIMESTAMPTZ;
  v_has_session        BOOLEAN;

  -- ── W 维度
  v_weekly_minutes     FLOAT8;
  v_elapsed_days       INT;
  v_weekly_ratio       FLOAT8;
  v_dow                INT;
  v_current_monday     DATE;

  -- ── 停琴判断
  v_last_bjt           TIMESTAMPTZ;
  v_days_inactive      INT     := 0;

BEGIN
  -- ══════════════════════════════════════════════════════════════
  -- 1. 时间基准（以 p_snapshot_date 为这周的周一）
  -- ══════════════════════════════════════════════════════════════
  v_week_monday    := p_snapshot_date;
  v_week_start_bjt := (p_snapshot_date::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';
  v_week_next_bjt  := v_week_start_bjt + INTERVAL '7 days';

  -- ══════════════════════════════════════════════════════════════
  -- 2. 读取学生基线（用 as_of 时刻的 compute_baseline 结果）
  -- ══════════════════════════════════════════════════════════════
  SELECT * INTO r FROM public.student_baseline WHERE student_name = p_student_name;
  IF NOT FOUND THEN RETURN; END IF;
  v_major := r.student_major;

  -- ══════════════════════════════════════════════════════════════
  -- 3. 停琴冻结检查（快照日期之前最近一次工作日练琴）
  -- ══════════════════════════════════════════════════════════════
  SELECT MAX(session_start) INTO v_last_bjt
  FROM public.practice_sessions
  WHERE student_name = p_student_name
    AND session_start < v_week_start_bjt
    AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

  v_days_inactive := EXTRACT(DAYS FROM
    (v_week_start_bjt - COALESCE(v_last_bjt, v_week_start_bjt - INTERVAL '999 days')))::INT;

  IF v_days_inactive > 30 THEN
    -- FIX-53: 保留停练学生最后一次有效分数（原为写0，与FIX-12"冻结保留"设计相悖）
    INSERT INTO public.student_score_history (
      student_name, snapshot_date, composite_score, raw_score,
      baseline_score, trend_score, momentum_score, accum_score,
      outlier_rate, short_session_rate, mean_duration, record_count
    ) VALUES (
      p_student_name, v_week_monday,
      COALESCE(r.composite_score, 0), COALESCE(r.raw_score, 0.0),
      NULL, NULL, NULL, NULL,
      r.outlier_rate, r.short_session_rate, r.mean_duration, r.record_count
    ) ON CONFLICT DO NOTHING;
    RETURN;
  END IF;

  -- ══════════════════════════════════════════════════════════════
  -- 4. 该快照周内有无工作日练琴 (FIX-15/19)
  -- ══════════════════════════════════════════════════════════════
  SELECT EXISTS (
    SELECT 1 FROM public.practice_sessions
    WHERE student_name     = p_student_name
      AND cleaned_duration > 0
      AND session_start   >= v_week_start_bjt
      AND session_start   <  v_week_next_bjt
      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  ) INTO v_has_session;

  IF NOT v_has_session THEN
    INSERT INTO public.student_score_history (
      student_name, snapshot_date, composite_score, raw_score,
      baseline_score, trend_score, momentum_score, accum_score,
      outlier_rate, short_session_rate, mean_duration, record_count
    ) VALUES (
      p_student_name, v_week_monday, 0, 0.0,
      NULL, NULL, NULL, NULL,
      r.outlier_rate, r.short_session_rate, r.mean_duration, r.record_count
    ) ON CONFLICT DO NOTHING;
    RETURN;
  END IF;

  -- ══════════════════════════════════════════════════════════════
  -- 5. 历史深度（快照日期之前的活跃周数）
  -- ══════════════════════════════════════════════════════════════
  SELECT COUNT(*) INTO hist_count
  FROM public.student_score_history sh
  WHERE sh.student_name    = p_student_name
    AND sh.composite_score > 0
    AND sh.snapshot_date   < v_week_monday;

  -- ══════════════════════════════════════════════════════════════
  -- 6. 同专业统计 + 贝叶斯收缩 (FIX-37)
  -- ══════════════════════════════════════════════════════════════
  SELECT COUNT(*) INTO v_major_count
  FROM public.student_baseline
  WHERE student_major = v_major AND mean_duration > 0;

  IF v_major_count >= 5 THEN
    SELECT
      PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY mean_duration),
      PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY mean_duration),
      PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY mean_duration)
    INTO median_mean, p25_mean, p75_mean
    FROM public.student_baseline
    WHERE mean_duration IS NOT NULL AND mean_duration > 0
      AND student_major = v_major;
  ELSE
    SELECT
      PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY mean_duration),
      PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY mean_duration),
      PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY mean_duration)
    INTO median_mean, p25_mean, p75_mean
    FROM public.student_baseline
    WHERE mean_duration IS NOT NULL AND mean_duration > 0;
  END IF;

  pop_iqr := GREATEST(COALESCE(p75_mean, 0) - COALESCE(p25_mean, 0), 1.0);

  v_shrink_alpha   := LEAST(1.0, r.record_count::FLOAT8 / 15.0);
  v_effective_mean := v_shrink_alpha * COALESCE(r.mean_duration, 0.0)
                    + (1.0 - v_shrink_alpha) * COALESCE(median_mean, 30.0);
  v_effective_mean := GREATEST(v_effective_mean, 15.0);

  v_peer_median_weekly := COALESCE(median_mean, 30.0) * 5.0;

  -- ══════════════════════════════════════════════════════════════
  -- 7. A 维度
  --    FIX-57: quality_score 改用 v_effective_mean（贝叶斯收缩后均值）
  -- ══════════════════════════════════════════════════════════════
  quality_score := GREATEST(0.0, LEAST(1.0,
    0.5 + (v_effective_mean - COALESCE(median_mean, 0.0))
        / (2.0 * pop_iqr)));
  a_score := LEAST(1.0,
    LN(GREATEST(COALESCE(r.record_count, 0), 0)::FLOAT8 * quality_score + 1.0)
    / LN(31.0));

  -- ══════════════════════════════════════════════════════════════
  -- 8. B 维度 (FIX-34-A + FIX-44 + FIX-46)
  -- ══════════════════════════════════════════════════════════════
  SELECT
    SUM(CASE WHEN rn = 1 THEN cleaned_duration ELSE 0 END),
    SUM(CASE WHEN rn = 2 THEN cleaned_duration ELSE 0 END),
    MIN(CASE WHEN rn = 1 THEN week_start END),
    MIN(CASE WHEN rn = 2 THEN week_start END)
  INTO v_week1_mins, v_week2_mins, v_week1_start, v_week2_start
  FROM (
    SELECT
      ps.cleaned_duration,
      DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE AS week_start,
      DENSE_RANK() OVER (
        ORDER BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai') DESC
      ) AS rn
    FROM public.practice_sessions ps
    WHERE ps.student_name     = p_student_name
      AND ps.cleaned_duration > 0
      AND ps.session_start    < v_week_start_bjt
      AND ps.session_start   >= v_week_start_bjt - INTERVAL '8 weeks'
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
  ) sub
  WHERE rn <= 2;

  IF COALESCE(v_week1_mins, 0) > 0 THEN
    b_level := 1.0 / (1.0 + EXP(
      -3.0 * (v_week1_mins - v_peer_median_weekly)
      / GREATEST(v_peer_median_weekly, 150.0)
    ));

    IF COALESCE(v_week2_mins, 0) > 0 THEN
      b_change := 1.0 / (1.0 + EXP(
        -3.0 * (v_week1_mins - v_week2_mins)
        / GREATEST(v_effective_mean * 5.0, 150.0)
      ));

      IF v_week1_start IS NOT NULL AND v_week2_start IS NOT NULL THEN
        b_gap_weeks := (v_week1_start - v_week2_start)::FLOAT8 / 7.0;
        IF b_gap_weeks > 3.0 THEN
          b_neutralize := LEAST(0.70, (b_gap_weeks - 3.0) * 0.15);
          b_change := b_change * (1.0 - b_neutralize) + 0.5 * b_neutralize;
        END IF;
      END IF;
    END IF;

    -- FIX-56: 变化分量 80%，绝对水平分量 20%
    b_score := 0.80 * b_change + 0.20 * b_level;
  END IF;

  -- ══════════════════════════════════════════════════════════════
  -- 9. T 维度 (FIX-43 + FIX-44 + FIX-46)
  -- ══════════════════════════════════════════════════════════════
  SELECT
    AVG(CASE WHEN rn <= 2 THEN weekly_mins END),
    AVG(CASE WHEN rn  > 2 THEN weekly_mins END),
    COUNT(*),
    MIN(CASE WHEN rn <= 2 THEN week_start END),
    MAX(CASE WHEN rn  > 2 THEN week_start END)
  INTO v_recent_avg, v_older_avg, n_t_weeks, v_t_recent_start, v_t_older_end
  FROM (
    SELECT
      SUM(ps.cleaned_duration) AS weekly_mins,
      DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')::DATE AS week_start,
      ROW_NUMBER() OVER (
        ORDER BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai') DESC
      ) AS rn
    FROM public.practice_sessions ps
    WHERE ps.student_name     = p_student_name
      AND ps.cleaned_duration > 0
      AND ps.session_start    < v_week_start_bjt
      AND ps.session_start   >= v_week_start_bjt - INTERVAL '20 weeks'
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    GROUP BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')
    HAVING SUM(ps.cleaned_duration) > 0
    ORDER BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai') DESC
    LIMIT 4
  ) sub;

  IF v_recent_avg IS NOT NULL THEN
    t_level := 1.0 / (1.0 + EXP(
      -3.0 * (v_recent_avg - v_peer_median_weekly)
      / GREATEST(v_peer_median_weekly, 150.0)
    ));

    IF v_older_avg IS NOT NULL THEN
      t_change := 1.0 / (1.0 + EXP(
        -3.0 * (v_recent_avg - v_older_avg)
        / GREATEST(v_effective_mean * 5.0, 150.0)
      ));

      IF v_t_recent_start IS NOT NULL AND v_t_older_end IS NOT NULL THEN
        t_gap_weeks := (v_t_recent_start - v_t_older_end)::FLOAT8 / 7.0;
        IF t_gap_weeks > 4.0 THEN
          t_neutralize := LEAST(0.60, (t_gap_weeks - 4.0) * 0.10);
          t_change := t_change * (1.0 - t_neutralize) + 0.5 * t_neutralize;
        END IF;
      END IF;
    END IF;

    -- FIX-56: 变化分量 80%，绝对水平分量 20%（与 B 保持一致）
    t_score := 0.80 * t_change + 0.20 * t_level;
  END IF;

  -- ══════════════════════════════════════════════════════════════
  -- 10. M 维度 (FIX-52 修订版: 12周窗口内最近4活跃周 + 固定分母2.34)
  --     假期不惩罚（活跃周查询）+ 新生/稀疏练有区分度（固定分母）
  -- ══════════════════════════════════════════════════════════════
  FOR m_rec IN
    SELECT SUM(ps.cleaned_duration) AS weekly_mins
    FROM public.practice_sessions ps
    WHERE ps.student_name     = p_student_name
      AND ps.cleaned_duration > 0
      AND ps.session_start    < v_week_start_bjt
      AND ps.session_start   >= v_week_start_bjt - INTERVAL '12 weeks'
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    GROUP BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')
    HAVING SUM(ps.cleaned_duration) > 0
    ORDER BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai') DESC
    LIMIT 4
  LOOP
    m_wk_num       := m_wk_num + 1;
    m_weight       := POWER(0.65, m_wk_num - 1);
    m_total_weight := m_total_weight + m_weight;
    -- FIX-56: 达标线 = 个人日均 × 5天 × 100%
    IF m_rec.weekly_mins >= GREATEST(v_effective_mean, 30.0) * 5.0 * 1.00 THEN
      m_weighted_sum := m_weighted_sum + m_weight;
      m_weeks_met   := m_weeks_met + 1;
    END IF;
  END LOOP;

  -- 固定分母2.34（满4活跃周权重之和）
  -- m_wk_num < 4：数据不足，无法判断规律性 → 中性冷启动0.5
  m_score := CASE
    WHEN m_wk_num < 4 THEN 0.5
    ELSE m_weighted_sum / 2.34
  END;

  -- ══════════════════════════════════════════════════════════════
  -- 11. W 维度 (FIX-20/26/27/32/37)
  --     历史周：统计完整周（v_week_start_bjt 到 v_week_next_bjt）
  --     当前周：统计本周已练时长，天数用实际已过工作日数
  -- ══════════════════════════════════════════════════════════════
  v_current_monday := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;

  IF p_snapshot_date = v_current_monday THEN
    -- 当前周：实时统计
    SELECT COALESCE(SUM(cleaned_duration), 0) INTO v_weekly_minutes
    FROM public.practice_sessions
    WHERE student_name   = p_student_name
      AND session_start >= v_week_start_bjt
      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

    v_dow          := EXTRACT(DOW FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INT;
    -- FIX-53: 周日(DOW=0)视为本周已过5个工作日
    v_elapsed_days := CASE v_dow WHEN 0 THEN 5 WHEN 6 THEN 5 ELSE v_dow END;
  ELSE
    -- 历史周：统计整周
    SELECT COALESCE(SUM(cleaned_duration), 0) INTO v_weekly_minutes
    FROM public.practice_sessions
    WHERE student_name   = p_student_name
      AND session_start >= v_week_start_bjt
      AND session_start <  v_week_next_bjt
      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

    v_elapsed_days := 5;  -- 历史周默认 5 个工作日
  END IF;

  IF v_elapsed_days > 0 AND v_effective_mean > 0 THEN
    v_weekly_ratio := v_weekly_minutes::FLOAT8
                    / NULLIF(GREATEST(v_effective_mean, 30.0) * v_elapsed_days, 0.0);
    w_score := GREATEST(0.0, LEAST(1.0,
      1.0 / (1.0 + EXP(-3.0 * (COALESCE(v_weekly_ratio, 0.0) - 0.5)))));
  END IF;

  -- ══════════════════════════════════════════════════════════════
  -- 12. 动态权重 (FIX-20)
  -- ══════════════════════════════════════════════════════════════
  IF hist_count < 4 THEN
    -- FIX-57: 新生阶段 A 权重 25→10%，W 50→70%
    w_baseline := 0.08; w_trend := 0.08; w_momentum := 0.04;
    w_accum    := 0.10; w_week  := 0.70;
  ELSIF hist_count < 12 THEN
    w_baseline := 0.20; w_trend := 0.20; w_momentum := 0.10;
    w_accum    := 0.15; w_week  := 0.35;
  ELSE
    -- FIX-56: W 25→30%，B/T 各 25→22%，A 10→11%
    w_baseline := 0.22; w_trend := 0.22; w_momentum := 0.15;
    w_accum    := 0.11; w_week  := 0.30;
  END IF;

  -- ══════════════════════════════════════════════════════════════
  -- 13. 异常率惩罚 (FIX-40)
  -- ══════════════════════════════════════════════════════════════
  outlier_penalty := CASE
    WHEN COALESCE(r.outlier_rate, 0.0) <= 0.60
      THEN 1.0 - 0.4 * COALESCE(r.outlier_rate, 0.0)
    ELSE 0.76 * EXP(-3.0 * (COALESCE(r.outlier_rate, 0.0) - 0.60))
  END;

  -- ══════════════════════════════════════════════════════════════
  -- 14. 高峰衰退惩罚 (FIX-31)
  -- ══════════════════════════════════════════════════════════════
  SELECT COALESCE(AVG(weekly_total), GREATEST(r.mean_duration, 30.0) * 5.0)
  INTO v_peak_weekly_avg
  FROM (
    SELECT SUM(ps.cleaned_duration) AS weekly_total
    FROM public.practice_sessions ps
    WHERE ps.student_name   = p_student_name
      AND ps.session_start  >= v_week_start_bjt - INTERVAL '16 weeks'
      AND ps.session_start  <  v_week_start_bjt
      AND ps.cleaned_duration > 0
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    GROUP BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')
    ORDER BY SUM(ps.cleaned_duration) DESC
    LIMIT 4
  ) top4;

  -- FIX-53: 改用贝叶斯收缩后的 v_effective_mean，与 B/T/M/W 保持一致
  v_peak_weekly_avg := COALESCE(v_peak_weekly_avg, GREATEST(v_effective_mean, 30.0) * 5.0);
  v_peak_weekly_avg := LEAST(v_peak_weekly_avg,
                             GREATEST(v_effective_mean, 30.0) * 5.0 * 1.6);

  SELECT COALESCE(AVG(weekly_total), v_peak_weekly_avg)
  INTO v_recent_4w_avg
  FROM (
    SELECT SUM(ps.cleaned_duration) AS weekly_total
    FROM public.practice_sessions ps
    WHERE ps.student_name   = p_student_name
      AND ps.session_start  >= v_week_start_bjt - INTERVAL '16 weeks'
      AND ps.session_start  <  v_week_start_bjt
      AND ps.cleaned_duration > 0
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    GROUP BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')
    ORDER BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai') DESC
    LIMIT 4
  ) recent4;

  v_peak_decay := CASE
    WHEN v_peak_weekly_avg <= 0 OR hist_count < 4      THEN 1.0
    WHEN v_recent_4w_avg   >= v_peak_weekly_avg * 0.70 THEN 1.0
    ELSE GREATEST(0.5, v_recent_4w_avg / (v_peak_weekly_avg * 0.70))
  END;

  -- ══════════════════════════════════════════════════════════════
  -- 15. 综合分合成
  -- ══════════════════════════════════════════════════════════════
  composite_raw :=
      w_baseline * b_score
    + w_trend    * t_score
    + w_momentum * m_score
    + w_accum    * a_score
    + w_week     * w_score;

  composite_raw := GREATEST(0.0, LEAST(1.0,
    composite_raw * outlier_penalty * v_peak_decay));

  -- ══════════════════════════════════════════════════════════════
  -- 16. 置信度
  -- ══════════════════════════════════════════════════════════════
  score_conf := GREATEST(0.0, LEAST(1.0,
      LEAST(1.0, hist_count::FLOAT8 / 12.0) * 0.5
    + (CASE
        WHEN v_days_inactive <= 7  THEN 1.0
        WHEN v_days_inactive <= 14 THEN 0.7
        WHEN v_days_inactive <= 21 THEN 0.4
        ELSE 0.2
      END) * 0.3
    + (1.0 - COALESCE(r.outlier_rate, 0.0) * 0.5) * 0.2
  ));

  -- ══════════════════════════════════════════════════════════════
  -- 17. 写入 student_score_history（只写历史，不更新 baseline）
  -- ══════════════════════════════════════════════════════════════
  v_composite_score := ROUND((composite_raw * 100)::NUMERIC, 1);
  v_raw_score       := composite_raw;

  INSERT INTO public.student_score_history (
    student_name, snapshot_date,
    composite_score, raw_score,
    baseline_score, trend_score, momentum_score, accum_score,
    outlier_rate, short_session_rate, mean_duration, record_count
  ) VALUES (
    p_student_name, v_week_monday,
    v_composite_score, v_raw_score,
    b_score, t_score, m_score, a_score,
    r.outlier_rate, r.short_session_rate, r.mean_duration, r.record_count
  ) ON CONFLICT (student_name, snapshot_date) DO UPDATE SET
    composite_score    = EXCLUDED.composite_score,
    raw_score          = EXCLUDED.raw_score,
    baseline_score     = EXCLUDED.baseline_score,
    trend_score        = EXCLUDED.trend_score,
    momentum_score     = EXCLUDED.momentum_score,
    accum_score        = EXCLUDED.accum_score,
    outlier_rate       = EXCLUDED.outlier_rate,
    short_session_rate = EXCLUDED.short_session_rate,
    mean_duration      = EXCLUDED.mean_duration,
    record_count       = EXCLUDED.record_count;

END;
$$;


-- ============================================================
-- 部署后重算步骤
-- ============================================================
-- 步骤1：全量历史重算（B/T 逻辑均已变更，历史分需重新计算）
-- SELECT public.backfill_score_history();
--
-- 步骤2：重算当前综合分
-- SELECT public.compute_student_score(student_name)
--   FROM public.student_baseline
--   WHERE composite_score > 0 OR last_updated IS NOT NULL;
--
-- 步骤3：同步当前周 W 分
-- SELECT public.compute_and_store_w_score(student_name)
--   FROM public.student_baseline;
