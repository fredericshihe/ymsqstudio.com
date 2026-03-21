# 学生练琴基线监控 — 函数备份与架构说明

> 项目：menuhin-school-system（Supabase 项目 ID：waesizzoqodntrlvrwhw）
> 备份日期：2026-03-10 | 最后更新：2026-03-20（FIX-73 trigger_insert_session/trigger_update_student_baseline 补回 SECURITY DEFINER；FIX-72 饭点检测时区Bug+历史误判修复；FIX-71 trigger每次练琴必触发；FIX-70 composite_score改NUMERIC精度；FIX-69 进步榜显示绝对涨分；FIX-68 自动结算开关RLS修复；FIX-65 综合榜Top10退专项榜；FIX-64 稳定/守则榜科学重设计；FIX-63 进步榜最小必要门槛；FIX-62 backfill基线覆写bug）
> 说明：本文件汇总了所有与学生练琴基线监控相关的 SQL 函数，包含完整代码、参数说明和调用关系。

---

## 一、整体架构图

```
【新增练琴记录 practice_logs】
         ↓
【trigger_insert_session（触发器）】   ← 唯一写入 practice_sessions 的触发器
    ↓                                  （fn_sync_practice_session 旧版已于 2026-03-10 删除）
写入
practice_sessions
         ↓
【trigger_update_student_baseline（触发器）】
    动态决定触发频率（冷启动/波动性/距上次更新天数）
         ↓
【update_student_baseline（包装函数）】
    薄封装层，方便未来添加前后置逻辑
         ↓
【compute_baseline / compute_baseline_as_of】
    计算：均值 / 标准差 / alpha / 异常率 / 短时率
    写入：student_baseline 表
         ↓
【trg_fn_compute_score_on_baseline_update（触发器）】
    基线更新后自动触发成长分计算（含熔断防递归）
         ↓
【compute_student_score / compute_student_score_as_of】
    四维成长分：
    B（基线进步）+ T（趋势）+ M（动量）+ A（积累）
    写入：student_score_history 表
         ↓
【run_weekly_score_update（每周定时任务）】
    唯一职责：本周无练琴 → 写入 0 分缺席快照 [FIX-13/FIX-18]
    （有练琴的学生由触发链实时处理，PERCENT_RANK 已废弃）[FIX-18]

【backfill_score_history（全量历史回溯）】
    按周遍历所有历史数据，重算基线+成长分+归一化
    每周内：活跃学生重算，无练琴学生写 0 分快照 [FIX-13]
    baseline 同步在触发器关闭期间执行，防止触发链覆盖 0 分 [FIX-15]

【get_weekly_leaderboards()（前端 RPC 接口）】[FIX-48]
    一次调用返回四个榜单数据：综合榜/进步榜/稳定榜/守则榜
    前端（dashboard.html / 练琴跟踪简化版）直接调用，无需前端计算
    由 student_score_history + student_baseline + practice_sessions 联合查询
```

---

## 二、核心数据表说明

| 表名 | 用途 |
|------|------|
| `practice_sessions` | 每次练琴会话（start/end/时长/清洗后时长/是否异常）|
| `student_baseline` | 每位学生的基线快照（均值/标准差/alpha/成长分等）|
| `student_score_history` | 每位学生每周的成长分历史快照 |
| `practice_logs` | 原始练琴打卡日志（assign/clear 事件）|

---

## 三、函数详细说明与完整代码

---

### 3.1 `clean_duration` — 练琴时长数据清洗

**类型**：普通函数
**用途**：对原始练琴时长进行清洗，剔除无效数据，压缩个人离群值。

**参数**：
- `student TEXT` — 学生姓名
- `raw_dur FLOAT` — 原始时长（分钟）

**返回**：
- `cleaned_dur FLOAT` — 清洗后时长
- `is_outlier BOOL` — 是否为异常值
- `reason TEXT` — 异常原因（too_short / personal_outlier / too_long / capped_120 / meal_break / NULL）

**清洗规则**：
1. 无时长 → 返回 0，标记异常
2. < 5 分钟 → 无效，返回 0
3. 超过个人 mean + 3σ → 压缩到 mean + σ，标记异常
4. 120~180 分钟 → 截断为 120 分钟，**不标记异常**（FIX-24：忘续卡的学生不被惩罚）
5. > 180 分钟 → 截断为 120 分钟，**标记异常**（`too_long`，属于真正忘还卡情况）
6. 正常范围 → 原样返回

```sql
DECLARE
    student_mean FLOAT;
    student_std  FLOAT;
BEGIN
    SELECT mean_duration, std_duration
    INTO student_mean, student_std
    FROM public.student_baseline
    WHERE student_name = student;

    IF raw_dur IS NULL THEN
        RETURN QUERY SELECT 0::FLOAT, TRUE, 'no_duration';
        RETURN;
    END IF;

    IF raw_dur < 5 THEN
        RETURN QUERY SELECT 0::FLOAT, TRUE, 'too_short';
        RETURN;
    END IF;

    IF student_mean IS NOT NULL AND student_std IS NOT NULL THEN
        IF raw_dur > student_mean + 3 * student_std THEN
            RETURN QUERY SELECT (student_mean + student_std)::FLOAT, TRUE, 'personal_outlier';
            RETURN;
        END IF;
    END IF;

    -- FIX-24: 120~180 分钟截断不判异常，> 180 分钟截断且标记异常
    IF raw_dur > 180 THEN
        RETURN QUERY SELECT 120::FLOAT, TRUE, 'too_long';
        RETURN;
    END IF;

    IF raw_dur > 120 THEN
        RETURN QUERY SELECT 120::FLOAT, FALSE, 'capped_120';
        RETURN;
    END IF;

    RETURN QUERY SELECT raw_dur, FALSE, NULL::TEXT;
END;
```

---

### 3.2 `compute_baseline` — 计算学生基线（当前版本）

**类型**：普通函数
**用途**：基于最近 30 条有效练琴记录，计算学生个人基线并写入 `student_baseline` 表。

**参数**：
- `p_student_name TEXT` — 学生姓名

**当前实现说明（2026-03-11）**：
1. `compute_baseline` 已改为**薄封装**，实际逻辑统一委托给 `compute_baseline_as_of(p_student_name, CURRENT_DATE + 1)`。
2. 因此当前生效的基线公式以 **3.3 `compute_baseline_as_of`** 为准，而不是早期版本的重复实现。
3. 当前 alpha 逻辑的关键点：
   - 只看最近30条有效记录
   - `std` 在样本不足时会保护，不再伪造波动
   - 波动惩罚已改为 **CV（std / mean）**，不再出现“均值越高反而扣分越多”的旧问题
   - 冷启动仍保留同专业/同年级群体混合
   - `alpha` 最终硬截断在 `[0.5, 1.0]`

**当前 alpha 组成**：
- 低均值风险惩罚：均值越低，alpha 越低
- 波动惩罚：`LEAST(0.20, CV × 0.15)`，波动越大，alpha 越低
- 异常率惩罚：`0.02 × outlier_rate`
- 短时率惩罚：`0.05 × short_session_rate`

**结论**：当前基线可信度已经以 `compute_baseline_as_of` 的 CV 版本为准，`compute_baseline` 本身不再维护独立公式。

---

### 3.3 `compute_baseline_as_of` — 截止某日期计算基线（历史回溯版）

**类型**：普通函数
**用途**：与 `compute_baseline` 逻辑相同，但只使用截止 `p_as_of_date` 之前的数据，用于历史快照回溯。

**参数**：
- `p_student_name TEXT` — 学生姓名
- `p_as_of_date DATE` — 截止日期

**与 `compute_baseline` 的关键区别**：
- 所有数据查询都加 `AND session_start < p_as_of_date::TIMESTAMPTZ`
- UPSERT 时 `last_updated` 写入 `p_as_of_date`（而非 NOW()）

```sql
-- 核心区别示例（其余逻辑与 compute_baseline 完全一致）:
WHERE student_name     = p_student_name
  AND cleaned_duration > 0
  AND session_start    < p_as_of_date::TIMESTAMPTZ  -- ← 截止日期过滤
ORDER BY session_start DESC LIMIT 30

-- UPSERT 时时间戳：
last_updated = p_as_of_date::TIMESTAMPTZ  -- ← 写历史时间，非 NOW()
```

---

### 3.4 `recompute_all_baselines` — 批量重算所有学生基线

**类型**：普通函数
**用途**：遍历所有有练琴记录的学生，重新调用 `update_student_baseline` 计算基线。

```sql
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT DISTINCT student_name FROM public.practice_sessions LOOP
    PERFORM public.update_student_baseline(r.student_name);
  END LOOP;
END;
```

---

### 3.5 `compute_student_score` — 计算学生成长分（当前版本）

**类型**：普通函数（返回 composite_score, weight_conf）
**用途**：基于基线快照历史，计算四维成长分，写入 `student_score_history` 并更新 `student_baseline`。

**五个维度说明（FIX-20）**：

| 维度 | 英文 | 计算逻辑 |
|------|------|---------|
| B | Baseline Progress | **最近2活跃周工作日练琴量**差值，相对个人周基准归一化（FIX-34-A：数据源改为 practice_sessions，消除 raw_score 回声）|
| T | Trend | **最近3活跃周工作日练琴量**线性回归斜率，相对个人周基准归一化（FIX-33：数据源改为 practice_sessions，与 B 解耦）|
| M | Momentum | **近4活跃周练琴量≥个人周基准70%的加权比例**，越近权重越高（FIX-34-B：数据源改为 practice_sessions，消除 raw_score 回声）|
| A | Accumulation | 最近样本量 × 同专业时长质量形成的“练琴底盘”，不是生涯总时长 |
| **W** | **Weekly Progress** | **本周工作日实际时长 / (均值 × 已过工作日天数)，Sigmoid 归一化，实时生效（FIX-20 新增）**|

**动态权重（FIX-20 五维版）**：

| hist_count（仅统计有练琴周） | w_baseline | w_trend | w_momentum | w_accum | **w_week** |
|-----------|-----------|---------|-----------|---------|----------|
| < 4 | 10% | 10% | 5% | 25% | **50%** |
| 4~11 | 20% | 20% | 10% | 15% | **35%** |
| ≥ 12 | 25% | 25% | 15% | 10% | **25%** |

**其他修正**：
- 异常惩罚：outlier_rate > 0.4 时，乘以指数衰减系数（按当前业务要求保留，不在 FIX-17 中调整）
- 数据新鲜度：distance_stale > 7 天开始衰减，> 90 天降至 0.1
- 置信度 = **有效练琴周数深度因子** × 异常因子 × 新鲜度

**FIX-12 停琴检测**（插入位置：① 读取基线之后、② IQR 统计之前）：
- 若该学生**超过 30 天**无新 `practice_sessions` 记录，则**不再重算**四维成长分，直接进入「冻结」分支：
  - **分数**：沿用当前 `student_baseline.composite_score`，不再变更。
  - **置信度**：按停琴天数指数衰减  
    `conf_frozen = conf_last × e^(-0.005 × (days - 30))`，下限 0.05、上限 1.0。
  - **基线表**：仅更新 `score_confidence` 与 `last_updated`，其余字段不动。
  - **历史表**：以**本周一**（`DATE_TRUNC('week', CURRENT_DATE)`）写入冻结快照（沿用当前 baseline 的 B/T/M/A 与 raw/composite）。[FIX-14] 统一快照日期，ON CONFLICT DO UPDATE 保证每周只有一行。
- 从未有过 session 的学生（`MAX(session_start)` 为 NULL）视为停琴天数无穷大，走冻结分支。
- **[FIX-15]** 若该学生停琴 ≤ 30 天但**本周仍无练琴记录**，`compute_student_score` 写入历史时使用 `ON CONFLICT DO NOTHING`，保护周批次已写好的 0 分快照不被覆盖。

```sql
-- 完整代码（已在上方函数列表中提供，此处为关键片段）

-- B：基线进步（只比较有练琴周）
b_score := 1.0 / (1.0 + EXP(
    -3.0 * (hist_score_recent - hist_score_early) / 0.3
));

-- T：趋势（线性回归斜率）
slope := (n_points * sum_xy - sum_x * sum_y) / NULLIF(n_points * sum_x2 - sum_x * sum_x, 0);
t_score := 1.0 / (1.0 + EXP(-slope / 0.02 * 3.0));

-- M：动量（连续改善周数）
m_score := LEAST(1.0, LN(consec_improve::FLOAT + 1.0) / LN(9.0));

-- A：积累/底盘（最近样本量 × 质量）
quality_score := 1.0 / (1.0 + EXP(-((r.mean_duration - median_mean) / (pop_iqr / 1.35))));
a_score := LEAST(1.0, LN(accum_raw + 1.0) / LN(31.0));

-- W：本周进度（实时）
w_score := 1.0 / (1.0 + EXP(-3.0 * (v_weekly_ratio - 0.5)));

-- 合成（FIX-20：已加入 W 维度）
composite_raw := w_baseline*b_score + w_trend*t_score + w_momentum*m_score + w_accum*a_score + w_week*w_score;

-- 异常惩罚
outlier_penalty := CASE
    WHEN outlier_rate <= 0.4 THEN 1.0
    ELSE EXP(-5.0 * (outlier_rate - 0.4))
END;
```

---

### 3.6 `compute_student_score_as_of` — 截止某日期计算成长分（历史回溯版）

**类型**：普通函数（无返回值，直接写入）
**用途**：与 `compute_student_score` 逻辑相同，但只使用 `p_snapshot_date` 之前的历史数据，用于 `backfill_score_history` 批量回溯。

**与 `compute_student_score` 的关键区别**：
- 所有历史查询加 `AND snapshot_date < p_snapshot_date`
- 置信度计算用 `p_snapshot_date` 而非 `NOW()`（避免 freshness 恒为 1）
- FIX-17 后与实时版完全同步：同样排除缺席周、同样使用新权重、同样只按有效练琴周计算置信度深度

---

### 3.7 `compute_all_student_scores` — 批量计算所有学生成长分

**类型**：普通函数
**用途**：遍历 `student_baseline` 中所有学生，逐一调用 `compute_student_score`。

```sql
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT student_name FROM public.student_baseline LOOP
    PERFORM public.compute_student_score(r.student_name);
  END LOOP;
END;
```

---

### 3.8 `backfill_score_history` — 全量历史回溯

**类型**：普通函数
**用途**：从最早练琴记录开始，按周循环，重算每一周的基线+成长分+归一化，用于数据修复或首次初始化。

**执行流程**（FIX-13/15 零分制版本）：
1. 禁用触发器（`app.skip_score_trigger = 'on'`）
2. 找到最早有效练琴记录的周一作为起始日期
3. 按周循环到当前：
   - **①** 计算每位学生截止该日的基线
   - **②** 判断该学生当前迭代周内是否有练琴 `session_start ∈ [周一, 下周一)`：
     - 有练琴 → `compute_student_score_as_of`（正常重算）
     - 无练琴 → 插入 `composite_score = 0` 快照（`ON CONFLICT DO NOTHING`）
   - **③** PERCENT_RANK 归一化：**仅对当周活跃学生**（无练琴学生不参与）
4. **④** 同步最新有效分数到 `student_baseline`（**触发器仍关闭**）[FIX-15]
5. 恢复触发器

```sql
-- 核心循环结构（FIX-13 零分制）
WHILE v_current_date <= v_end_date LOOP
    v_next_date := v_current_date + INTERVAL '7 days';

    -- ① 基线（有历史数据的所有学生）
    FOR v_student IN SELECT DISTINCT student_name FROM practice_sessions
                     WHERE session_start < v_current_date AND cleaned_duration > 0
    LOOP
        PERFORM public.compute_baseline_as_of(v_student.student_name, v_current_date);
    END LOOP;

    -- ② 成长分：本周活跃 → 重算；无练琴 → 写 0
    FOR v_student IN (同上) LOOP
        IF EXISTS (SELECT 1 FROM practice_sessions
                   WHERE student_name = v_student.student_name
                     AND cleaned_duration > 0
                     AND session_start >= v_current_date AND session_start < v_next_date) THEN
            PERFORM public.compute_student_score_as_of(v_student.student_name, v_current_date);
        ELSE
            INSERT INTO student_score_history (student_name, snapshot_date, raw_score, composite_score, ...)
            VALUES (v_student.student_name, v_current_date, 0, 0, NULL...)
            ON CONFLICT DO NOTHING;
        END IF;
    END LOOP;

    -- ③ 归一化：仅活跃学生（raw_score > 0 且本周有练琴）
    UPDATE student_score_history h SET composite_score = norm.normalized
    FROM (SELECT student_name,
                 ROUND(PERCENT_RANK() OVER (ORDER BY raw_score) * 100)::INT AS normalized
          FROM student_score_history WHERE snapshot_date = v_current_date
            AND raw_score > 0
            AND EXISTS (SELECT 1 FROM practice_sessions ps
                        WHERE ps.student_name = student_score_history.student_name
                          AND ps.session_start >= v_current_date AND ps.session_start < v_next_date)
         ) norm
    WHERE h.snapshot_date = v_current_date AND h.student_name = norm.student_name;

    v_current_date := v_next_date;
END LOOP;

-- ④ baseline 同步（触发器关闭期间，防止触发链写入脏快照）
UPDATE student_baseline b SET composite_score = latest.composite_score
FROM (SELECT DISTINCT ON (student_name) student_name, composite_score
      FROM student_score_history WHERE composite_score > 0
      ORDER BY student_name, snapshot_date DESC) latest
WHERE b.student_name = latest.student_name;
```

**实现文件**：`fix15_week_aware_score.sql`（FIX-13/14/15） → `fix17_rebalance_score_model.sql`（当前评分模型最新版）

---

### 3.9 `run_weekly_score_update` — 每周定时更新任务

**类型**：普通函数
**用途**：每周一定时执行，**唯一职责是给本周未练琴的学生写 0 分快照**。

> **2026-03-12 重大简化（去掉 PERCENT_RANK）**
>
> 原版函数包含：重算基线 → 重算成长分 → PERCENT_RANK 归一化 → 同步 baseline。
> 现已全部移除，原因如下：
> - **有练琴的学生**：触发链（`practice_logs→practice_sessions→student_baseline→student_score_history`）已实时完成所有计算，`composite_score = ROUND(raw_score × 100)`，无需周批次干预
> - **PERCENT_RANK 归一化**：仅影响分数的视觉分布，不改变排名顺序，且造成排名每周才刷新一次，已废弃
> - **无练琴的学生**：触发链不会主动写缺席记录，因此保留周批次写 0 分快照这一步

**执行步骤（新版）**：
1. 取本周一（`DATE_TRUNC('week', CURRENT_DATE)`）作为 `snapshot_date`
2. 查找 `student_baseline` 中本周无任何有效 `practice_sessions` 的学生
3. 为这些学生插入 `composite_score = 0` 的缺席快照（`ON CONFLICT DO NOTHING`，不覆盖已有数据）

**composite_score 含义变化**：
- 旧版：PERCENT_RANK × 100（百分位，每周才更新）
- **新版：`ROUND(raw_score × 100)`（原始成长分放大，每次练琴后实时更新）**

**零分制规则**（保持不变）：
- 本周有练琴 → 触发链实时计算分数（`composite_score > 0`）
- 本周无练琴 → 周批次写 `composite_score = 0`，Dashboard 显示"本周未练"
- 恢复练琴后 → 触发链自动用 `ON CONFLICT DO UPDATE` 覆盖 0 分快照

```sql
-- ============================================================
-- 新版 run_weekly_score_update（FIX-18：去掉 PERCENT_RANK）
-- 在 Supabase SQL Editor 中执行此语句即可完成升级
-- ============================================================
CREATE OR REPLACE FUNCTION public.run_weekly_score_update()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_week_start DATE;
    v_student    TEXT;
BEGIN
    v_week_start := DATE_TRUNC('week', CURRENT_DATE)::DATE;

    -- 唯一任务：给本周没有练琴记录的学生写入 0 分缺席快照
    -- 有练琴的学生由触发器链路实时写入，无需在此重算
    FOR v_student IN
        SELECT student_name
        FROM public.student_baseline
        WHERE student_name NOT IN (
            SELECT DISTINCT student_name
            FROM public.practice_sessions
            WHERE session_start >= v_week_start::TIMESTAMPTZ
              AND cleaned_duration > 0
        )
    LOOP
        INSERT INTO public.student_score_history (
            student_name,
            snapshot_date,
            raw_score,
            composite_score,
            baseline_score,
            trend_score,
            momentum_score,
            accum_score
        )
        VALUES (
            v_student,
            v_week_start,
            0, 0,
            NULL, NULL, NULL, NULL
        )
        ON CONFLICT (student_name, snapshot_date) DO NOTHING;
    END LOOP;
END;
$$;

-- 推荐调用方式（每周一 00:05 通过 pg_cron 触发）：
-- SELECT public.run_weekly_score_update();
```

**实现文件**：`fix18_remove_percent_rank.sql`

---

### 3.10 触发器函数汇总

#### `trigger_update_student_baseline` — 动态触发基线更新（推荐版本）

**触发时机**：`practice_sessions` 表 INSERT 后
**核心逻辑**：根据冷启动状态、变异系数(CV)、距上次更新天数，动态计算触发间隔：

| 条件 | 触发间隔 |
|------|---------|
| record_count < 5 | 每条都算 |
| record_count < 10 | 每2条 |
| CV > 0.5（高波动）| 每3条 |
| CV > 0.3（中波动）| 每5条 |
| CV ≤ 0.3（稳定）| 每10条 |
| 距上次更新 ≥ 7天 | 间隔减半 |
| 距上次更新 ≥ 14天 | 强制更新 |

#### `trigger_update_baseline` — 简单版触发器（每5条触发）

```sql
-- 每积累5条练琴记录，触发一次基线更新
IF (SELECT COUNT(*) % 5 = 0 FROM public.practice_logs WHERE student_name = NEW.student_name)
THEN PERFORM public.update_student_baseline(NEW.student_name);
END IF;
```

#### `trg_fn_compute_score_on_baseline_update` — 基线更新后触发成长分计算

**含熔断机制**，防止 compute_student_score 内部的 UPDATE 再次触发此触发器造成无限递归：

```sql
-- 熔断检查
IF current_setting('app.computing_score', true) = 'true' THEN RETURN NEW; END IF;
PERFORM set_config('app.computing_score', 'true', true);
PERFORM public.compute_student_score(NEW.student_name);
PERFORM set_config('app.computing_score', 'false', true);
```

#### `fn_trigger_compute_student_score` / `trigger_compute_student_score`

利用 `pg_trigger_depth()` 防止递归：
```sql
IF pg_trigger_depth() > 0 THEN RETURN NEW; END IF;
PERFORM public.compute_student_score(NEW.student_name);
```

---

### 3.11 调试函数

#### `debug_confidence` — 调试置信度

**参数**：`p_student_name TEXT`
**返回**：hist_count / outlier_rate / days_stale / data_freshness / factor1 / factor2 / weight_conf

#### `debug_weight_conf` — 调试权重置信度（详细版）

**参数**：`p_student_name TEXT`
**返回**：8列详细中间值，包括每个因子的独立数值和最终 `weight_conf`

---

## 四、常用调用示例

```sql
-- 1. 手动更新单个学生基线
SELECT public.compute_baseline('张三');

-- 2. 手动计算单个学生成长分（含写入历史快照）
SELECT * FROM public.compute_student_score('张三');

-- 3. 批量重算所有学生基线
SELECT public.recompute_all_baselines();

-- 4. 批量计算所有学生成长分
SELECT public.compute_all_student_scores();

-- 5. 每周定时任务（手动触发）
SELECT public.run_weekly_score_update();

-- 6. 全量历史回溯（慎用，耗时较长）
SELECT public.backfill_score_history();

-- 7. 调试某学生置信度
SELECT * FROM public.debug_weight_conf('张三');

-- 8. 查看某学生基线状态
SELECT student_name, mean_duration, std_duration, alpha, is_cold_start,
       composite_score, score_confidence, last_updated
FROM public.student_baseline
WHERE student_name = '张三';

-- 9. 查看某学生成长分历史
SELECT snapshot_date, raw_score, composite_score,
       baseline_score, trend_score, momentum_score, accum_score
FROM public.student_score_history
WHERE student_name = '张三'
ORDER BY snapshot_date DESC;

-- 10. 全量历史重建（FIX-13/14/15 版本，含零分制 + 快照日期统一）
-- 在 SQL Editor 执行：fix15_week_aware_score.sql

-- 11. 验证当前周是否有"本周有分但无练琴"的脏数据（应返回 0 行）
SELECT h.student_name, h.snapshot_date, h.composite_score
FROM public.student_score_history h
WHERE h.snapshot_date = DATE_TRUNC('week', CURRENT_DATE)::DATE
  AND h.composite_score > 0
  AND NOT EXISTS (
    SELECT 1 FROM public.practice_sessions ps
    WHERE ps.student_name = h.student_name
      AND ps.cleaned_duration > 0
      AND ps.session_start >= DATE_TRUNC('week', CURRENT_DATE)
  );

-- 12. 查看基线健康状态
SELECT * FROM public.v_baseline_health;
```

---

## 五、关键参数说明

| 参数 | 含义 | 典型值 |
|------|------|-------|
| `alpha` | 基线可信度系数，越高说明数据越可靠 | 0.5 ~ 1.0 |
| `is_cold_start` | 是否为冷启动状态（记录数 < 10）| true/false |
| `outlier_rate` | 异常练琴记录占比 | 0.0 ~ 1.0 |
| `short_session_rate` | 短时练琴（5~30分钟）占比 | 0.0 ~ 1.0 |
| `raw_score` | 原始成长分（未归一化）| 0.0 ~ 1.0 |
| `composite_score` | 归一化后的百分位成长分；**0 表示本周未练琴**（Dashboard 显示"本周未练"）| 0 ~ 100 |
| `score_confidence` | 成长分置信度 | 0.0 ~ 1.0 |
| `growth_velocity` | 最近4周 vs 最近8周的斜率差（成长加速度）| 负~正 |
| `weeks_improving` | 连续改善周数 | 0 ~ N |
| `personal_best` | 历史最高 composite_score | 0 ~ 100 |

---

## 六、问题核查与优化建议（已验证 · 2026-03-10）

---

### ✅ 问题一：`update_student_baseline` 函数存在【已核实，无问题】

**核查结论**：`update_student_baseline` **确实存在**，是 `compute_baseline` 的包装函数（wrapper）。
调用链如下：

```
trigger_update_student_baseline（触发器）
    ↓ PERFORM
update_student_baseline(student_name)        ← 包装层
    ↓ PERFORM
compute_baseline(p_student_name)             ← 实际计算逻辑
```

**`update_student_baseline` 完整代码**：
```sql
BEGIN
  PERFORM public.compute_baseline(p_student_name);
END;
```

**设计说明**：这种两层设计的好处是——如果未来需要在基线计算前后添加额外逻辑（如日志、通知、清洗前置步骤），只需修改 `update_student_baseline`，不影响 `compute_baseline` 本身，也不需要修改所有触发器。

**调用关系完整链路**（更新后）：

| 调用者 | 调用函数 | 最终执行 |
|--------|---------|---------|
| `recompute_all_baselines` | `update_student_baseline` | `compute_baseline` |
| `trigger_update_baseline` | `update_student_baseline` | `compute_baseline` |
| `trigger_update_student_baseline` | `update_student_baseline` | `compute_baseline` |

**结论**：此问题**不存在**，原文档误判，已修正。

---

### ✅ 问题二：`backfill_score_history` 性能风险【已确认，建议优化】

**核查结论**：函数使用 WHILE 循环按周遍历，每周对所有学生执行两次子查询密集型函数。

**粗略耗时估算**（以 50 名学生 × 26 周为例）：
- `compute_baseline_as_of` × 1300 次
- `compute_student_score_as_of` × 1300 次
- 每次内含多个 CTE + 窗口函数
- 预计总耗时：**5~20 分钟**（视数据量）

**优化建议**：

```sql
-- ① 分段执行（按学期或按年），避免单次超时
-- 示例：只回溯最近半年
SELECT public.backfill_score_history();  -- 原函数已自动找最早日期，不支持分段
-- 建议在 Supabase Dashboard > SQL Editor 中直接执行，不要通过 Edge Function 调用（有30秒超时限制）

-- ② 执行前先关闭 Realtime 订阅（避免大量 WAL 推送）
-- 在 Supabase Dashboard > Database > Replication 中临时关闭 student_baseline 和 student_score_history 的订阅

-- ③ 执行后验证数据完整性
SELECT COUNT(DISTINCT student_name), MIN(snapshot_date), MAX(snapshot_date)
FROM public.student_score_history;
```

**最佳实践**：仅在数据修复或初始化时使用，日常依赖 `run_weekly_score_update` 维护。

---

### ⚠️ 问题三：三套防递归机制分工不清，存在漏洞【已确认，需注意】

**核查结论**：三套机制实际服务于不同层级，但存在两个隐患：

#### 三套机制的实际分工：

| 机制 | 使用函数 | 防御目标 |
|------|---------|---------|
| `pg_trigger_depth() > 0` | `fn_trigger_compute_student_score` | 防止 practice_sessions 的 INSERT 触发器在深层触发中重复执行 |
| `pg_trigger_depth() > 1` | `trigger_compute_student_score` | 允许深度1触发，防止深度2+ |
| `app.computing_score` | `trg_fn_compute_score_on_baseline_update` | 防止 student_baseline UPDATE → compute_student_score → UPDATE baseline 的无限递归 |
| `app.skip_score_trigger` | `backfill_score_history`, `run_weekly_score_update` | 批量写入时跳过触发器 |

#### 隐患一：`app.skip_score_trigger` **从未被任何触发器读取！**

`backfill_score_history` 和 `run_weekly_score_update` 中设置了 `app.skip_score_trigger = 'on'`，
但查遍所有触发器函数，**没有一个函数检查这个配置**，导致批量执行期间触发器依然全部触发，完全达不到预期的跳过效果。

**修复方案**：在每个计算分数的触发器函数顶部加入检查：
```sql
-- 在 trg_fn_compute_score_on_baseline_update 顶部加入：
IF current_setting('app.skip_score_trigger', true) = 'on' THEN
    RETURN NEW;
END IF;
```

#### 隐患二：`fn_trigger_compute_student_score` 与 `trigger_compute_student_score` 若同时挂载同一张表，会导致 `compute_student_score` 被调用两次

- `fn_trigger_compute_student_score`：`pg_trigger_depth() > 0` → 深度0时执行
- `trigger_compute_student_score`：`pg_trigger_depth() > 1` → 深度0和1时都执行

若两者都挂在 `practice_sessions` 或 `student_baseline` 上，每次写入会触发**两次**成长分计算。

**验证是否存在重复挂载**（SQL Editor 运行）：
```sql
SELECT trigger_name, event_object_table, action_statement
FROM information_schema.triggers
WHERE trigger_schema = 'public'
  AND action_statement LIKE '%compute_student_score%'
ORDER BY event_object_table, trigger_name;
```

---

### ✅ 问题四：`composite_score` 实时值与周归一化值含义不同【已确认，设计如此】

**核查结论**：经代码分析，这是**有意的两层设计**，但需要明确区分含义：

| 字段 | 写入时机 | 含义 | 可比性 |
|------|---------|------|-------|
| `raw_score`（0~1） | 每次 `compute_student_score` / `as_of` 写入 | 该学生自身的原始成长值 | 可反映个人变化，不可跨学生比较 |
| `composite_score`（0~100，实时）| `compute_student_score` 写入 `ROUND(raw_score × 100)`，每次练琴后实时更新 | 原始成长值放大显示，可用于排名排序 | 排名顺序有效，数值分布集中在 50~75 |

> **FIX-18（2026-03-12）**：已废弃 PERCENT_RANK 归一化，`composite_score` 统一为 `ROUND(raw_score × 100)`，完全实时。排名顺序不变，分数更新更及时。

**前端排名查询**：
```sql
-- 按 composite_score 排序即为正确排名（实时有效）
SELECT student_name, raw_score, composite_score, last_updated
FROM public.student_baseline
ORDER BY composite_score DESC;
```

### ✅ 问题五：冷启动阈值 10 条【已确认合理，提供调整参考】

**核查结论**：10 条记录作为冷启动阈值在代码中一共出现 **3 处**，且逻辑一致：

```sql
-- compute_baseline 和 compute_baseline_as_of 中：
IF COALESCE(v_count, 0) < 10 THEN  -- 触发冷启动群体混合

-- trigger_update_student_baseline 中：
WHEN v_record_count < 10 THEN 2    -- 每2条触发一次（比正常更频繁）
```

**不同练琴频率下的冷启动持续时间估算**：

| 练琴频率 | 达到10条所需时间 |
|---------|---------------|
| 每天练 | ~2 周 |
| 每周3次 | ~3 周 |
| 每周1次 | ~10 周 |

**建议**：如果学校新学期有大批新生同时入学，建议在第一次全体有记录后立即手动执行一次：
```sql
SELECT public.recompute_all_baselines();  -- 注意：先确认问题一已修复
```

---

## 七、修复记录（2026-03-10 已完成）

---

### ✅ 修复零：`trigger_insert_session` 完整代码备份（2026-03-19 最终版，含 FIX-51B）

**说明**：这是 `practice_logs → practice_sessions` 链路中最关键的函数。旧版（`fn_sync_practice_session`）已于 2026-03-10 删除，当前使用以下新版逻辑。

**关键改进点**：
1. 明确使用 `TIMESTAMPTZ` 变量 `v_assign_time` / `v_clear_time` 代替直接引用 `pl.created_at`，彻底解决子查询中字段歧义问题（原版）
2. 中间断点检查使用局部变量而非表别名关联，逻辑更清晰（原版）
3. 保留 16 小时时间窗口限制（防止跨天误配对）（原版）
4. **FIX-51B**：不足 5 分钟时，主动 DELETE 已有的同 `(student_name, session_start)` 错误记录，再 RETURN NEW（旧版只是静默跳过，不清理历史脏数据）
5. 120~180 分钟（7200~10800 秒）→ 截断为 120 分钟，**不判异常**（FIX-24：忘续卡保护）；但若同时跨饭点，升级为 `meal_break` 异常（FIX-30）
6. 超过 180 分钟（10800 秒）→ 截断为 120 分钟，**标记异常** `too_long`（最高优先级，不被 meal_break 覆盖）
7. **FIX-50**：饭点检测改为"峰值时刻在场"（12:10 午饭 / 18:10 晚饭，周三不判晚饭），替代旧的"完全跨越"检测（FIX-39）
8. **FIX-41**：始终从时间戳计算时长，废弃前端传入的 `practice_duration` 字段

```sql
CREATE OR REPLACE FUNCTION public.trigger_insert_session()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_assign           RECORD;
    v_duration_seconds INTEGER;
    v_assign_time      TIMESTAMPTZ;
    v_clear_time       TIMESTAMPTZ;
    v_cleaned_duration INTEGER;
    v_is_outlier       BOOLEAN;
    v_outlier_reason   TEXT;
    v_start_bjt        TIMESTAMPTZ;
    v_end_bjt          TIMESTAMPTZ;
    v_start_time       TIME;
    v_end_time         TIME;
    v_dow              INTEGER;
    v_spans_meal_break BOOLEAN;
BEGIN
    IF NEW.action != 'clear' THEN
        RETURN NEW;
    END IF;

    v_clear_time := NEW.created_at;

    -- 第一步：找最近的 assign（16小时内，同学生+同琴房）
    SELECT pl.*
    INTO v_assign
    FROM public.practice_logs pl
    WHERE pl.student_name = NEW.student_name
      AND pl.room_name    = NEW.room_name
      AND pl.action       = 'assign'
      AND pl.created_at   < v_clear_time
      AND pl.created_at   > v_clear_time - INTERVAL '16 hours'
    ORDER BY pl.created_at DESC
    LIMIT 1;

    IF v_assign IS NULL THEN
        RETURN NEW; -- 没找到配对，静默跳过
    END IF;

    v_assign_time := v_assign.created_at;

    -- 第二步：检查 assign/clear 之间是否有其他 clear（防止重复消费同一个 assign）
    IF EXISTS (
        SELECT 1
        FROM public.practice_logs mid
        WHERE mid.student_name = NEW.student_name
          AND mid.room_name    = NEW.room_name
          AND mid.action       = 'clear'
          AND mid.created_at   > v_assign_time
          AND mid.created_at   < v_clear_time
          AND mid.id           != NEW.id
    ) THEN
        RETURN NEW; -- 中间有断点，此 assign 已被消费
    END IF;

    -- FIX-41：始终从时间戳计算，废弃 practice_duration 字段
    v_duration_seconds := EXTRACT(EPOCH FROM (v_clear_time - v_assign_time))::INTEGER;

    -- FIX-51B：不足 5 分钟时，主动删除已有的错误记录（旧数据污染修复）
    -- 旧行为是静默返回，遗留历史脏数据；新行为主动清理再返回
    IF v_duration_seconds < 300 THEN
        DELETE FROM public.practice_sessions
        WHERE student_name = NEW.student_name
          AND session_start = v_assign_time;
        RETURN NEW;
    END IF;

    -- 时长分级处理（FIX-24 规则）
    IF v_duration_seconds > 10800 THEN        -- > 180 分钟
        v_cleaned_duration := 120;
        v_is_outlier       := TRUE;
        v_outlier_reason   := 'too_long';
    ELSIF v_duration_seconds > 7200 THEN      -- 120~180 分钟
        v_cleaned_duration := 120;
        v_is_outlier       := FALSE;
        v_outlier_reason   := 'capped_120';
    ELSE
        v_cleaned_duration := ROUND(v_duration_seconds / 60.0)::INTEGER;
        v_is_outlier       := FALSE;
        v_outlier_reason   := NULL;
    END IF;

    -- FIX-50：饭点峰值时刻检测（12:10 午饭 / 18:10 晚饭，周三不判晚饭）
    v_start_bjt  := v_assign_time AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Shanghai';
    v_end_bjt    := v_clear_time  AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Shanghai';
    v_start_time := v_start_bjt::TIME;
    v_end_time   := v_end_bjt::TIME;
    v_dow        := EXTRACT(DOW FROM v_start_bjt)::INTEGER;

    v_spans_meal_break := (
        -- 午饭峰值时刻 12:10（周一至周五，DOW 1-5）
        (v_dow BETWEEN 1 AND 5
            AND v_start_time < '12:10:00'::TIME
            AND v_end_time   > '12:10:00'::TIME)
        OR
        -- 晚饭峰值时刻 18:10（周一/二/四/五，周三不判定，DOW 1,2,4,5）
        (v_dow IN (1, 2, 4, 5)
            AND v_start_time < '18:10:00'::TIME
            AND v_end_time   > '18:10:00'::TIME)
    );

    -- 饭点升级逻辑（too_long 最高优先级，不被降级）
    IF v_spans_meal_break AND v_outlier_reason != 'too_long' THEN
        v_is_outlier     := TRUE;
        v_outlier_reason := 'meal_break';
        -- capped_120 升级为 meal_break 时 cleaned_duration 不变（仍为120）
    END IF;

    INSERT INTO public.practice_sessions (
        student_name, student_major, student_grade,
        room_name, piano_type,
        session_start, session_end,
        raw_duration, cleaned_duration,
        is_outlier, outlier_reason, created_at
    ) VALUES (
        NEW.student_name, NEW.student_major, NEW.student_grade,
        NEW.room_name, NEW.piano_type,
        v_assign_time, v_clear_time,
        ROUND(v_duration_seconds / 60.0)::INTEGER,
        v_cleaned_duration,
        v_is_outlier,
        v_outlier_reason,
        NOW()
    )
    ON CONFLICT (student_name, session_start) DO UPDATE SET
        session_end      = EXCLUDED.session_end,
        raw_duration     = EXCLUDED.raw_duration,
        cleaned_duration = EXCLUDED.cleaned_duration,
        is_outlier       = EXCLUDED.is_outlier,
        outlier_reason   = EXCLUDED.outlier_reason;

    RETURN NEW;
END;
$$;
```

**已绑定触发器**：
```sql
-- 确认绑定（无需重建，只要函数名对即可）
SELECT trigger_name, action_statement
FROM information_schema.triggers
WHERE event_object_table = 'practice_logs' AND trigger_name = 'trg_insert_session';
```

**前端配合修复（2026-03-12，index.html）**：
此前 `clearRoom` 函数在写日志前执行了 `optimisticClear()`，导致 `room.registerTime` 被提前清空为 `null`，进而导致写入 `practice_logs` 的 `clear` 记录缺少 `session_start` 字段，触发器无法配对。
修复方案：在调用 `optimisticClear` 前先将 `row.registerTime` 保存到 `originalStartTime` 变量，并通过 `{ startMs: originalStartTime }` 显式传给 `writePracticeLog`。

---

### ✅ 修复一：删除旧版触发器 `trg_sync_practice_session`【高危，已修复】

**问题描述**：`practice_logs` 表上同时存在新旧两个触发器，都往 `practice_sessions` 写入数据：
- `trg_insert_session` → `trigger_insert_session()`（新版，已修复3个已知Bug）
- `trg_sync_practice_session` → `fn_sync_practice_session()`（旧版，含已知Bug）

PostgreSQL 按触发器名字母顺序执行，旧版在后执行，**覆盖**了新版的修复结果。

**修复操作**：
```sql
DROP TRIGGER IF EXISTS trg_sync_practice_session ON public.practice_logs;
```

**修复后验证**（practice_logs INSERT 触发器只剩两个）：
```
trg_baseline_update  → trigger_update_baseline()   ✅
trg_insert_session   → trigger_insert_session()    ✅
```

---

### ✅ 修复二：`trigger_compute_student_score` 加入批量任务跳过逻辑【中危，已修复】

**问题描述**：`backfill_score_history` 和 `run_weekly_score_update` 批量运行时设置了 `app.skip_score_trigger = 'on'`，但 `trigger_compute_student_score` 从未读取该配置，导致批量写入 `student_baseline` 时每行都额外触发一次 `compute_student_score`，影响性能并可能产生中间状态的分数数据。

**修复操作**：
```sql
CREATE OR REPLACE FUNCTION public.trigger_compute_student_score()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    -- 防止触发器递归（深度超过1时跳过）
    IF pg_trigger_depth() > 1 THEN
        RETURN NEW;
    END IF;

    -- 批量任务（backfill / run_weekly_score_update）期间跳过
    IF current_setting('app.skip_score_trigger', true) = 'on' THEN
        RETURN NEW;
    END IF;

    PERFORM public.compute_student_score(NEW.student_name);
    RETURN NEW;
END;
$$;
```

**修复后验证**：函数定义中已包含 `app.skip_score_trigger` 检查逻辑 ✅

---

### ℹ️ 清理建议：`fn_trigger_compute_student_score` 为未挂载死代码

该函数存在但没有绑定任何触发器（实际运行的是 `trigger_compute_student_score`）。
不影响功能，可选择性删除：
```sql
-- 先确认无绑定
SELECT trigger_name FROM information_schema.triggers
WHERE action_statement LIKE '%fn_trigger_compute_student_score%';
-- 若返回空，可安全删除：
DROP FUNCTION IF EXISTS public.fn_trigger_compute_student_score();
```

---

## 八、修复后的完整触发器链路（已验证 2026-03-11）

```
【practice_logs INSERT】
         │
         └─► trg_insert_session → trigger_insert_session()   ← 唯一入口（trg_baseline_update 已删除）
                 ↓ INSERT INTO practice_sessions（或 ON CONFLICT DO UPDATE）
         【practice_sessions INSERT 或 UPDATE】  ✅FIX-21
                 ↓
         trg_update_baseline → trigger_update_student_baseline()
                 实时有效记录数决定触发频率（冷启动/CV/天数）✅FIX-9
                 → update_student_baseline → compute_baseline_as_of
                 ↓ UPSERT student_baseline

         【student_baseline UPDATE】
                 ↓
         trg_compute_score_on_baseline_update → trigger_compute_student_score()
                 ├─ pg_trigger_depth() > 1          → 跳过（防递归）
                 ├─ app.skip_score_trigger = 'on'   → 跳过（批量任务保护）✅FIX-2
                 └─ 正常情况 → compute_student_score
                         ├─ 停琴 > 30 天              → 冻结分数，写入冻结快照 ✅FIX-12
                         ├─ 本周无练琴记录            → 写 0 占位（DO NOTHING），返回 ✅FIX-15
                         └─ 本周有练琴                → 正常重算，写入 student_score_history
                                                        snapshot_date = 本周一 ✅FIX-14
                                                        ON CONFLICT DO UPDATE（覆盖更新）

【run_weekly_score_update（每周一 00:05）】
         └─ 无练琴学生 → 写 0 分缺席快照（DO NOTHING）✅FIX-13/FIX-18
            （有练琴学生由触发链实时处理，PERCENT_RANK 已废弃）✅FIX-18
```

---

## 九、当前状态总览（2026-03-11 全量修复后）

| 项目 | 状态 | 修复版本 |
|------|------|---------|
| `update_student_baseline` 存在性 | ✅ 正常（`compute_baseline_as_of` 的两层封装）| — |
| `trg_sync_practice_session` 旧版触发器 | ✅ 已删除 | 触发器修复 |
| `trigger_compute_student_score` 批量保护 | ✅ 已加入 `skip_score_trigger` 检查 | 触发器修复 |
| `clean_duration` 冷启动/std 保护 | ✅ 已修复 | FIX-1 |
| `compute_baseline_as_of` alpha CV化 | ✅ 已修复 | FIX-2 |
| `compute_baseline_as_of` std 保护 | ✅ 已修复 | FIX-2 |
| `compute_baseline_as_of` last_updated 未来时间 | ✅ 已修复 | FIX-2 |
| `compute_baseline` 代码去重 | ✅ 改为薄封装 | FIX-3 |
| `trg_baseline_update` 双触发器路径 | ✅ 已删除，链路唯一化 | FIX-4 |
| `compute_student_score` B 维度分母 | ✅ 改为固定系数 0.3 | FIX-5 |
| `compute_student_score` A 维度 IQR | ✅ 优先同专业，不足回落全体 | FIX-5 |
| `compute_student_score_as_of` 同步修复 | ✅ 已同步 B/A 维度 | FIX-6 |
| `backfill_score_history` 异常捕获 | ✅ 单学生失败不中断 | FIX-7 |
| `backfill_score_history` PERCENT_RANK 保护 | ✅ < 5 人时用原始分 | FIX-7 |
| `run_weekly_score_update` 分数倒退 | ✅ 已修复，额外归一化当前 baseline | FIX-8 |
| `trigger_update_student_baseline` 计数基准 | ✅ 改为实时有效记录数 | FIX-9 |
| 数据完整性约束 | ✅ 已添加 alpha/score/duration 范围约束 | FIX-10 |
| `v_baseline_health` 监控视图 | ✅ 已创建 | FIX-10 |
| `debug_weight_conf_as_of` 历史调试 | ✅ 已创建 | FIX-10 |
| **停琴检测**（>30 天无 session 冻结分数、置信度衰减、写冻结快照）| ✅ 已加入 `compute_student_score` | FIX-12 |
| **零分制周快照**（无练琴学生写 0、不参与 PERCENT_RANK）| ✅ `run_weekly_score_update` + `backfill` | FIX-13 |
| **废弃 PERCENT_RANK，composite_score 改为实时 raw_score × 100** | ✅ `run_weekly_score_update` 大幅简化 | FIX-18 |
| **快照日期统一**（`compute_student_score` 使用本周一而非 `CURRENT_DATE`）| ✅ 每周每生只有一行快照 | FIX-14 |
| **本周无练琴保护**（触发器误触发时 `DO NOTHING`，不覆盖 0 分快照）| ✅ `compute_student_score` 内置检查 | FIX-15 |
| **缺席周快照污染 B/T/M**（0 分快照被误当真实表现参与趋势/进步计算）| ✅ 所有三维均加 `raw_score > 0` 过滤 | FIX-16 |
| **评分模型更强调个人变化**（降低 A 权重、置信度只看有效练琴周）| ✅ 实时版/回溯版已统一 | FIX-17 |
| **评分动态化：B 1v1、T 3周、新增 W 本周进度分、五维权重** | ✅ 每次练完即实时影响排名 | FIX-20 |
| **`trg_update_baseline` 改为 INSERT OR UPDATE**（auto_clear 后次日归还不触发基线的问题）| ✅ 已修复 | FIX-21 |
| **基线统计排除周六周日，只统计工作日（周一~周五）** | ✅ 6 个函数统一加 DOW NOT IN (0,6) 过滤 | FIX-19 |
| **触发器函数缺少 SECURITY DEFINER，导致长时练琴 clear 无法写入 `practice_logs`** | ✅ 4 个触发器函数已加 SECURITY DEFINER | FIX-22 |
| **W 分仅在前端计算，无法持久化存储** | ✅ `student_baseline.w_score` 列 + `compute_and_store_w_score` 函数，每次练完后端实时写入 | FIX-23 |
| **W 分防刷分（30分钟基数门槛）+ 超长练琴截断阈值调整（120~180min不判异常，>180min判异常）** | ✅ `compute_and_store_w_score` + `trigger_insert_session` + `clean_duration` 全部更新 | FIX-24 |
| **历史旧记录中 130~180min 被错误标记为异常**（旧阈值 >130min 判异常，新阈值 >180min）| ✅ UPDATE `practice_sessions` 修正 `is_outlier`，并重算基线 | FIX-24b |
| **`compute_student_score` 变量名 `growth_velocity` 与列名歧义导致全量重算报错** | ✅ 局部变量重命名为 `v_growth_velocity`，完整函数已部署 | FIX-25 |
| **`compute_and_store_w_score` 单位错误（除两次 60）+ 时区偏移（周一 00:00 BJT 被误算为 08:00 BJT），导致所有学生 W 分常驻 ≈ 0.182、与练琴量完全无关** | ✅ 删除多余 `/60.0`；`v_week_start` 改用 `AT TIME ZONE` 正确转换 | FIX-26 |
| **`compute_student_score` 的 `v_week_monday::TIMESTAMPTZ` 使用 UTC session 时区，导致：① 周一 00:00~07:59 BJT 练琴被误判为「本周未练」并写入 0 分快照；② W 维度 `v_weekly_minutes` 同时漏统计同段时间的练琴** | ✅ 新增 `v_week_start_bjt TIMESTAMPTZ`，用 `AT TIME ZONE 'Asia/Shanghai'` 正确转换，替换两处 `::TIMESTAMPTZ` 引用 | FIX-27 |
| `fn_trigger_compute_student_score` 死代码 | ℹ️ 存在但无害，可选择性删除 | — |

**验证触发器链路**（2026-03-16 已确认）：

| 表 | 触发器 | 触发时机 | 函数 | SECURITY DEFINER |
|----|--------|----------|------|-----------------|
| `practice_logs` | `trg_insert_session` | INSERT | `trigger_insert_session()` | ✅ FIX-22 |
| `practice_sessions` | `trg_update_baseline` | **INSERT OR UPDATE** ✅FIX-21 | `trigger_update_student_baseline()` | ✅ FIX-22 |
| `student_baseline` | `trg_compute_score_on_baseline_update` | UPDATE | `trigger_compute_student_score()` | ✅ FIX-22 |
| （被链路调用）| — | — | `compute_student_score()` | ✅ FIX-22 ✅ FIX-27（时区修复）|
| （被链路调用）| — | — | `compute_and_store_w_score()` | ✅ FIX-23（新增）✅ FIX-26（修复）|

---

### FIX-21 ✅ `trg_update_baseline` 改为 INSERT OR UPDATE（2026-03-16）

**问题根因**：`auto_clear_open_sessions`（每晚 21:35 BJT）在学生未归还时会提前写入 `practice_sessions` 合成记录。次日学生正式归还时，`trigger_insert_session` 触发 `ON CONFLICT DO UPDATE`——这是一次 **UPDATE**，而原 `trg_update_baseline` 只监听 **INSERT**，导致 `student_baseline` 和 `student_score_history` 无法自动刷新。

**修复操作**：
```sql
DROP TRIGGER IF EXISTS trg_update_baseline ON public.practice_sessions;

CREATE TRIGGER trg_update_baseline
AFTER INSERT OR UPDATE ON public.practice_sessions
FOR EACH ROW
EXECUTE FUNCTION trigger_update_student_baseline();
```

**影响说明**：
- 当天正常还卡（新 INSERT）：行为不变 ✅
- auto_clear 后次日还卡（ON CONFLICT UPDATE）：现在可正确触发基线刷新 ✅
- `trigger_update_student_baseline` 内部有节流逻辑，UPDATE 触发不会造成性能问题 ✅

---

*最后更新：2026-03-16（FIX-21：trg_update_baseline 改为 INSERT OR UPDATE，修复 auto_clear 后次日归还不触发基线更新的问题）*

---

### FIX-22 ✅ 触发器函数加 SECURITY DEFINER，修复长时练琴 clear 不写入 `practice_logs`（2026-03-16）

**问题现象**：从 `index.html` 归还琴房时，短时练琴（< 5 分钟）的 clear 记录能正常写入 `practice_logs`，但 ≥ 5 分钟的长时练琴 clear 记录始终无法写入，用户控制台出现：
```
new row violates row-level security policy for table "student_score_history"
Failed to load https://...supabase.co/rest/v1/practice_logs — 401 Unauthorized
```

**根本原因（触发器链路事务回滚）**：

1. `practice_logs` INSERT → 触发 `trg_insert_session`（`trigger_insert_session()`）
2. `trigger_insert_session` 内有 `cleaned_duration < 300` 提前返回逻辑：
   - **< 5 分钟**：直接 `RETURN NEW`，不写 `practice_sessions`，链路在此中断 → `practice_logs` 写入成功 ✅
   - **≥ 5 分钟**：继续向 `practice_sessions` 写入，触发 `trg_update_baseline`
3. `trg_update_baseline` → `trigger_update_student_baseline()` → 更新 `student_baseline`
4. `student_baseline` UPDATE → `trg_compute_score_on_baseline_update` → `trigger_compute_student_score()`
5. `trigger_compute_student_score()` 调用 `compute_student_score()`，后者尝试 INSERT 到 `student_score_history`
6. **`anon` 角色被 RLS 策略禁止向 `student_score_history` 写入 → 触发 RLS 异常**
7. 整个数据库事务（从第 1 步开始）**全部回滚** → `practice_logs` 的 INSERT 也被撤销

**为什么有 401 错误**：Token 过期导致偶发，但即使 Token 有效，RLS 事务回滚仍会阻止写入。两者独立存在。

**修复方案**：为 4 个触发器相关函数加 `SECURITY DEFINER`，使其以函数 owner（postgres/超级用户）权限执行，绕过 `anon` 角色的 RLS 限制：

```sql
-- 修复1：compute_student_score — 负责写 student_score_history，是 RLS 直接触发点
ALTER FUNCTION public.compute_student_score(text) SECURITY DEFINER;

-- 修复2：trigger_update_student_baseline — 更新 student_baseline
ALTER FUNCTION public.trigger_update_student_baseline() SECURITY DEFINER;

-- 修复3：trigger_compute_student_score — 触发 compute_student_score
ALTER FUNCTION public.trigger_compute_student_score() SECURITY DEFINER;

-- 修复4：trigger_insert_session — 最上游入口，写 practice_sessions
ALTER FUNCTION public.trigger_insert_session() SECURITY DEFINER;
```

**验证方式**：
```sql
SELECT proname, prosecdef
FROM pg_proc
WHERE proname IN (
  'compute_student_score',
  'trigger_update_student_baseline',
  'trigger_compute_student_score',
  'trigger_insert_session'
)
AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');
-- 预期：4 行全部 prosecdef = true
```

**修复后效果**：
- ≥ 5 分钟的长时练琴 clear 记录能正常写入 `practice_logs` ✅
- 触发器链路（baseline → score_history）继续正常执行，不再因 RLS 回滚事务 ✅
- `anon` 角色本身的 RLS 策略不变，仅触发器函数内部以 owner 权限执行 ✅

### FIX-23 ✅ W 分后端持久化：`student_baseline.w_score` + `compute_and_store_w_score`（2026-03-16）

**问题根因**：W（本周进度分）原先只在前端 JavaScript 临时计算并展示，每次打开学生详情面板时向 `practice_sessions` 发一次 API 请求重算，不存储到数据库。导致：
- W 分无法在后端参与排名分的持久化记录
- 页面初次加载时 W 卡片先显示"计算中…"，有延迟
- 后端 `compute_student_score` 已把 W 算入 `composite_score`，但前端展示的 W 值与后端计算的值来源不同，存在潜在偏差

**修复方案**：在 `student_baseline` 增加 `w_score` 列，每次触发器链路计算完评分后，同步把 W 分写入该列，前端直接读取。

**步骤 1：加列（使用 FLOAT8 避免 JSON 字符串问题）**
```sql
ALTER TABLE public.student_baseline
ADD COLUMN IF NOT EXISTS w_score FLOAT8;
```
> ⚠ 列类型必须为 `FLOAT8`（double precision），不能用 `NUMERIC`。Supabase REST API 对 `NUMERIC` 类型会以 JSON **字符串**返回（`"0.182..."`），导致前端 `toFixed(3)` 失败，W 卡片显示 `—`。`FLOAT8` 会以 JSON **数字**返回，前端直接可用。

**步骤 2：新建 `compute_and_store_w_score` 函数**
```sql
CREATE OR REPLACE FUNCTION public.compute_and_store_w_score(p_student_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_mean_duration  FLOAT8;
  v_weekly_minutes FLOAT8;
  v_elapsed_days   INT;
  v_ratio          FLOAT8;
  v_w_score        FLOAT8;
  v_dow            INT;
  v_week_start     TIMESTAMPTZ;
BEGIN
  SELECT mean_duration INTO v_mean_duration
  FROM public.student_baseline
  WHERE student_name = p_student_name;

  v_week_start := (DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE)::TIMESTAMPTZ;

  SELECT COALESCE(SUM(cleaned_duration) / 60.0, 0) INTO v_weekly_minutes
  FROM public.practice_sessions
  WHERE student_name = p_student_name
    AND session_start >= v_week_start
    AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

  v_dow := EXTRACT(DOW FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INT;
  v_elapsed_days := CASE v_dow
    WHEN 0 THEN 0   -- 周日：本周还未开始
    WHEN 6 THEN 5   -- 周六：整周已结束
    ELSE v_dow      -- 周一=1 … 周五=5
  END;

  IF v_elapsed_days = 0 OR COALESCE(v_mean_duration, 0) <= 0 THEN
    v_w_score := 0.5;  -- 中性值（周日 or 无历史均值）
  ELSE
    -- FIX-24: 增加 W 分计算门槛，防止低基数刷分
    -- 1. 均值基数保护：如果个人日均值 < 30分钟，按 30分钟计算
    -- 2. 上限封顶：W 分最高不超过 1.2 倍满分（即 ratio > 2.0 后收益递减）
    v_ratio   := v_weekly_minutes / (GREATEST(v_mean_duration, 30.0) * v_elapsed_days);
    v_w_score := 1.0 / (1.0 + EXP(-3.0 * (v_ratio - 0.5)));
  END IF;

  -- 防止此 UPDATE 再次触发 trigger_compute_student_score，避免循环重算
  PERFORM set_config('app.skip_score_trigger', 'on', true);

  UPDATE public.student_baseline
  SET w_score = v_w_score
  WHERE student_name = p_student_name;

  PERFORM set_config('app.skip_score_trigger', 'off', true);
END;
$$;
```
> ⚠ **关键设计**：函数内更新 `student_baseline` 会触发 `trg_compute_score_on_baseline_update` → `trigger_compute_student_score` → `compute_student_score`，形成循环。通过 `set_config('app.skip_score_trigger', 'on', true)`（事务级别局部生效）跳过该触发器，避免重复计算和 `growth_velocity` 变量名歧义错误。

**步骤 3：更新 `trigger_compute_student_score`，追加调用新函数**
```sql
CREATE OR REPLACE FUNCTION public.trigger_compute_student_score()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;
  IF current_setting('app.skip_score_trigger', true) = 'on' THEN
    RETURN NEW;
  END IF;

  PERFORM public.compute_student_score(NEW.student_name);
  PERFORM public.compute_and_store_w_score(NEW.student_name);  -- FIX-23 新增
  RETURN NEW;
END;
$$;
```

**步骤 4：初始化所有学生当前 W 分**
```sql
SELECT public.compute_and_store_w_score(student_name)
FROM public.student_baseline;
```

**前端改动（dashboard.html）**：
- 删除 `updateWeekScoreCard()` 异步函数（约 40 行）
- W 维度卡片改为直接读 `s.w_score`（与 B/T/M/A 一致）
- 去掉 `showDetail()` 里 `updateWeekScoreCard()` 的调用
- 底部说明文字更新：W 分现由后端实时写入并存储

**触发器链路（更新后）**：
```
practice_logs
  → trg_insert_session
  → trigger_insert_session()               [SECURITY DEFINER, FIX-22]
  → practice_sessions INSERT/UPDATE
  → trg_update_baseline
  → trigger_update_student_baseline()      [SECURITY DEFINER, FIX-22]
  → student_baseline UPDATE
  → trg_compute_score_on_baseline_update
  → trigger_compute_student_score()        [SECURITY DEFINER, FIX-22]
      ├─ compute_student_score()           → student_score_history + student_baseline.composite_score
      └─ compute_and_store_w_score()       → student_baseline.w_score  ← FIX-23 新增
```

**验证**：
```sql
SELECT student_name, composite_score, w_score
FROM public.student_baseline
WHERE w_score IS NOT NULL
ORDER BY composite_score DESC
LIMIT 10;
-- 预期：w_score 为 0.18~1.0 的浮点数（JSON 数字，非字符串）
```

**修复后效果**：
- W 卡片与 B/T/M/A 卡片渲染方式完全一致，无异步延迟 ✅
- 每次练琴归还后，`student_baseline.w_score` 自动更新 ✅
- 前端读取直接，无额外 API 请求 ✅
- `FLOAT8` 类型确保 PostgREST 返回 JSON 数字，前端 `toFixed(3)` 正常 ✅

---

### FIX-24 ✅ W 分防刷分 + 超长练琴自动截断（2026-03-16）

**问题 1：W 分（本周进度）低基数刷分漏洞**
- 现象：平时练琴很少的学生（日均值极低，如 10 分钟），突击练一次（60 分钟），W 分瞬间爆表，甚至超过长期勤奋的学生。
- 修复：
  1. **最低门槛**：计算 W 分时，分母中的“个人日均值”最低按 **30 分钟**计算。即平日均值 < 30 分钟的学生，要想拿高分，必须按日均 30 分钟的标准来练。
  2. **公式调整**：`ratio = weekly_minutes / (MAX(mean_duration, 30) * elapsed_days)`

**问题 2：超长练琴（> 2小时）判异常打击积极性**
- 现象：学生练琴投入忘续卡，超过 2 小时（如 130 分钟），系统直接判为异常记录（`is_outlier=TRUE`），导致该次练琴完全不计分，挫败感强。
- 修复：
  1. **120~180 分钟**：截断为 120 分钟，标记 `is_outlier=FALSE`（正常有效记录，仅 `outlier_reason='capped_120'` 备注），计入总分。
  2. **> 180 分钟**：截断为 120 分钟，标记 `is_outlier=TRUE`，`outlier_reason='too_long'`（判定为真正忘还卡，影响异常率）。

**SQL 更新内容**：

1. **更新 `compute_and_store_w_score` 函数**（防刷分逻辑）：
```sql
CREATE OR REPLACE FUNCTION public.compute_and_store_w_score(p_student_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_mean_duration  FLOAT8;
  v_weekly_minutes FLOAT8;
  v_elapsed_days   INT;
  v_ratio          FLOAT8;
  v_w_score        FLOAT8;
  v_dow            INT;
  v_week_start     TIMESTAMPTZ;
BEGIN
  SELECT mean_duration INTO v_mean_duration
  FROM public.student_baseline
  WHERE student_name = p_student_name;

  v_week_start := (DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE)::TIMESTAMPTZ;

  SELECT COALESCE(SUM(cleaned_duration) / 60.0, 0) INTO v_weekly_minutes
  FROM public.practice_sessions
  WHERE student_name = p_student_name
    AND session_start >= v_week_start
    AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

  v_dow := EXTRACT(DOW FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INT;
  v_elapsed_days := CASE v_dow
    WHEN 0 THEN 0
    WHEN 6 THEN 5
    ELSE v_dow
  END;

  IF v_elapsed_days = 0 OR COALESCE(v_mean_duration, 0) <= 0 THEN
    v_w_score := 0.5;
  ELSE
    -- FIX-24: 增加 W 分计算门槛，防止低基数刷分
    -- 1. 均值基数保护：如果个人日均值 < 30分钟，按 30分钟计算
    v_ratio   := v_weekly_minutes / (GREATEST(v_mean_duration, 30.0) * v_elapsed_days);
    v_w_score := 1.0 / (1.0 + EXP(-3.0 * (v_ratio - 0.5)));
  END IF;

  PERFORM set_config('app.skip_score_trigger', 'on', true);

  UPDATE public.student_baseline
  SET w_score = v_w_score
  WHERE student_name = p_student_name;

  PERFORM set_config('app.skip_score_trigger', 'off', true);
END;
$$;
```

2. **更新 `trigger_insert_session` 函数**（自动截断逻辑）：
```sql
CREATE OR REPLACE FUNCTION public.trigger_insert_session()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_assign_time TIMESTAMPTZ;
    v_clear_time TIMESTAMPTZ;
    v_duration_seconds INTEGER;
    v_cleaned_duration INTEGER;
    v_is_outlier BOOLEAN;
    v_outlier_reason TEXT;
BEGIN
    IF NEW.action = 'assign' THEN
        RETURN NEW;
    END IF;

    IF NEW.action != 'clear' THEN
        RETURN NEW;
    END IF;

    v_clear_time := NEW.created_at;

    SELECT created_at INTO v_assign_time
    FROM public.practice_logs
    WHERE student_name = NEW.student_name
      AND action = 'assign'
      AND created_at < v_clear_time
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_assign_time IS NULL THEN
        RETURN NEW;
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.practice_logs mid
        WHERE mid.student_name = NEW.student_name
          AND mid.action       = 'clear'
          AND mid.created_at   > v_assign_time
          AND mid.created_at   < v_clear_time
          AND mid.id           != NEW.id
    ) THEN
        RETURN NEW;
    END IF;

    v_duration_seconds := COALESCE(
        NEW.practice_duration,
        EXTRACT(EPOCH FROM (v_clear_time - v_assign_time))::INTEGER
    );

    -- 不足 5 分钟，静默丢弃
    IF v_duration_seconds < 300 THEN
        RETURN NEW;
    END IF;

    -- FIX-24（更新版）：
    -- 120~180 分钟 → 截断为 120 分钟，不判异常（忘续卡保护）
    -- > 180 分钟   → 截断为 120 分钟，判异常 too_long（真正忘还卡）
    IF v_duration_seconds > 10800 THEN
        v_cleaned_duration := 120;
        v_is_outlier := TRUE;
        v_outlier_reason := 'too_long';
    ELSIF v_duration_seconds > 7200 THEN
        v_cleaned_duration := 120;
        v_is_outlier := FALSE;
        v_outlier_reason := 'capped_120';
    ELSE
        v_cleaned_duration := ROUND(v_duration_seconds / 60.0)::INTEGER;
        v_is_outlier := FALSE;
        v_outlier_reason := NULL;
    END IF;

    INSERT INTO public.practice_sessions (
        student_name, student_major, student_grade,
        room_name, piano_type,
        session_start, session_end,
        raw_duration, cleaned_duration,
        is_outlier, outlier_reason, created_at
    ) VALUES (
        NEW.student_name, NEW.student_major, NEW.student_grade,
        NEW.room_name, NEW.piano_type,
        v_assign_time, v_clear_time,
        ROUND(v_duration_seconds / 60.0)::INTEGER,
        v_cleaned_duration,
        v_is_outlier,
        v_outlier_reason,
        NOW()
    )
    ON CONFLICT (student_name, session_start) DO UPDATE SET
        session_end      = EXCLUDED.session_end,
        raw_duration     = EXCLUDED.raw_duration,
        cleaned_duration = EXCLUDED.cleaned_duration,
        is_outlier       = EXCLUDED.is_outlier,
        outlier_reason   = EXCLUDED.outlier_reason;

    RETURN NEW;
END;
$$;
```

**验证**：
1. **防刷分**：找一个日均值很低（如 10 分钟）的学生，手动插入一条 60 分钟的练琴记录，检查其 W 分是否不再爆表（应按 30 分钟基数计算，ratio = 60 / (30 * days) = 2.0 / days，而非 6.0 / days）。
2. **自动截断**：手动插入一条 150 分钟的练琴记录（assign 和 clear 间隔 2.5 小时），检查 `practice_sessions` 表中该记录的 `cleaned_duration` 是否为 120，且 `is_outlier` 为 `FALSE`。

---

### FIX-24b ✅ 历史旧记录 `is_outlier` 修正（2026-03-16）

**背景**：旧版 `trigger_insert_session` 在 7800 秒（130 分钟）即判断 `is_outlier = TRUE`，FIX-24 将阈值调整为 10800 秒（180 分钟）。因此数据库中**已存在的** 130~180 分钟练琴记录仍然被标记为 `is_outlier = TRUE`，会被 `compute_baseline_as_of` 纳入异常率统计，仍然受到处罚。

**`compute_baseline_as_of` 异常率计算方式**（已确认，读取 `practice_sessions.is_outlier` 字段，不调用 `clean_duration` 函数）：
```sql
SELECT AVG(CASE WHEN is_outlier THEN 1.0 ELSE 0.0 END)  -- 直接读 is_outlier
INTO v_outlier_rate
FROM (
    SELECT is_outlier FROM public.practice_sessions
    WHERE student_name = p_student_name ...
    LIMIT 30
) recent;
```
> 因此，`trigger_insert_session` 写入的 `is_outlier` 值是决定异常率的**唯一来源**，历史记录必须手动修正。

**修复 SQL**（需在 Supabase SQL Editor 中执行）：
```sql
-- 步骤1：查看受影响记录数（确认数量合理再执行步骤2）
SELECT COUNT(*) AS affected_count,
       MIN(raw_duration) AS min_min,
       MAX(raw_duration) AS max_min
FROM public.practice_sessions
WHERE raw_duration > 120
  AND raw_duration <= 180
  AND is_outlier = TRUE;

-- 步骤2：修正历史记录（130~180 分钟：取消异常标记）
UPDATE public.practice_sessions
SET is_outlier     = FALSE,
    outlier_reason = 'capped_120'
WHERE raw_duration > 120
  AND raw_duration <= 180
  AND is_outlier = TRUE;

-- 步骤3：重算基线（让 outlier_rate 使用修正后的数据）
SELECT public.recompute_all_baselines();

-- 步骤4：重算历史评分快照
SELECT public.backfill_score_history();

-- 步骤5：重算当前 W 分
SELECT public.compute_and_store_w_score(student_name)
FROM public.student_baseline;
```

**修复后效果**：
- 130~180 分钟练琴记录的 `is_outlier` 改为 `FALSE` ✅
- `outlier_rate` 重算后不再含这部分"假异常" ✅
- 受影响学生的 `alpha`、`outlier_penalty`、`composite_score` 全部得到修正 ✅

---

### FIX-25 ✅ `compute_student_score` 变量名 `growth_velocity` 歧义修复（2026-03-16）

**问题根因**：`compute_student_score` 函数在 DECLARE 段声明了局部变量 `growth_velocity FLOAT := 0`，而 `student_baseline` 表也有同名列。在以下 UPDATE 语句中：
```sql
UPDATE public.student_baseline
SET growth_velocity = growth_velocity  -- PostgreSQL 无法区分左列名 vs 右变量名
WHERE student_name = p_student_name;
```
PostgreSQL 报错：`ERROR: 42702: column reference "growth_velocity" is ambiguous`

该错误在每次触发器链路调用 `compute_student_score` 时都会发生，导致全量重算（`recompute_all_baselines` → `compute_student_score`）完全无法执行。

**修复方案**：将局部变量重命名为 `v_growth_velocity`，UPDATE 右侧使用 `v_growth_velocity`。

修改了以下 3 处：
1. `DECLARE` 段：`growth_velocity FLOAT := 0` → `v_growth_velocity FLOAT := 0`
2. Velocity 计算块：`growth_velocity := COALESCE(-slope4, 0)` → `v_growth_velocity := COALESCE(-slope4, 0)`
3. UPDATE 语句：`growth_velocity = growth_velocity` → `growth_velocity = v_growth_velocity`

**修复后验证**：
```sql
-- 应成功返回 composite_score 和 weight_conf，不再报歧义错误
SELECT * FROM public.compute_student_score('测试学生姓名');

-- 全量重算应正常完成
SELECT public.recompute_all_baselines();
```

---

## 十、系统深度分析与优化（2026-03-10）

> 完整修复补丁见：`baseline_fixes_v1.sql`，在 Supabase SQL Editor 中按顺序执行即可。

---

### FIX-1 ✅ `clean_duration` — 冷启动保护 + std=0/NULL 保护

**问题**：
- `record_count < 10` 时 `std=NULL`，导致个人离群检测完全跳过，任何时长都能通过
- `std=0`（所有记录相同）时，`mean + 3×0 = mean`，所有高于均值的记录都被错误压缩

**修复逻辑**：
```
暖启动（record_count >= 10 且 std > 1.0） → 启用个人离群检测（mean + 3σ）
冷启动（否则）                           → 改用全局硬上限 180 分钟
```

---

### FIX-2 ✅ `compute_baseline_as_of` — 三处修复

**① std 保护**：`< 2` 条记录时 std 保留 NULL（无统计意义），过小时设最小值 `1.0`

**② alpha 波动项语义修正**：
| | 旧公式 | 新公式 |
|-|--------|--------|
| 波动惩罚 | `LEAST(0.15, mean相关计算)` 均值越高扣越多 | `LEAST(0.20, CV × 0.15)` CV越高扣越多 |
| 语义 | ❌ 均值高的学生被惩罚，逻辑相反 | ✅ 波动性高的学生被惩罚，正确 |

**③ `last_updated` 未来时间戳问题**：
- `p_as_of_date > CURRENT_DATE`（如传入明天）时，写入 `NOW()`
- 历史日期时，写入 `p_as_of_date`（保留历史快照语义）

---

### FIX-3 ✅ `compute_baseline` — 改为薄封装，消除代码重复

```sql
-- 修复前：compute_baseline 与 compute_baseline_as_of 代码完全重复（~100行）
-- 修复后：
CREATE OR REPLACE FUNCTION public.compute_baseline(p_student_name TEXT) ...
  PERFORM public.compute_baseline_as_of(p_student_name, (CURRENT_DATE + 1)::DATE);
```
**效果**：修改计算逻辑只需改 `compute_baseline_as_of` 一处，`compute_baseline` 自动同步。

---

### FIX-4 ✅ 删除双触发器路径 `trg_baseline_update`

**问题**：一次练琴结束同时触发两条基线计算路径，同一事务内计算两次，存在竞态风险。

```
路径1（已删除）：practice_logs → trg_baseline_update（每5条）→ compute_baseline
路径2（保留）  ：practice_logs → practice_sessions → trg_update_baseline（动态）→ compute_baseline
```
保留路径2的理由：基于已清洗的 `practice_sessions` 触发，语义更准确。

---

### FIX-5 & FIX-6 ✅ `compute_student_score` / `compute_student_score_as_of` — B 维度 + A 维度

**B 维度（基线进步）分母修正**：
| | 旧 | 新 |
|-|-----|-----|
| 公式 | `/ GREATEST(hist_score_early, 0.01)` | `/ 0.3`（固定归一化系数）|
| 问题 | 早期分≈0 时，微小进步被放大为满分 | 典型有意义进步幅度为 0.3，归一化合理 |

**A 维度（积累）IQR 计算范围修正**：
| | 旧 | 新 |
|-|-----|-----|
| 参照群体 | 全体学生（跨专业混算）| 优先同专业（不足5人时回落全体）|
| 问题 | 钢琴 vs 声乐时长分布差异大，IQR 失真 | 同专业比较更公平 |

**M 维度（动量）**：经核查，代码已使用 `raw_score`（非 `composite_score`），此问题不存在。

---

### FIX-7 ✅ `backfill_score_history` — 异常捕获 + PERCENT_RANK 人数保护

**① 异常捕获**：每个学生的计算用 `BEGIN/EXCEPTION` 包裹，单个学生数据异常不中断整体回溯，输出 WARNING 日志继续下一位。

**② PERCENT_RANK 人数保护**：
```
学生数 >= 5 → PERCENT_RANK 归一化
学生数 < 5  → 直接用 raw_score × 100，跳过归一化（避免 0/100 的极端值）
```

---

### FIX-8 ✅ `run_weekly_score_update` — 修复成长分倒退问题

**问题**：周任务用"本周一"历史快照覆盖实时触发器写入的当前分数，导致成长分倒退。

**修复**：周任务在写完历史快照后，额外步骤基于当前最新 `raw_score` 做一次全局归一化，直接更新 `student_baseline.composite_score`，确保 baseline 始终反映最新状态。

---

### FIX-9 ✅ `trigger_update_student_baseline` — 实时计数修复

**问题**：触发间隔由 `v_record_count`（baseline 表中上次计算时的值，可能过时）决定，但模运算用的是实时计数，两者基准不一致。

**修复**：增加 `v_live_count`（实时查询 `practice_sessions` 中有效记录数），同时用于决定触发间隔和做模运算，保证一致性。

---

### FIX-10 ✅ 数据完整性约束 + 监控视图 + 历史调试函数

**数据约束**：
```sql
student_baseline:      alpha ∈ [0.5,1.0]，outlier_rate ∈ [0,1]，mean_duration ≥ 0
student_score_history: raw_score ∈ [0,1]，composite_score ∈ [0,100]
```

**监控视图** `v_baseline_health`：
```sql
SELECT * FROM public.v_baseline_health;
-- 返回：学生总数、冷启动数、7/14天未更新数、均值alpha、均值置信度等
```

**历史调试函数** `debug_weight_conf_as_of(student, date)`：
```sql
-- 可调试历史某周的置信度计算过程（原 debug_weight_conf 只能看当前状态）
SELECT * FROM public.debug_weight_conf_as_of('张三', '2025-10-01');
```

---

### FIX-11（已跳过，保留编号）

---

### FIX-12 ✅ 停琴检测（compute_student_score）

**插入位置**：在 `compute_student_score` 内，**① 读取基线之后、② IQR 统计之前**，增加早退分支。

**逻辑**：
- 查询该学生最近一条 `practice_sessions.session_start`，计算距今天数 `v_days_inactive`；无记录时视为 9999 天。
- 若 `v_days_inactive > 30`：
  - **分数**：不重算，沿用当前 `r.composite_score` 作为冻结分。
  - **置信度**：`conf_frozen = conf_last × e^(-0.005 × (days - 30))`，并限制在 [0.05, 1.0]。
  - **基线表**：仅更新 `score_confidence`、`last_updated`。
  - **历史表**：仍以 `CURRENT_DATE` 写入一条冻结快照（沿用当前 baseline 的 B/T/M/A、raw、composite），保证 `run_weekly_score_update` 按周 PERCENT_RANK 时**不断档**。

**置信度衰减公式**（下限 0.05）：

| 停琴天数 | 衰减系数 e^(-0.005×(days-30)) | 若原置信度 0.88 |
|---------|-------------------------------|------------------|
| 30 天（刚触发） | 1.000 | 0.880 |
| 60 天 | 0.861 | 0.758 |
| 90 天 | 0.741 | 0.652 |
| 120 天 | 0.638 | 0.562 |
| 180 天 | 0.472 | 0.416 |
| 365 天 | 0.160 | 0.141 |
| 兜底 | — | **0.050**（不会到零）|

**与 `run_weekly_score_update` 的关系**：停琴学生不再重算四维分，但**仍写入本周冻结快照**，因此周任务中「按 snapshot_date 做 PERCENT_RANK」时该学生仍参与当周排名，不会出现历史表断档；老师可通过 `score_confidence` 持续衰减判断「分数越来越旧」。

**实现文件**：`baseline_fixes_v1.sql` 中 FIX-5 段已含 FIX-12；单独增量见 `baseline_fix_inactive.sql`。

---

---

### FIX-13 ✅ 零分制周快照（run_weekly_score_update + backfill_score_history）

**问题**：`run_weekly_score_update` 每周对全部学生重跑 `PERCENT_RANK`，即使某学生本周无练琴，其百分位排名也因其他学生分数变化而漂移，出现"没练习却涨分/跌分"的虚假结果。

**修复逻辑**：

| 情况 | 旧行为 | 新行为 |
|------|--------|--------|
| 本周有练琴记录 | 重算，参与 PERCENT_RANK | 重算，参与 PERCENT_RANK ✅ |
| 本周无练琴记录 | 重算旧数据，随排名漂移 ❌ | 写 0 分快照，不参与排名 ✅ |
| >30 天未练 | FIX-12 冻结 | FIX-12 冻结 ✅ |

**影响范围**：`run_weekly_score_update`、`backfill_score_history`（两者均已同步修复）

**实现文件**：`fix13_apply_and_rebuild.sql` → `fix15_week_aware_score.sql`（最新版）

---

### FIX-14 ✅ 快照日期统一（compute_student_score）

**问题**：`compute_student_score`（实时触发版）使用 `CURRENT_DATE` 写快照，导致：
- 学生周三练琴 → 写入 `2026-03-11`（周三）的快照
- 周任务写的是 `2026-03-09`（周一）
- 同一周在 `student_score_history` 产生两行，Dashboard 全部显示

**修复**：将两处 `CURRENT_DATE` 改为 `DATE_TRUNC('week', CURRENT_DATE)::DATE`（本周一）。

```sql
-- 修复前
p_student_name, CURRENT_DATE, ...

-- 修复后（FIX-14）
v_week_monday := DATE_TRUNC('week', CURRENT_DATE)::DATE;
p_student_name, v_week_monday, ...
```

**效果**：实时触发和周任务都写到同一行（本周一），`ON CONFLICT DO UPDATE` 保证同一周最新计算结果始终覆盖旧值，每学生每周只有一行快照。

**同步修复**：FIX-12 停琴检测中的历史表写入也同步改为 `v_week_monday`。

**实现文件**：`fix14_weekly_snapshot_date.sql`

---

### FIX-15 ✅ 本周无练琴保护（compute_student_score）

**问题根因（三层触发链）**：
```
backfill 正确写 0（正确）
    ↓
backfill 结束后 app.skip_score_trigger 恢复 'off'（旧版在结束前恢复）
    ↓
STEP 4: UPDATE student_baseline 触发 trg_fn_compute_score_on_baseline_update
    ↓
compute_student_score 运行（学生仅 3 天没练，< 30 天 FIX-12 不拦截）
    ↓
ON CONFLICT DO UPDATE → 写 97，覆盖了 0 ← 根本问题
```

**修复方案**（双重保护）：

**① `compute_student_score` 内部检查**（FIX-15 核心）：
```sql
-- 本周是否有练琴记录
SELECT EXISTS (
    SELECT 1 FROM practice_sessions
    WHERE student_name = p_student_name
      AND cleaned_duration > 0
      AND session_start >= v_week_monday::TIMESTAMPTZ
) INTO v_has_session_this_week;

IF NOT v_has_session_this_week THEN
    -- 写 0 占位（DO NOTHING 绝不覆盖已有数据）
    INSERT INTO student_score_history (...) VALUES (..., 0, 0, NULL...)
    ON CONFLICT DO NOTHING;
    RETURN QUERY SELECT 0, 0.0;
    RETURN;
END IF;
```

**② `backfill_score_history` 的 baseline 同步提前到触发器关闭期间执行**：
```sql
-- 触发器仍处于关闭状态，防止 UPDATE 触发 compute_student_score 覆盖快照
UPDATE student_baseline SET composite_score = latest.composite_score FROM (...);
-- 然后才恢复触发器
PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
```

**实现文件**：`fix15_week_aware_score.sql`（同时包含 FIX-13/14/15 最终版）

---

---

### FIX-16 ✅ 排除缺席周快照污染 B/T/M 计算（compute_student_score）

**问题**：FIX-13 为无练琴的周写入 `raw_score = 0` 快照。但 `compute_student_score` 在计算 B/T/M 三维时未过滤这些快照，导致：

| 维度 | 被污染的计算 | 实际效果 |
|------|------------|---------|
| B（基线进步） | `hist_score_recent` 取最新5周均值，全是0 | B ≈ 0.018，极低 |
| T（趋势） | 最近8周数据包含大量0，线性回归斜率为强负 | T ≈ 0.05，极低 |
| M（动量） | 最新快照 = 0，立即中断连续改善计数 | M = 0 |
| 权重判断 | `hist_count` 含缺席周，导致 B/T 权重虚高至 30% | 误用被污染的B/T |

**结果**：久未练琴后第一周回来，系统评分极低，不反映真实练琴表现。

**修复**：B/T/M 三维及 `hist_count`（权重决策） 查询均加 `WHERE raw_score > 0`，排除缺席周快照：
```sql
-- B：只看有练琴的快照的 raw_score 历史
WHERE student_name = p_student_name AND raw_score > 0

-- T：只对有练琴的周做线性回归
WHERE student_name = p_student_name AND raw_score > 0 ORDER BY snapshot_date DESC LIMIT 8

-- M：连续改善比较只在有练琴的周之间进行
WHERE student_name = p_student_name AND raw_score > 0 ORDER BY snapshot_date DESC LIMIT 12

-- hist_count（权重判断）：只计有练琴的快照数
COUNT(*) FILTER (WHERE raw_score > 0)
```

**FIX-17 更新**：`weight_conf` 现统一只使用 `hist_count`（有实际练琴的历史周数）计算深度，不再让缺席周虚增分数可信度。

**实现文件**：`fix16_exclude_absent_weeks.sql`（FIX-16） → `fix17_rebalance_score_model.sql`（FIX-17）

---

### FIX-17 ✅ 评分模型再平衡（更真实反映个人变化）

**背景**：FIX-16 之后，缺席周不再污染 B/T/M，但评分模型仍有两个偏差：

1. 早期阶段 A（积累量）权重过高，更像在评“练得多不多”，而不是“最近有没有变好”
2. 实时版 `compute_student_score` 的置信度仍把缺席周计入历史深度，导致长期停练学生的分数看起来比实际更“可信”

**修复**：

| 历史深度 | 旧权重 | 新权重 |
|---------|--------|--------|
| `< 4` | B10 / T10 / M10 / A70 | **B20 / T20 / M10 / A50** |
| `4~11` | B25 / T25 / M15 / A35 | **B30 / T30 / M15 / A25** |
| `>= 12` | B30 / T30 / M20 / A20 | **B35 / T30 / M20 / A15** |

**效果**：
- 新学生或恢复练琴学生，不再被“积累量”过度主导
- 成长分更强调“最近几周相对自己是否更好”
- 实时分与历史回填分口径重新统一
- `score_confidence` 更接近“这份判断到底有多少有效练琴证据支持”

**保留项**：
- `outlier_rate` 的惩罚逻辑按当前业务要求维持不变
- 停琴冻结、零分制、缺席周过滤全部保留

**实现文件**：`fix17_rebalance_score_model.sql`

---

### FIX-19 ✅ 基线统计默认排除周六周日（2026-03-13）

**背景**：音乐学院管理需要，希望评估学生的"规律工作日练琴习惯"，周末练琴属于自由时间，不纳入基线考核。

**改动范围**：

| 函数 | 改动说明 |
|------|---------|
| `compute_baseline_as_of` | 全部 6 处 `practice_sessions` 查询加工作日过滤（含冷启动群体参照） |
| `trigger_update_student_baseline` | `v_record_count` 实时计数只统计工作日记录 |
| `compute_student_score` | ① FIX-12 停琴天数判断只看最近一条**工作日**记录；② FIX-15 "本周有练琴"检查只统计工作日 |
| `compute_student_score_as_of` | 同 `compute_student_score`：FIX-15 `v_has_session_this_week` 加工作日过滤 |
| `run_weekly_score_update` | "本周未练琴"判断只看工作日 |
| `backfill_score_history` | 历史回溯中"活跃学生"判断加工作日过滤 |

**过滤条件（所有函数统一）**：
```sql
AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
-- DOW: 0=周日, 6=周六；时区转换确保北京时间正确
```

**`compute_student_score` 具体修改点（2 处）**：

① FIX-12 停琴判断——只统计工作日最近练琴时间：
```sql
-- 修改前
FROM public.practice_sessions
WHERE student_name = p_student_name;

-- 修改后 [FIX-19]
FROM public.practice_sessions
WHERE student_name = p_student_name
  AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);
```
> 意义：周末最后一次练琴不再重置"停琴计时器"，只有工作日练琴才算"有效活跃"。

② FIX-15 本周有无练琴保护——只统计工作日：
```sql
-- 修改前
AND session_start >= v_week_monday::TIMESTAMPTZ

-- 修改后 [FIX-19]
AND session_start >= v_week_monday::TIMESTAMPTZ
AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
```
> 意义：本周只在周末练过的学生，仍会写 0 分缺席快照，不参与本周成长分计算。

**B/T/M/A 四维及权重不变**：这四个维度读的是 `student_score_history`，而历史快照本身已在 `compute_baseline_as_of` 层面只用工作日数据计算，因此无需修改。

**设计决策**：
- `practice_sessions` 表中**仍然保留**周末练琴记录（真实数据不删除）
- 基线统计（均值/标准差/alpha/异常率/短时率）**只使用工作日数据**
- "本周有练琴"和"停琴天数"计算**只统计工作日**——周末仅练不算"本周活跃"
- `record_count` 字段语义变为"最近 30 条工作日有效记录数"
- `weekday_pattern` 仅含周一至周五的频次分布（DOW 0/6 字段自然为 0）

**对已有学生的影响**：
- 纯靠周末练琴的学生，其 `record_count` 会降低，可能进入冷启动
- 工作日练琴规律的学生，alpha 可信度会提升（周末噪声被过滤）
- 停琴超 30 天的判断更严格：仅周末练琴同样会触发冻结分数逻辑

**执行迁移**：修改函数后需执行完整历史重建：
```sql
SELECT public.backfill_score_history();
```

**Dashboard 同步**：
- 所有 `record_count`、`mean_duration`、`outlier_rate`、`short_session_rate`、`alpha` 的 tooltip 已更新，明确标注"仅统计工作日（周一至周五）"
- 详情面板标题由"条有效记录"改为"条工作日有效记录"

---

### 已确认不存在的问题

| 报告中的问题 | 实际情况 |
|------------|---------|
| M 维度应基于 raw_score | 代码已使用 `raw_score`，无需修复 |
| `fn_trigger_compute_student_score` 重复触发 | 该函数未挂载任何触发器，为死代码，不影响运行 |

---

### 架构层面建议（长期优化，未实现）

| 建议 | 说明 |
|------|------|
| `student_baseline` 职责拆分 | 将成长分字段迁移到单独的 `student_score_current` 表，消除循环写入 |
| `compute_student_score` 代码去重 | 类似 FIX-3，让其成为 `compute_student_score_as_of` 的薄封装（因返回类型不同，需额外设计）|
| 冷启动 group_alpha=0.82 显式化 | 已在代码注释中说明来源，可进一步提取为配置表 |
| 断点续传 backfill | 增加进度记录表，支持中断后从上次位置继续 |

---

### FIX-20 ✅ 评分模型动态化，引入 W 维度（本周进度分）（2026-03-13）

**背景**：原四维模型（B/T/M/A）全部基于历史周快照，实时性差，导致每天排名几乎固定不变。

**改动范围**：

| 维度 | 旧逻辑 | 新逻辑（FIX-20） |
|------|--------|----------------|
| B（进步分）| 最近5活跃周 vs 更早5活跃周均值 | **最近1活跃周 vs 上1活跃周**（1v1，raw_score）→ **FIX-34-A 改为最近2活跃周练琴量差值（practice_sessions）** |
| T（趋势分）| 最近8活跃周线性回归（raw_score）| **最近3活跃周线性回归（raw_score）→ FIX-33 改为工作日练琴量线性回归（practice_sessions）** |
| M（动量分）| 连续改善周数，最近12周 | 8活跃周加权改善率（raw_score）→ **FIX-34-B 改为近4活跃周练琴量达标加权比例（practice_sessions）** |
| A（底盘分）| 同专业 IQR 质量比较 | 不变 |
| **W（本周进度分）** | — | **新增**：本周工作日实际时长 / (个人均值 × 已过工作日天数)，Sigmoid 归一化 |

**W 维度公式**：
```
v_weekly_ratio = 本周工作日总练琴分钟 / (mean_duration × v_elapsed_days)
w_score        = 1 / (1 + EXP(-3.0 × (ratio - 0.5)))
                 ≈ ratio=0 → 0.18（很少练）
                 ≈ ratio=0.5 → 0.50（中等）
                 ≈ ratio=1.0 → 0.82（达到日均值，良好）
                 ≈ ratio≥2.0 → 趋近 1.0（大幅超越日均）
                 其中 v_elapsed_days：周一=1，周二=2，...，周五/六/日=5
```
> 意义：今天练够了 → W 高；本周懈怠 → W 低；每次练完立即生效  
> ⚠ 注意：原文档误写为 `sigmoid(-3.0×…)` 方向相反，已于 2026-03-16 更正。

**五维动态权重**（FIX-20 新版）：

| hist_count（仅活跃周） | w_baseline | w_trend | w_momentum | w_accum | **w_week** |
|----------------------|-----------|---------|-----------|---------|-----------|
| < 4 | 10% | 10% | 5% | 25% | **50%** |
| 4~11 | 20% | 20% | 10% | 15% | **35%** |
| ≥ 12 | 25% | 25% | 15% | 10% | **25%** |

**防循环保护（新增）**：B/T/M/hist_count 的历史查询统一加 `AND snapshot_date < v_week_monday`（实时版）或 `AND snapshot_date < p_snapshot_date`（as_of 版），防止同一周多次触发时出现自引用计算偏差。

**`compute_student_score_as_of` W 维度特殊处理**：
- `p_snapshot_date = 本周一` → 使用今天实际已过工作日天数
- `p_snapshot_date = 历史周一` → 固定使用 5 天（完整周）

**预期效果**：
- 每次练完琴，W 分立即上升，当天排名就会变化
- 新生/冷启动阶段 W 权重高达 50%，排名完全由近期表现决定
- 老生 B/T 窗口缩短（1v1 和 3 周），对最近两周的进退更敏感
- 全年无间断练习的学生 A 权重降至 10%，避免"底子好就躺赢"

**执行迁移**：
```sql
-- 步骤 1：部署两个函数（已在本文档提供完整 SQL）
-- 步骤 2：全量重算
SELECT public.backfill_score_history();
```

---

### FIX-26 ✅ `compute_and_store_w_score` 单位错误 + 时区偏移修复（2026-03-16）

**问题根因**：核查 `compute_and_store_w_score` 函数后，发现两个独立 bug 叠加，导致所有学生的 W 分（`student_baseline.w_score`）始终在 **≈ 0.182** 附近，与本周实际练琴量完全无关。

---

#### Bug 1（严重）— `cleaned_duration` 被除了两次 60，单位从分钟变成小时

**`practice_sessions.cleaned_duration` 的实际单位是分钟**（由 `trigger_insert_session` 写入：`ROUND(v_duration_seconds / 60.0)::INTEGER`）。`student_baseline.mean_duration` 是其均值，也是分钟。

旧版代码在求本周总时长时，对已经是分钟的值再除以 60：

```sql
-- ❌ 旧写法：minutes ÷ 60 = hours，与 mean_duration（分钟）单位不符
SELECT COALESCE(SUM(cleaned_duration) / 60.0, 0) INTO v_weekly_minutes
```

计算出的 `ratio = v_weekly_minutes（小时）/ (mean_duration（分钟）× elapsed_days)`，约为正确值的 **1/60**。

**后果验证**（以一位每天练 60 分钟、本周已练 5 天的学生为例）：

| 状态 | `v_weekly_minutes` | `ratio` | `w_score`（sigmoid） |
|------|-------------------|---------|----------------------|
| 有 bug | `300/60 = 5.0`（小时）| `5 / (60×5) ≈ 0.017` | **≈ 0.182**（死值）|
| 修复后 | `300`（分钟）| `300 / (60×5) = 1.0` | **≈ 0.818**（达到日均值）|

**所有学生显示相同的 `w_score ≈ 0.182425` 是此 bug 的直接证据**：这是 sigmoid(−3×(0−0.5)) = 1/(1+e^1.5) ≈ 0.182 的固定值。

---

#### Bug 2（中等）— `v_week_start` 时区转换错误，周一早 8 点前的练琴被遗漏

旧版 `v_week_start` 计算：

```sql
-- ❌ 旧写法
v_week_start := (DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE)::TIMESTAMPTZ;
```

步骤分解：
1. `NOW() AT TIME ZONE 'Asia/Shanghai'` → 北京本地时间（无时区信息的 timestamp）
2. `DATE_TRUNC('week', ...)` → 周一 00:00:00（北京本地，无时区信息）
3. `::DATE` → 取日期部分，如 `2026-03-16`
4. `::TIMESTAMPTZ` → Supabase session 时区为 **UTC**，因此结果为 `2026-03-16 00:00:00+00` = **北京时间周一 08:00:00**

实际效果：北京时间周一 **00:00~07:59** 的练琴记录（UTC 时间为上周日晚）的 `session_start` 早于 `v_week_start`，被判为"上周数据"而漏统计。

---

#### 修复方案

```sql
-- ============================================================
-- FIX-26: compute_and_store_w_score 单位修正 + 时区修正
-- ============================================================
CREATE OR REPLACE FUNCTION public.compute_and_store_w_score(p_student_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_mean_duration  FLOAT8;
  v_weekly_minutes FLOAT8;
  v_elapsed_days   INT;
  v_ratio          FLOAT8;
  v_w_score        FLOAT8;
  v_dow            INT;
  v_week_start     TIMESTAMPTZ;
BEGIN
  SELECT mean_duration INTO v_mean_duration
  FROM public.student_baseline
  WHERE student_name = p_student_name;

  -- FIX-26 Bug2修复：正确计算北京时间本周一 00:00:00 的 TIMESTAMPTZ
  -- 旧写法 ::DATE::TIMESTAMPTZ 用 session 时区（UTC）解释日期，导致偏移 +8 小时
  v_week_start := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')
                    AT TIME ZONE 'Asia/Shanghai';

  -- FIX-26 Bug1修复：cleaned_duration 已是分钟，直接 SUM，不再除以 60
  -- 旧写法 SUM(cleaned_duration) / 60.0 把分钟变成小时，与 mean_duration（分钟）单位不符
  SELECT COALESCE(SUM(cleaned_duration), 0) INTO v_weekly_minutes
  FROM public.practice_sessions
  WHERE student_name = p_student_name
    AND session_start >= v_week_start
    AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

  v_dow := EXTRACT(DOW FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INT;
  v_elapsed_days := CASE v_dow
    WHEN 0 THEN 0   -- 周日：本周还未开始，给中性值
    WHEN 6 THEN 5   -- 周六：按5天整周计
    ELSE v_dow      -- 周一=1 … 周五=5
  END;

  IF v_elapsed_days = 0 OR COALESCE(v_mean_duration, 0) <= 0 THEN
    v_w_score := 0.5;
  ELSE
    -- mean_duration 与 v_weekly_minutes 现在都是分钟，单位一致
    -- FIX-24 防刷分门槛保留：均值 < 30 分钟按 30 分钟计
    v_ratio   := v_weekly_minutes / (GREATEST(v_mean_duration, 30.0) * v_elapsed_days);
    v_w_score := 1.0 / (1.0 + EXP(-3.0 * (v_ratio - 0.5)));
  END IF;

  PERFORM set_config('app.skip_score_trigger', 'on', true);

  UPDATE public.student_baseline
  SET w_score = v_w_score
  WHERE student_name = p_student_name;

  PERFORM set_config('app.skip_score_trigger', 'off', true);
END;
$$;

-- 部署后立即重算所有学生的 W 分
SELECT public.compute_and_store_w_score(student_name)
FROM public.student_baseline;
```

---

#### 修复后预期 W 分范围

| 学生情况（本周工作日） | 修复前（bug） | 修复后（正确） |
|----------------------|--------------|--------------|
| 未练琴（ratio = 0） | ≈ 0.182 | ≈ 0.182 |
| 练了 50% 日均值（ratio = 0.5） | ≈ 0.182 | ≈ 0.500 |
| 练了 100% 日均值（ratio = 1.0） | ≈ 0.182 | ≈ 0.818 |
| 练了 200% 日均值（ratio = 2.0） | ≈ 0.183 | ≈ 0.953 |

修复前所有人 W 分几乎相同（均值高低、练不练琴完全无区别），等于 W 维度对排名**毫无实质影响**。修复后 W 分才真正反映本周完成度，高权重（新生 50%）的激励效果才能生效。

#### 附加检查：`compute_student_score` 内部 `v_weekly_ratio` 是否有相同问题

`compute_student_score` 内部也独立计算 `v_weekly_ratio`（用于 `composite_raw`，决定 `raw_score` 和 `composite_score`）。部署 FIX-26 后，建议在 Supabase SQL Editor 执行以下语句检查：

```sql
-- 查看 compute_student_score 函数源码，搜索 weekly 或 cleaned_duration
SELECT prosrc
FROM pg_proc
WHERE proname = 'compute_student_score'
  AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');
```

若源码中存在 `SUM(cleaned_duration) / 60.0` 或 `::DATE)::TIMESTAMPTZ`，需同步修正，并重跑 `backfill_score_history()`。

---

### FIX-27 ✅ `compute_student_score` 时区修复：`v_week_monday::TIMESTAMPTZ` → `v_week_start_bjt`（2026-03-16）

**触发背景**：通过查询 `pg_proc` 获取已部署的 `compute_student_score` 完整源码后发现，FIX-26 仅修复了 `compute_and_store_w_score` 的时区问题，但 `compute_student_score` 内部存在同类 bug，影响两处关键判断。

---

#### 问题 1（严重）— `v_has_session_this_week` 误判，周一早晨练琴写入 0 分快照

```sql
-- ❌ 旧写法
v_week_monday := DATE_TRUNC('week', CURRENT_DATE)::DATE;
-- CURRENT_DATE 使用 UTC session 时区，北京时间周一 00:00~07:59 时 UTC 仍是上周日
-- → v_week_monday 指向「上周一」，整周统计窗口错误

SELECT EXISTS (
    SELECT 1 FROM public.practice_sessions
    WHERE ...
      AND session_start >= v_week_monday::TIMESTAMPTZ
      -- ::TIMESTAMPTZ 用 UTC 解释日期 = 周一 08:00 BJT
      -- 周一 00:00~07:59 BJT 的记录被排除
) INTO v_has_session_this_week;
```

**后果**：学生周一早晨（00:00~07:59 BJT）练琴归还后触发器调用 `compute_student_score`，`v_has_session_this_week = FALSE`，系统写入 **0 分缺席快照**，明明练了却被记成"本周未练"。

#### 问题 2（中等）— W 维度 `v_weekly_minutes` 漏统计同段时间的练琴

```sql
-- ❌ 旧写法
AND session_start >= v_week_monday::TIMESTAMPTZ  -- 同样偏移 +8 小时
```

周一 00:00~07:59 BJT 的练琴记录不计入 `v_weekly_minutes`，W 分偏低。

---

#### 修复方案

在 DECLARE 段新增 `v_week_start_bjt TIMESTAMPTZ`，并替换两处引用：

```sql
-- DECLARE 段新增：
v_week_start_bjt TIMESTAMPTZ;

-- BEGIN 开头：
-- ❌ 旧：
v_week_monday := DATE_TRUNC('week', CURRENT_DATE)::DATE;

-- ✅ 新：
v_week_monday    := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
v_week_start_bjt := (v_week_monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';
-- v_week_monday    → DATE，用于 snapshot_date（北京时间周一日期）✓
-- v_week_start_bjt → TIMESTAMPTZ，周一 00:00:00 BJT = 上周日 16:00:00 UTC ✓

-- 替换 1：v_has_session_this_week 判断
AND session_start >= v_week_start_bjt  -- ← 替换 v_week_monday::TIMESTAMPTZ

-- 替换 2：W 维度 session_start 过滤
AND session_start >= v_week_start_bjt  -- ← 替换 v_week_monday::TIMESTAMPTZ
```

**部署后重算**：

```sql
-- 重算当前 W 分（FIX-26 + FIX-27 单位和时区均已正确）
SELECT public.compute_and_store_w_score(student_name) FROM public.student_baseline;

-- 重算当前综合分（FIX-27 时区修复后 composite_score 正确）
SELECT public.compute_student_score(student_name)
FROM public.student_baseline WHERE composite_score > 0 OR last_updated IS NOT NULL;
```

---

#### 五个维度全量核查结果（2026-03-17 FIX-29 后更新）

| 维度 | 数学公式 | 方向逻辑 | 防自引用过滤 | 时区 | 状态 |
|------|---------|---------|------------|------|------|
| **B** | ✅ sigmoid(3×Δ/0.3)，1v1 最近两周对比 | ✅ 进步→>0.5 | ✅ `< v_week_monday` | — | ✅ 无问题 |
| **T** | ✅ 3周线性回归，斜率放大60×（FIX-28 优化） | ✅ 上升趋势→>0.5 | ✅ `< v_week_monday` | — | ✅ FIX-28 已优化 |
| **M** | ✅ 8活跃周指数衰减加权改善率，decay=0.65（FIX-28 重构） | ✅ 近期进步→高分 | ✅ `< v_week_monday` | — | ✅ FIX-28 已重构 |
| **A** | ✅ IQR×record_count→LN 归一化 | ✅ 均值高于中位→A高 | ✅ `< v_week_monday` | — | ✅ 无问题 |
| **W** | ✅ 无 /60 bug（FIX-26+FIX-27 双修） | ✅ ratio→sigmoid→0~1 | — | ✅ FIX-26+FIX-27 均已修复 | ✅ 已修复 |

**合成后惩罚（FIX-29 更新）**：`composite_raw × outlier_penalty`，其中：
- 0~40%：`1.0 - 0.5 × outlier_rate`（线性，0%→1.00，40%→0.80）
- >40%：`0.8 × EXP(-5.0 × (outlier_rate - 0.40))`（指数衰减，两段连续）

---

### FIX-28：T/M 维度公式优化 + `compute_student_score_as_of` 全面对齐

**发现时间**：2026-03-17

---

#### 问题 1（设计过敏）— T 趋势分放大系数过高（150×）

**根本原因**：T 维度使用 `slope / 0.02 * 3.0 = slope × 150`，斜率放大150倍后输入 sigmoid。  
raw_score 每周仅下滑 0.02（小幅正常波动）时：`sigmoid(150 × 0.02) = sigmoid(3) ≈ 0.047`，T 已接近 0。  
实际效果：任何微小波动均被判定为"极端上升"或"极端下降"，T 长期在 0 或 1 两端跳动，失去区分度。

**修复方案**：将分母从 `0.02` 改为 `0.05`，放大系数降至 60×：

```sql
-- ❌ 旧（150×，过敏）
t_score := 1.0 / (1.0 + EXP(slope / 0.02 * 3.0));

-- ✅ 新（60×，合理）
t_score := 1.0 / (1.0 + EXP(slope / 0.05 * 3.0));
```

**效果对比**：

| 每周下滑幅度 | 旧 T（150×）| 新 T（60×）|
|------------|-----------|-----------|
| 0.005/周（轻微波动） | 0.32（偏低）| 0.43（接近中性）|
| 0.02/周（小幅下滑） | 0.047（≈0）| 0.23（明显偏低）|
| 0.05/周（明显下滑） | ≈0 | 0.047（接近 0）|
| 0/周（持平） | 0.5 | 0.5 |

---

#### 问题 2（设计严苛）— M 动量分"严格连续"机制导致大量归零

**根本原因**：旧 M 使用"从最近一周起向后数，遇到任意一周不进步即停止计数"的严格连续逻辑。  
任意一周表现平平即完全重置，导致 M = 0 成为常态，失去动量量化意义。  
同时，旧版使用等权改善率（8活跃周），滑动窗口新旧一对抵消时 M 值多周不变。

**修复方案**：改为**指数衰减加权改善率**，8 活跃周窗口，最新对权重 1.0，每向前一对乘 0.65：

```sql
-- ❌ 旧（严格连续计数，任意不进步归零）
FOR m_rec IN (...LIMIT 12) LOOP
    IF curr_raw < prev_raw THEN
        consec_improve := consec_improve + 1;
    ELSE
        EXIT;  -- 遇到不进步立即停止
    END IF;
END LOOP;
m_score := LEAST(1.0, LN(consec_improve + 1) / LN(9.0));

-- ✅ 新（指数衰减加权改善率，每周必然变化）
FOR m_rec IN (...LIMIT 8) LOOP
    IF m_first THEN
        prev_raw := m_rec.raw_score;
    ELSE
        IF m_rec.raw_score < prev_raw THEN
            m_w_improve := m_w_improve + m_weight;  -- 进步：累加当前权重
        END IF;
        m_w_total := m_w_total + m_weight;
        m_weight  := m_weight * 0.65;               -- 权重衰减
        prev_raw  := m_rec.raw_score;
    END IF;
END LOOP;
m_score := CASE WHEN m_w_total > 0 THEN m_w_improve / m_w_total ELSE 0.5 END;
```

**权重分布**（7 对相邻比较，总权重 2.31）：

| 相邻对 | 权重 | 占总权重 |
|--------|------|---------|
| 最新对（本周 vs 上周）| 1.000 | 43% |
| -1 周对 | 0.650 | 28% |
| -2 周对 | 0.423 | 18% |
| -3 周对 | 0.275 | 12% |
| -4 至 -6 周对 | 0.179~0.075 | 合计约 17% |

**效果对比**（以历史断练6周后恢复的场景为例）：

| 场景 | 旧 M（连续计数）| 新 M（加权改善率）|
|------|--------------|---------------|
| 7 周进步、最近 1 周持平 | **0（重置！）** | ~0.57（仍偏高）|
| 近期进步、中期有反复 | **0** | ~0.65（加权近期）|
| 连续 3 周进步 | 0.63 | ~0.85（加权后更高）|
| 历史不足 2 周 | 0 | **0.5（中性）** |

---

#### 问题 3（数据不一致）— `compute_student_score_as_of` 使用旧版逻辑（FIX-17）

**根本原因**：用于历史回溯的 `compute_student_score_as_of` 仍在使用 FIX-17 旧版逻辑（8周T窗口、5v5 B比较、无W维度、旧M连续计数），导致历史快照数据与实时评分逻辑完全不一致。

**修复方案**：全面重写 `compute_student_score_as_of`，与实时版 `compute_student_score` 完全对齐：
- B 维度：改为 1v1 最近两周对比
- T 维度：3周回归 + 60× 放大系数
- M 维度：8活跃周指数衰减加权改善率
- W 维度：当前周用实际已过天数，历史周固定 5 天
- 动态权重：五维权重体系（hist_count < 4 / < 12 / ≥ 12）
- 时区：`v_week_start_bjt` 正确处理北京时间周一边界

**部署后必须重算历史数据**：

```sql
-- 步骤 1：重算所有历史快照（使用新公式，约 5~20 分钟）
SELECT public.backfill_score_history();

-- 步骤 2：重算当前 W 分
SELECT public.compute_and_store_w_score(student_name)
FROM public.student_baseline;
```

---

#### DECLARE 段变量变更（两个函数均适用）

| 旧变量 | 新变量 | 说明 |
|--------|--------|------|
| `consec_improve INT := 0` | 删除 | 不再使用连续计数 |
| `curr_raw FLOAT` | 删除 | 不再使用 |
| `m_total INT := 0` | 删除（中间过渡版）| 等权版已废弃 |
| `m_improve INT := 0` | 删除（中间过渡版）| 等权版已废弃 |
| — | `m_w_improve FLOAT := 0.0` | 加权进步得分 |
| — | `m_w_total FLOAT := 0.0` | 加权总分母 |
| — | `m_weight FLOAT := 1.0` | 当前对权重（循环内动态衰减）|

`weeks_improving` 字段含义变更：原为"连续进步周数"，现为 `ROUND(m_w_improve)::INT`（加权进步得分取整，仅供展示参考）。

---

---

## FIX-29：异常率惩罚平滑化（2026-03-17）

### 问题描述

旧版 `outlier_penalty` 是一个**阶跃函数**：0~40% 完全不惩罚（系数=1.0），一旦超过 40% 立即进入指数衰减。导致异常率 39% 和 40% 的学生得分差异接近零，但 40% 和 41% 差距突然变大，逻辑不连贯。

### 修复内容

**受影响函数**：`compute_student_score`、`compute_student_score_as_of`

**旧公式**：
```sql
outlier_penalty := CASE
    WHEN outlier_rate <= 0.4 THEN 1.0
    ELSE EXP(-5.0 * (outlier_rate - 0.4))
END;
```

**新公式（FIX-29）**：
```sql
-- 0~40%：线性衰减；>40%：指数衰减；两段在 40% 处连续（均=0.80）
outlier_penalty := CASE
    WHEN outlier_rate <= 0.4
        THEN 1.0 - 0.5 * outlier_rate
    ELSE
        0.8 * EXP(-5.0 * (outlier_rate - 0.4))
END;
```

### 惩罚系数对照表

| outlier_rate | 旧系数 | 新系数 | 差值 |
|---|---|---|---|
| 0% | 1.00 | 1.00 | 0 |
| 10% | 1.00 | 0.95 | -0.05 |
| 20% | 1.00 | 0.90 | -0.10 |
| 30% | 1.00 | 0.85 | -0.15 |
| 40% | 1.00 | 0.80 | -0.20 |
| 50% | 0.61 | 0.49 | -0.12 |
| 60% | 0.37 | 0.29 | -0.08 |
| 80% | 0.14 | 0.11 | -0.03 |

> 两段在 40% 处**严格连续**（新旧系数均为 0.80），无断点跳跃。

### 部署步骤

1. 在 Supabase SQL Editor 中分别执行 `CREATE OR REPLACE FUNCTION public.compute_student_score(...)` 和 `CREATE OR REPLACE FUNCTION public.compute_student_score_as_of(...)` 的完整 SQL（含 FIX-29 新公式）。
2. 重算所有历史快照：
```sql
-- 步骤 1：重算所有历史快照（约 5~20 分钟）
SELECT public.backfill_score_history();

-- 步骤 2：重算当前 W 分
SELECT public.compute_and_store_w_score(student_name)
FROM public.student_baseline;
```

---

---

## FIX-30：工作日饭点跨越异常检测（2026-03-17）

### 问题描述

原有异常判断只考虑**时长**（too_long / personal_outlier），未考虑练琴时间是否覆盖了规定的就餐时段。若学生练琴从 11:30 一直到 12:45，整段时间跨越午饭（11:50~12:30），说明学生饭点未归还琴房卡，是一种典型的不合理使用行为，应纳入异常统计。

### 新增规则

**仅工作日（周一~周五，北京时间）**，练琴时段与以下任一区间存在**重叠**时，标记为异常：

| 时段 | 区间（BJT） |
|------|------------|
| 午饭 | 11:50 ~ 12:30 |
| 晚饭 | 17:50 ~ 18:30 |

"重叠"定义：`session_start < 区间结束时间 AND session_end > 区间开始时间`

**新增 outlier_reason 值**：`meal_break`

### 优先级与 cleaned_duration 处理

| 情况 | 处理 |
|------|------|
| `too_long`（>180分钟）同时跨饭点 | 保持 `too_long`，不降级 |
| `capped_120`（120~180分钟）同时跨饭点 | 升级为 `meal_break` 异常（`cleaned_duration` 仍为 120） |
| 正常时长跨饭点 | 标记 `meal_break` 异常，`cleaned_duration` **不变**（实际时长仍计入） |

> 注意：`clean_duration` 函数不含时间信息，无需修改。异常来源依然是 `practice_sessions.is_outlier`（见 FIX-24b 说明）。

### 受影响函数

- **`trigger_insert_session`**：新增 `v_start_bjt`, `v_end_bjt`, `v_start_time`, `v_end_time`, `v_dow`, `v_spans_meal_break` 变量，在时长判断后加饭点重叠检测逻辑（FIX-30）。
- **`auto_clear_open_sessions`**（cron 21:30 BJT）：**无需修改。** 该函数向 `practice_logs` 插入 `clear` 记录，会自动触发 `trigger_insert_session`，FIX-30 逻辑由此自动覆盖。此外，auto_clear 的 session_end 固定为 21:30 BJT，任何跨越晚饭区间（17:50~18:30）的 session 时长必然 ≥ 3 小时，会优先触发 `too_long`，不会产生 meal_break 遗漏。午饭跨越同理（9+ 小时，早已是 too_long）。

### 历史修复步骤

```sql
-- 步骤0：确认受影响记录数
SELECT COUNT(*) FROM public.practice_sessions
WHERE EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai')::INTEGER BETWEEN 1 AND 5
  AND COALESCE(outlier_reason, '') != 'too_long'
  AND (
    ((session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '12:30:00' AND (session_end AT TIME ZONE 'Asia/Shanghai')::TIME > '11:50:00')
    OR
    ((session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '18:30:00' AND (session_end AT TIME ZONE 'Asia/Shanghai')::TIME > '17:50:00')
  );

-- 步骤1：标记历史跨饭点记录
UPDATE public.practice_sessions SET is_outlier = TRUE, outlier_reason = 'meal_break'
WHERE EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai')::INTEGER BETWEEN 1 AND 5
  AND COALESCE(outlier_reason, '') != 'too_long'
  AND (
    ((session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '12:30:00' AND (session_end AT TIME ZONE 'Asia/Shanghai')::TIME > '11:50:00')
    OR
    ((session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '18:30:00' AND (session_end AT TIME ZONE 'Asia/Shanghai')::TIME > '17:50:00')
  );

-- 步骤2：重算基线
SELECT public.recompute_all_baselines();

-- 步骤3：重算历史评分快照
SELECT public.backfill_score_history();

-- 步骤4：重算当前 W 分
SELECT public.compute_and_store_w_score(student_name) FROM public.student_baseline;
```

### `auto_clear_open_sessions` 函数体备份（2026-03-17，无需修改）

```sql
DECLARE
    v_today_bjt        DATE;
    v_clear_time       TIMESTAMPTZ;
    v_current_hour     INTEGER;
    v_current_minute   INTEGER;
    v_duration_seconds INTEGER;
    v_rec              RECORD;
    v_log_count        INTEGER := 0;
    v_room_count       INTEGER := 0;
BEGIN
    -- 时间保护：只允许在 21:30 ~ 23:59 北京时间执行
    v_current_hour   := EXTRACT(HOUR   FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INTEGER;
    v_current_minute := EXTRACT(MINUTE FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INTEGER;

    IF v_current_hour < 21 OR (v_current_hour = 21 AND v_current_minute < 30) THEN
        RAISE NOTICE '[auto_clear] 当前北京时间 %:%，未到 21:30，跳过执行',
            LPAD(v_current_hour::TEXT, 2, '0'),
            LPAD(v_current_minute::TEXT, 2, '0');
        RETURN;
    END IF;

    v_today_bjt  := (NOW() AT TIME ZONE 'Asia/Shanghai')::DATE;
    v_clear_time := (v_today_bjt::TEXT || ' 21:30:00')::TIMESTAMP AT TIME ZONE 'Asia/Shanghai';

    RAISE NOTICE '[auto_clear] 开始执行，清场时间点：%（北京时间）',
        to_char(v_clear_time AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI:SS');

    -- 第一步：补写 practice_logs clear 记录
    -- 以 rooms 表当前占用状态为准（只为仍在 rooms 表中被占用的房间写 clear）
    FOR v_rec IN
        SELECT
            r.occupant_student_name  AS student_name,
            pl.student_major,
            pl.student_grade,
            r.room_name,
            pl.piano_type,
            pl.created_at            AS assign_time
        FROM public.rooms r
        INNER JOIN LATERAL (
            SELECT *
            FROM public.practice_logs
            WHERE student_name = r.occupant_student_name
              AND room_name    = r.room_name
              AND action       = 'assign'
              AND created_at   < v_clear_time
              AND NOT EXISTS (
                  SELECT 1 FROM public.practice_logs c
                  WHERE c.student_name = r.occupant_student_name
                    AND c.room_name    = r.room_name
                    AND c.action       = 'clear'
                    AND c.created_at   > practice_logs.created_at
              )
            ORDER BY created_at DESC
            LIMIT 1
        ) pl ON TRUE
        WHERE r.occupant_student_name IS NOT NULL
    LOOP
        v_duration_seconds := EXTRACT(EPOCH FROM (v_clear_time - v_rec.assign_time))::INTEGER;

        IF v_duration_seconds < 300 THEN
            RAISE NOTICE '[auto_clear] 跳过 % @ %：仅 % 秒，视为误操作',
                v_rec.student_name, v_rec.room_name, v_duration_seconds;
            CONTINUE;
        END IF;

        -- 补写 clear → 触发 trigger_insert_session → 自动写入 practice_sessions
        -- （FIX-30 饭点检测由 trigger_insert_session 自动处理，此处无需额外逻辑）
        INSERT INTO public.practice_logs (
            student_name, student_major, student_grade,
            room_name, piano_type,
            action, created_at, practice_duration
        ) VALUES (
            v_rec.student_name, v_rec.student_major, v_rec.student_grade,
            v_rec.room_name, v_rec.piano_type,
            'clear', v_clear_time, v_duration_seconds
        );

        v_log_count := v_log_count + 1;
        RAISE NOTICE '[auto_clear] 补写 clear：% @ %，时长 %.0f 分钟',
            v_rec.student_name, v_rec.room_name, v_duration_seconds / 60.0;
    END LOOP;

    -- 第二步：清空 rooms 表占用状态
    UPDATE public.rooms
    SET
        occupant_student_name = NULL,
        register_time         = NULL,
        heartbeat_at          = NOW(),
        updated_at            = NOW(),
        version               = COALESCE(version, 0) + 1
    WHERE occupant_student_name IS NOT NULL;

    GET DIAGNOSTICS v_room_count = ROW_COUNT;

    RAISE NOTICE '[auto_clear] 完成：补写 % 条 clear 记录，清空 % 个房间占用状态',
        v_log_count, v_room_count;
END;
```

> **设计说明**：`auto_clear_open_sessions` 通过向 `practice_logs` 插入 `clear` 记录来间接创建 `practice_sessions`，触发链保证了所有数据处理逻辑（含 FIX-30 饭点检测）都在 `trigger_insert_session` 中统一执行，**无需在此函数中重复实现**。

---

### `index.ts` 同步修改

| 位置 | 修改内容 |
|------|---------|
| `Session` 接口 | 新增 `outlier_reason?: string` 字段 |
| 两处 API 查询 | `select=...is_outlier` 改为 `select=...is_outlier,outlier_reason` |
| 两处 session 对象映射 | 新增 `outlier_reason: r.outlier_reason ?? undefined` |
| flag 逻辑 | 按 `outlier_reason` 分别显示"★跨饭点/疑似饭点未还卡"、"★超长/疑似未还卡"、"★异常超长(个人基线)" |

---

---

## FIX-31：反躺平三联改（2026-03-17）

### 背景与动机

**漏洞描述**：当一名学生冲到排名第一后，若每周只练"和历史均值相同的量"，则：
- W 分（对比个人历史均值）≈ 0.5（中性，不被惩罚）
- B 分（本周 vs 上周无变化）≈ 0.5（中性）
- T 分（三周持平）≈ 0.5（中性）
- M 分（不进步，但衰退需 8 周）→ 缓慢降低，最长 2 个月
- 净结果：最长可"躺平保第一"长达 8 周

**三项修复目标**：
1. W 分参照从"全程历史均值"改为"近16周峰值均值"——维持均值不再够用，必须接近近期最佳表现
2. M 窗口从 8 活跃周缩为 4 活跃周——停止进步的代价从 2 个月压缩至 4 周
3. 新增 `peak_decay` 高峰衰退惩罚——近4周若明显低于近16周峰值，综合分被线性扣减

**受影响函数**：`compute_student_score`、`compute_student_score_as_of`（两者完全对齐）

---

### FIX-31-A：引入 `v_peak_weekly_avg`（近16周最佳4周均值）

> ⚠️ **架构状态**：FIX-31-A 最初将 `v_peak_weekly_avg` 同时用于 W 分计算和 peak_decay 阈值，导致双重惩罚。已于 **FIX-32（2026-03-17）** 完成职责分离，`v_peak_weekly_avg` 现在**仅供 peak_decay 使用**，W 分已恢复使用均值基准。本节保留原始设计记录，请以 FIX-32 为准。

**FIX-31-A 核心贡献**：引入 `v_peak_weekly_avg` 变量，为 peak_decay 提供"近期最佳水平"参照基准。

```sql
-- 近16周最佳4个完整工作日周的均值 → peak_decay 参照基准（FIX-31-A）
SELECT COALESCE(AVG(weekly_total), GREATEST(r.mean_duration, 30.0) * 5.0)
INTO v_peak_weekly_avg
FROM (
    SELECT SUM(ps.cleaned_duration) AS weekly_total
    FROM public.practice_sessions ps
    WHERE ps.student_name = p_student_name
      AND ps.session_start >= v_week_start_bjt - INTERVAL '16 weeks'
      AND ps.session_start <  v_week_start_bjt
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
      AND ps.cleaned_duration > 0
    GROUP BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')
    ORDER BY weekly_total DESC
    LIMIT 4
) top4;

IF v_peak_weekly_avg IS NULL OR v_peak_weekly_avg <= 0 THEN
    v_peak_weekly_avg := GREATEST(r.mean_duration, 30.0) * 5.0;
END IF;

-- cap：不超过历史均值 × 1.6（防偶发集训拉高 peak_decay 阈值）
v_peak_weekly_avg := LEAST(v_peak_weekly_avg,
                           GREATEST(r.mean_duration, 30.0) * 5.0 * 1.6);
```

> `as_of` 版：历史周的 `v_week_start_bjt` 对应回溯时间点，近16周同理往前数16周。

---

### FIX-31-A cap 修正（2026-03-17）：防偶发集训高峰拉高 peak_decay 阈值

> 注：此修正最初是为了防止 W 分和 peak_decay 双重受到集训高峰影响，FIX-32 完成职责分离后，cap 现在仅影响 `peak_decay` 阈值，W 分已不再依赖 `v_peak_weekly_avg`。

**问题**：若学生曾参加集训、备考等导致一段时间内练琴量远超日常水平（如平时 60 min/天，集训期 120 min/天），`v_peak_weekly_avg` 会被拉高，导致 peak_decay 阈值过高、日常练琴时频繁触发惩罚。

**后果（集训结束后恢复日常练琴）**：
- `v_peak_weekly_avg` = 120 × 5 = 600 min/week（无 cap）
- `peak_decay` 阈值 = 600 × 70% = 420 min/week
- 日常练琴 300 < 420 → `peak_decay = 300/420 = 0.714`
- 结果：日常练琴本属良好的学生被不合理地当作"衰退"处理

**修复**：在 `v_peak_weekly_avg` 计算后增加上限约束：

```sql
-- cap：不超过历史均值日均 × 1.6 × 5 天
v_peak_weekly_avg := LEAST(v_peak_weekly_avg,
                           GREATEST(r.mean_duration, 30.0) * 5.0 * 1.6);
```

**cap 效果对比**（示例：日常均值 60 min/天，集训4周 120 min/天）：

| 场景 | 旧（无 cap）| 新（有 cap）|
|------|-----------|-----------|
| `v_peak_weekly_avg` | 600 min/week（集训4周均值） | **480 min/week**（60×5×1.6，cap 生效）|
| 日常 300 min 时 W 分 | 0.50（中性，感觉在"混日子"）| **0.61（偏良好，反映真实状态）** |
| 日常 300 min 时 peak_decay | 0.714（触发惩罚）| **1.0（480×70%=336 < 300，豁免）** |

> **设计原则**：cap 最大允许基准比日常均值高 60%，既保留对"停止进步"的惩罚，又不惩罚"从集训状态恢复到高质量日常练琴"的学生。

---

### FIX-31-B：M 动量窗口 8 活跃周 → 4 活跃周

**旧**：
```sql
FOR m_rec IN (... LIMIT 8) LOOP
```

**新（FIX-31-B）**：
```sql
FOR m_rec IN (... LIMIT 4) LOOP  -- FIX-31-B: 4活跃周（原8周），窗口减半
```

**效果对比**：

| 场景 | 旧 M（8周窗口）| 新 M（4周窗口）|
|------|--------------|--------------|
| 停止进步后 M 归零时间 | 约 8 周（2个月）| **约 4 周（1个月）** |
| 连续2周进步后 M | ~0.65 | ~0.65（变化不大）|
| 连续3周进步后 M | ~0.80 | **~0.85（更快到高分）** |

> 注意：`weeks_improving`（存入 `student_baseline`）的满分对应值由约 7 降为约 3（3 对相邻周比较），Dashboard 文案需同步更新为"满分约3"。

---

### FIX-31-C：新增高峰衰退惩罚 `peak_decay`

**DECLARE 段新增变量**：
```sql
v_peak_weekly_avg  FLOAT8 := 0;   -- FIX-31: 近16周最佳4周均值（W+峰值参照）
v_recent_4w_avg    FLOAT8 := 0;   -- FIX-31: 近4活跃周均值（高峰衰退参照）
v_peak_decay       FLOAT8 := 1.0; -- FIX-31: 高峰衰退惩罚系数（0~1）
```

**插入位置（在 outlier_penalty 应用后）**：
```sql
-- FIX-31-C（修正版）: 高峰衰退惩罚
-- 取最近4个有练琴的活跃周（跳过寒暑假等假期空窗，扩大到16周窗口 ORDER BY week DESC LIMIT 4）
SELECT COALESCE(AVG(weekly_total), v_peak_weekly_avg)
INTO v_recent_4w_avg
FROM (
    SELECT SUM(ps.cleaned_duration) AS weekly_total
    FROM public.practice_sessions ps
    WHERE ps.student_name = p_student_name
      AND ps.session_start >= v_week_start_bjt - INTERVAL '16 weeks'
      AND ps.session_start <  v_week_start_bjt
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
      AND ps.cleaned_duration > 0
    GROUP BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')
    ORDER BY 1 DESC
    LIMIT 4
) recent4;

-- 近4活跃周 < 近16周峰值 × 70% 时触发线性惩罚；新生（hist_count < 4）豁免
v_peak_decay := CASE
    WHEN v_peak_weekly_avg <= 0 OR hist_count < 4    THEN 1.0
    WHEN v_recent_4w_avg >= v_peak_weekly_avg * 0.70 THEN 1.0
    ELSE v_recent_4w_avg / (v_peak_weekly_avg * 0.70)
END;

-- 双重惩罚
composite_raw := composite_raw * outlier_penalty * v_peak_decay;
```

**惩罚系数对照表（示例：峰值均值 = 100 分钟/天）**：

| 近4活跃周日均 | 近4周/峰值比 | peak_decay | 综合分惩罚 |
|------------|------------|------------|----------|
| 100 分钟 | 100% | 1.00 | 无 |
| 75 分钟  | 75%  | 1.00 | 无（≥70% 豁免区）|
| 65 分钟  | 65%  | 65/70 = 0.929 | 约扣 7% |
| 50 分钟  | 50%  | 50/70 = 0.714 | 约扣 29% |
| 30 分钟  | 30%  | 30/70 = 0.429 | 约扣 57% |

---

### FIX-31-C 修正（2026-03-17）：recent_4w 由"日历4周"改为"最近4活跃周"

**发现时间**：2026-03-17，通过诊断学生冼昊熹分数异常（composite_score = 15）发现。

**根本原因**：初版 FIX-31-C 使用 `INTERVAL '4 weeks'` 固定日历窗口查询近4周练琴量。当学生因**寒暑假或其他假期**长时间停练后返校，该窗口内绝大部分为空白周（无练琴记录），导致 `v_recent_4w_avg` 极低，`peak_decay` 被不合理地压至接近 0，综合分从正常水平直接跌到 15 分。

**问题复现（以冼昊熹为例）**：
- 2026-02-02 ～ 2026-03-02：春节假期，5 周零练琴
- FIX-31-C 的日历4周窗口（02-16 ～ 03-15）内：只有 2026-03-09 一周有练琴（240 分钟）
- `v_recent_4w_avg = 240`，`v_peak_weekly_avg = 1424.8`
- `peak_decay = 240 / (1424.8 × 0.70) = 0.241` → 综合分乘以 0.80 × 0.241 ≈ 0.193 → 最终 **composite_score = 15**
- 但该学生 B=0.89、T=1.0、M=1.0，所有进步维度均优秀，低分完全不合理

**修复方案**：将 `v_recent_4w_avg` 的查询从"最近4个日历周"改为"最近4个有练琴的活跃周"：

| 字段 | 旧（BUG）| 新（修正）|
|------|---------|---------|
| 查询窗口 | `INTERVAL '4 weeks'`（固定日历） | `INTERVAL '16 weeks'`（扩大搜索范围）|
| 取周方式 | 取该窗口内所有有记录的周 | `ORDER BY DATE_TRUNC('week',...) DESC LIMIT 4`（按日期取最近4个活跃周）|

> **ORDER BY 说明**：使用 `ORDER BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai') DESC LIMIT 4`，明确按**日期倒序**取最近4个有练琴的活跃周。避免使用 `ORDER BY 1 DESC`（按练琴量降序），防止历史某个高峰周"挤占"名额，使近期真实状态被遗漏。

**修正后冼昊熹的计算结果**：
- 近4活跃周：03-09(240)、01-26(240)、01-19(1626)、01-12(1296)，均值 = 850.5
- `peak_decay = 850.5 / (1424.8 × 0.70) = 0.853`
- 预期 `composite_score ≈ 49`（合理反映假期后恢复状态）

---

### 综合防躺平效果（三项叠加）

| 躺平策略 | 旧版受影响时间 | 新版受影响时间 |
|---------|--------------|--------------|
| 维持历史均值，不提高 | 8 周后 M 才明显降低 | **第1周 W 分立即下降（到 0.5），第4周 M 下降，同时 peak_decay 触发** |
| 练习量降至均值的 65% | 几乎无影响 | **peak_decay ≈ 0.93，W 分 < 0.4，3 维同时拉低分数** |
| 完全停练 | 分数冻结保持旧高分 | **本周 W=0.18，peak_decay=0 向趋近，M 快速归零** |

---

### `backfill_score_history` 同步改进（2026-03-17）

在本次 FIX-31 全量重算时同步改进了 `backfill_score_history` 函数，修复两处已知问题：

#### 改进 1：去掉 PERCENT_RANK 归一化（对齐 FIX-18）

| 字段 | 旧（FIX-18 前遗留）| 新 |
|------|-----------------|-----|
| 历史快照 `composite_score` | PERCENT_RANK × 100（百分位） | **ROUND(raw_score × 100)**（与实时版一致）|
| 每周步骤 ③ | 对活跃学生执行 PERCENT_RANK 归一化 | **删除此步骤**，由 `compute_student_score_as_of` 直接写入 |

> 旧版 backfill 的 PERCENT_RANK 步骤在调用 `compute_student_score_as_of` 之后执行，会覆盖 as_of 写入的 `composite_score`，导致历史数据与实时评分口径不一致。

#### 改进 2：使用 BJT 时区作为周边界（对齐 FIX-27）

```sql
-- 旧：直接转换 DATE → TIMESTAMPTZ（在 UTC session 中偏移 +8h）
AND session_start >= v_current_date::TIMESTAMPTZ

-- 新：明确使用北京时间周一 00:00:00 作为边界
v_week_start_bjt := (v_current_date::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';
AND session_start >= v_week_start_bjt
AND session_start <  v_week_next_bjt
```

> 修复后，周一 00:00:00~07:59:59 BJT 的练琴记录能被正确纳入该周的 backfill 计算，与实时版 FIX-27 行为完全一致。

---

### FIX-32：W / peak_decay 职责分离——消除双重惩罚（2026-03-17）

#### 问题根因

FIX-31-A 将同一个变量 `v_peak_weekly_avg` 同时用于两处：

| 用途 | 路径 |
|------|------|
| W 分分母 | `v_weekly_ratio = 本周练琴 / (v_peak_weekly_avg / 5 × 已过天数)` |
| peak_decay 阈值 | `若近4周均值 < v_peak_weekly_avg × 70% → 触发衰退惩罚` |

当学生某周只练了峰值的 50%，两条路径都会放大惩罚，造成叠加压分：

```
① W 分：ratio = 0.5 → w_score ≈ 0.50（正常水平 0.82 → 跌 0.32）
   W 权重 25% → composite_raw 减少 0.25 × 0.32 = -0.08

② peak_decay：近4周均值 50% < 70% → peak_decay = 0.50/0.70 = 0.714
   composite_raw 额外 × 0.714 → 再扣 28.6%

最终：composite_raw = 0.72 → 经 W 跌至 ≈0.64 → 再经 peak_decay ≈0.46
综合分从 72 跌至 46，跌幅 36%（过惩罚）
```

两者本质都在惩罚"相对于近期峰值练习不足"，属于对同一行为的双重计量。

#### 修复方案（FIX-32）

**W 分基准恢复为历史均值**，`v_peak_weekly_avg`（含 cap）职责专属 peak_decay：

| 维度 | 基准 | 测量意图 |
|------|------|----------|
| **W 分** | `GREATEST(r.mean_duration, 30.0) × v_elapsed_days` | 衡量本周与个人历史均值的一致性 |
| **peak_decay** | `v_peak_weekly_avg × 70%` | 衡量近期是否相对近期最佳水平明显下滑 |

**W 分代码（FIX-32 后）**：
```sql
-- W 分基准：历史均值 × 本周已过工作日天数（不再使用 v_peak_weekly_avg）
v_weekly_ratio := v_weekly_minutes::FLOAT8
                  / NULLIF(GREATEST(r.mean_duration, 30.0) * v_elapsed_days, 0.0);
w_score := GREATEST(0.0, LEAST(1.0,
             1.0 / (1.0 + EXP(-3.0 * (COALESCE(v_weekly_ratio, 0.0) - 0.5)))));
```

**peak_decay 代码（不变，仍使用 v_peak_weekly_avg）**：
```sql
-- peak_decay：近4活跃周均值若低于近16周峰值均值 70%，触发线性惩罚
IF v_recent_4w_avg < v_peak_weekly_avg * 0.70 AND hist_count >= 4 THEN
    v_peak_decay := v_recent_4w_avg / (v_peak_weekly_avg * 0.70);
    v_peak_decay := GREATEST(0.5, v_peak_decay);
ELSE
    v_peak_decay := 1.0;
END IF;
```

#### 修复后行为对比

| 学生行为 | FIX-31（修复前）| FIX-32（修复后）|
|---------|----------------|----------------|
| 本周练了历史均值 × 已过天数 | W ≈ 0.50（被峰值压低），peak_decay 可能触发 | **W ≈ 0.82（良好），peak_decay 视近4周定** |
| 本周练了峰值均值 | W ≈ 0.82 | **W > 0.90（超均值加分）** |
| 近4周均值 < 峰值 70% | W + peak_decay 双重压分 | **仅 peak_decay 单一惩罚** |
| 恢复正常练琴（均值水平）| W 被集训历史压低 | **W 恢复正常，peak_decay 随之缓解** |

**受影响函数**：`compute_student_score`、`compute_student_score_as_of`（两者已完全对齐）

---

### 部署后重算步骤

```sql
-- 步骤 1：全量历史重算（约 5~20 分钟）
SELECT public.backfill_score_history();

-- 步骤 2：重算当前 W 分
SELECT public.compute_and_store_w_score(student_name)
FROM public.student_baseline;

-- 步骤 3：重算当前综合分
SELECT public.compute_student_score(student_name)
FROM public.student_baseline
WHERE composite_score > 0 OR last_updated IS NOT NULL;
```

---

## FIX-33：T 维度数据源改为工作日练琴量——消除 B/T 循环依赖（2026-03-17）

### 问题根因

T 维度使用 `student_score_history.raw_score` 做线性回归，但 `raw_score` 本身已经包含了 B 维度的贡献：

```
raw_score = f(B, T, M, A, W)
T = "对已包含B分的历史分数做线性回归"
  = B 的时间延迟版，而非独立信号
```

**结构性后果**：成熟学生（≥12周）B+T 联合权重 50%，实际上用两个镜子照同一面墙——都在测量"近期分数有没有在上升"，而上升的主要驱动又来自 B 本身。

**极端案例**（连续3周进步，B≈0.85，T≈0.88）：
```
仅 B+T 贡献：0.25×0.85 + 0.25×0.88 = 0.433
约等于43%的总分，仅靠"近期在进步"这一件事
```

### 修复方案（FIX-33）

**将 T 的数据源从 `student_score_history.raw_score` 改为 `practice_sessions` 的周总练琴量。**

| | 旧（FIX-28 前后）| 新（FIX-33）|
|--|------|------|
| **T 测量对象** | raw_score 的3周趋势（质量分走向）| 工作日练琴分钟数的3周趋势（练琴量走向）|
| **数据来源** | `student_score_history` | `practice_sessions` |
| **与 B 的关系** | 循环依赖（T 依赖包含B的raw_score）| **完全独立**（不同数据源）|
| **语义** | "分数在涨吗"（和B重复）| **"练琴量在增长吗"**（独立新信息）|

修复后两维度语义正交：
- **B（质量进步）**："这周综合评分比上周好了吗？" → 捕捉练琴质量/规律性的突变
- **T（量的趋势）**："练琴时间在持续增长吗？" → 捕捉练习投入度的走向

### 新 T 计算代码（两函数一致）

```sql
-- T：FIX-33 改为读 practice_sessions 周总练琴量，与 B(raw_score) 数据源解耦
-- 语义：B = 质量分有无进步；T = 练琴量是否在增长（两个独立信号）
n_points := 0; sum_x := 0; sum_y := 0; sum_xy := 0; sum_x2 := 0;
FOR rec IN
    SELECT ROW_NUMBER() OVER (ORDER BY week_start ASC) AS x,
           weekly_mins                                  AS y
    FROM (
        SELECT DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai') AS week_start,
               SUM(ps.cleaned_duration)                                           AS weekly_mins
        FROM public.practice_sessions ps
        WHERE ps.student_name     = p_student_name
          AND ps.cleaned_duration > 0
          AND ps.session_start    < v_week_start_bjt          -- as_of版同此变量
          AND ps.session_start   >= v_week_start_bjt - INTERVAL '8 weeks'
          AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
        GROUP BY 1
        HAVING SUM(ps.cleaned_duration) > 0
        ORDER BY 1 DESC
        LIMIT 3
    ) sub
LOOP
    n_points := n_points + 1;
    sum_x  := sum_x  + rec.x;  sum_y  := sum_y  + rec.y;
    sum_xy := sum_xy + rec.x * rec.y;  sum_x2 := sum_x2 + rec.x * rec.x;
END LOOP;
IF n_points >= 3 THEN
    slope := COALESCE(
        (n_points * sum_xy - sum_x * sum_y) / NULLIF(n_points * sum_x2 - sum_x * sum_x, 0),
        0.0);
    -- 斜率归一化：relative_slope = slope / 个人周基准（均值×5工作日，最低150min）
    -- 5%/周增长率（≈周基准的5%）→ t_score ≈ 0.82（良好），对齐旧版 /0.05*3.0 参数
    t_score := GREATEST(0.0, LEAST(1.0,
        1.0 / (1.0 + EXP(-(slope / GREATEST(r.mean_duration * 5.0, 150.0)) / 0.05 * 3.0))));
ELSE
    t_score := 0.5;  -- 数据不足3周时中性
END IF;
```

**归一化参数说明**：

| relative_slope（slope / 周基准）| 含义 | t_score |
|---|---|---|
| 0 | 练琴量持平 | 0.50（中性）|
| +0.05 | 每周量增长 5%（温和上升）| ≈ 0.82（良好）|
| +0.10 | 每周量增长 10%（明显上升）| ≈ 0.95（优秀）|
| −0.05 | 每周量下滑 5% | ≈ 0.18（偏低）|

### 修复后 B/T 独立性对比

| 学生场景 | B | T | 说明 |
|---------|---|---|------|
| 练习时间稳定，但质量突然提升 | ↑ 高 | ≈ 中（量没变）| B 独立捕捉到 ✅ |
| 每周增加练琴时间，分还没跟上 | ≈ 中 | ↑ 高（量在涨）| T 独立捕捉到 ✅ |
| 量增加 + 质量同步提升 | ↑ | ↑ | 两件独立的事，联合奖励合理 ✅ |
| 连续3周持平 | ≈ 中 | ≈ 中 | 无虚假加分 ✅ |

**受影响函数**：`compute_student_score`、`compute_student_score_as_of`（两者已完全对齐）

### 部署后重算步骤

```sql
-- 步骤 1：部署两个函数（FIX-33 已含入完整 SQL）

-- 步骤 2：全量历史重算（T 维度历史数据全部需要重算）
SELECT public.backfill_score_history();

-- 步骤 3：重算当前 W 分
SELECT public.compute_and_store_w_score(student_name)
FROM public.student_baseline;

-- 步骤 4：重算当前综合分
SELECT public.compute_student_score(student_name)
FROM public.student_baseline
WHERE composite_score > 0 OR last_updated IS NOT NULL;
```

---

## FIX-34：B 和 M 维度数据源改为工作日练琴量——消除 raw_score 回声室效应（2026-03-17）

### 问题根因

B 和 M 均从 `student_score_history.raw_score` 历史中读取数据，而 `raw_score` 本身已经包含了上周 B 和 M 的贡献，形成**反馈回路**：

```
raw_score(N) = f(B, T, M, A, W)

B(N+1) = f(raw_score(N)  vs  raw_score(N-1))   ← 两者都含 B 贡献
M(N+1) = f(raw_score(N), raw_score(N-1), ...)   ← 每个都含 M 贡献
```

**回声放大路径**（一次偶发高分周，成熟学生 B=25% M=15%）：

```
周 N：W 超高 → raw_score 高出 +0.033
周 N+1：B 检测到 raw_score 变大 → b_score ≈ 0.83（原本 0.50）
        B 贡献额外：0.25 × 0.33 = +0.083     ← 回声放大到 2.5 倍！
周 N+2：B 回落，M 仍受益（窗口内有高分对）→ 轻微偏高
周 N+3：M 窗口仍残留高分 → 衰减但未消除
```

**关键问题**：B 的 sigmoid 斜率除数为 0.3（放大 3.3 倍），周 N 的 +0.033 在周 N+1 被放大到 +0.083——**回声比原始信号强 2.5 倍**。

### 修复方案（FIX-34）

将 B 和 M 的数据源与 FIX-33 的 T 保持一致，全部改为读 `practice_sessions` 周总练琴量：

| 维度 | 旧数据源 | 新数据源（FIX-34）| 新语义 |
|------|---------|-----------------|--------|
| **B** | `student_score_history.raw_score`（含B贡献）| `practice_sessions` 周总量 | 上周比前周多练了多少？|
| **M** | `student_score_history.raw_score`（含M贡献）| `practice_sessions` 周总量 | 最近几周有多少周达到练琴目标？|

FIX-34 后，B、T、M 三维全部来自 `practice_sessions`，无任何 raw_score 反馈环。

### FIX-34-A：B 维度新计算代码

```sql
-- B：FIX-34-A 改为比较最近2活跃周总练琴量，与 raw_score 反馈环彻底解耦
-- 语义：上周比前周多练了多少？（量的即时变化）
SELECT MAX(CASE WHEN rn = 1 THEN weekly_mins END),
       MAX(CASE WHEN rn = 2 THEN weekly_mins END)
INTO v_last_mins, v_prev_mins
FROM (
    SELECT SUM(ps.cleaned_duration)                                           AS weekly_mins,
           ROW_NUMBER() OVER (
               ORDER BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai') DESC
           )                                                                  AS rn
    FROM public.practice_sessions ps
    WHERE ps.student_name     = p_student_name
      AND ps.cleaned_duration > 0
      AND ps.session_start    < v_week_start_bjt
      AND ps.session_start   >= v_week_start_bjt - INTERVAL '8 weeks'
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    GROUP BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')
    HAVING SUM(ps.cleaned_duration) > 0
    ORDER BY 1 DESC
    LIMIT 2
) sub;
v_last_mins := COALESCE(v_last_mins, GREATEST(r.mean_duration, 30.0) * 5.0);
v_prev_mins := COALESCE(v_prev_mins, GREATEST(r.mean_duration, 30.0) * 5.0);
-- 归一化：差值 / 个人周基准（均值×5工作日，最低150min），sigmoid 斜率与旧版对齐
b_score := GREATEST(0.0, LEAST(1.0,
    1.0 / (1.0 + EXP(
        -3.0 * (v_last_mins - v_prev_mins) / GREATEST(r.mean_duration * 5.0, 150.0)
    ))));
```

**B 归一化参数**：

| 场景 | `(last - prev) / 周基准` | b_score |
|------|------------------------|---------|
| 上周比前周多 20%（+0.20）| +0.20 | ≈ 0.73 |
| 持平（0）| 0 | 0.50 |
| 上周比前周少 20%（-0.20）| -0.20 | ≈ 0.27 |

### FIX-34-B：M 维度新计算代码

```sql
-- M：FIX-34-B 改为：近4活跃周练琴量 ≥ 个人周基准70% 的指数衰减加权比例
-- 语义：最近几周有多少周达到了练琴目标？越近的周权重越高
m_w_improve := 0.0; m_w_total := 0.0; m_weight := 1.0;
FOR m_rec IN (
    SELECT SUM(ps.cleaned_duration) AS weekly_mins
    FROM public.practice_sessions ps
    WHERE ps.student_name     = p_student_name
      AND ps.cleaned_duration > 0
      AND ps.session_start    < v_week_start_bjt
      AND ps.session_start   >= v_week_start_bjt - INTERVAL '16 weeks'
      AND EXTRACT(DOW FROM ps.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    GROUP BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai')
    HAVING SUM(ps.cleaned_duration) > 0
    ORDER BY DATE_TRUNC('week', ps.session_start AT TIME ZONE 'Asia/Shanghai') DESC
    LIMIT 4
) LOOP
    IF m_rec.weekly_mins >= GREATEST(r.mean_duration, 30.0) * 5.0 * 0.70 THEN
        m_w_improve := m_w_improve + m_weight;
    END IF;
    m_w_total := m_w_total + m_weight;
    m_weight  := m_weight * 0.65;
END LOOP;
m_score := CASE WHEN m_w_total > 0 THEN m_w_improve / m_w_total ELSE 0.5 END;
```

**M 典型值对照**（4周权重：1.0 / 0.65 / 0.42 / 0.27，总计 2.34）：

| 达标情况（最近→最早）| m_score |
|-------------------|---------|
| 4/4 周达标 | 1.00 |
| 最近3周达标，最早1周未达标 | (1.0+0.65+0.42)/2.34 ≈ 0.88 |
| 最近2周达标，较早2周未达标 | (1.0+0.65)/2.34 ≈ 0.70 |
| 仅最近1周达标 | 1.0/2.34 ≈ 0.43 |
| 0/4 周达标 | 0.00 |
| 无历史数据 | 0.50（中性）|

> `weeks_improving` 字段（存入 `student_baseline`）语义更新：原为"加权进步分"，现为加权达标分，`ROUND(m_w_improve)::INT` 可解读为"约 N 周达到练琴目标（加权）"。

### DECLARE 段变量变更

| 旧变量 | 新变量 | 说明 |
|--------|--------|------|
| `hist_score_early FLOAT8` | 删除 | B 不再读 raw_score |
| `hist_score_recent FLOAT8` | 删除 | B 不再读 raw_score |
| `m_first BOOLEAN := TRUE` | 删除 | M 不再做相邻对比较 |
| `prev_raw FLOAT8 := NULL` | 删除 | M 不再做相邻对比较 |
| — | `v_last_mins FLOAT8 := 0.0` | B 新增：上周总量 |
| — | `v_prev_mins FLOAT8 := 0.0` | B 新增：前周总量 |

### 回声消除效果验证

```
周 N：W 超高（ratio=2.0）→ raw_score 高出 +0.033

旧版 周 N+1：B 读到 raw_score(N) > raw_score(N-1) → b_score ≈ 0.83 → 回声 +0.083
新版 周 N+1：B 读 practice_sessions 量。若量正常（没有超练）→ b_score ≈ 0.50 → 无回声 ✅

旧版 周 N+1：M 读 raw_score(N) "改善" → m_w_improve 计入 → M 虚高
新版 周 N+1：M 读量是否≥70%基线。若量正常 → 照常判断，不受 W 分影响 ✅
```

### 五维数据源全览（FIX-34 后）

| 维度 | 数据来源 | 反馈环 | 时间窗口 |
|------|---------|--------|---------|
| **B** | practice_sessions（FIX-34-A）| 无 ✅ | 最近2活跃周 |
| **T** | practice_sessions（FIX-33）| 无 ✅ | 最近3活跃周斜率 |
| **M** | practice_sessions（FIX-34-B）| 无 ✅ | 最近4活跃周达标率 |
| **A** | student_baseline（静态快照）| 无 ✅ | 最近30条工作日记录 |
| **W** | practice_sessions（当前周）| 无 ✅ | 本周实时 |

**受影响函数**：`compute_student_score`、`compute_student_score_as_of`（两者已完全对齐）

### 部署后重算步骤

```sql
-- 步骤 1：部署两个函数（FIX-34 已含入完整 SQL）

-- 步骤 2：全量历史重算（B、M 历史数据全部需要重算）
SELECT public.backfill_score_history();

-- 步骤 3：重算当前 W 分
SELECT public.compute_and_store_w_score(student_name)
FROM public.student_baseline;

-- 步骤 4：重算当前综合分
SELECT public.compute_student_score(student_name)
FROM public.student_baseline
WHERE composite_score > 0 OR last_updated IS NOT NULL;
```

---

## FIX-37：新生阶段 W/B/T/M 基准贝叶斯收缩——防止极端初始值导致评分失真（2026-03-17）

### 问题根因

`mean_duration` 由最近 30 条工作日记录的算术均值计算。新生只有 1~3 条记录时，均值方差极大：

```
极端案例 A：第一周练 120 min/天 → mean_duration = 120
  此后正常练 40 min/天 → W ratio = 40/120 = 0.33 → w_score ≈ 0.37（持续被惩罚）

极端案例 B：第一周只练 10 min/天 → mean_duration = 10（但 GREATEST 兜底到 30）
  此后正常练 40 min/天 → W ratio = 40/30 = 1.33 → w_score ≈ 0.91（虚高）
```

新生恰好处于 W 权重 **50%** 的阶段，基准失真对综合分影响最大。

### 修复方案（FIX-37）：贝叶斯收缩

引入 `v_effective_mean` 替代所有评分计算中的 `r.mean_duration`，向全体/同专业中位数线性收缩：

```sql
-- 在 A 维度百分位计算后（median_mean 已可用）加入：
v_shrink_alpha   := LEAST(1.0, r.record_count::FLOAT8 / 15.0);
v_effective_mean := v_shrink_alpha * COALESCE(r.mean_duration, 0.0)
                  + (1.0 - v_shrink_alpha) * COALESCE(median_mean, 30.0);
v_effective_mean := GREATEST(v_effective_mean, 15.0);  -- 绝对下限 15 分钟/天
```

**收缩效果对照**（示例：个人均值=120，全体中位数=40）：

| record_count | α | v_effective_mean | 效果 |
|---|---|---|---|
| 1 条 | 0.07 | ≈ 46 min | 几乎完全依赖中位数 |
| 5 条 | 0.33 | ≈ 66 min | 混合过渡 |
| 10 条 | 0.67 | ≈ 93 min | 偏向个人值 |
| 15 条+ | 1.00 | = 120 min | 完全信任个人值 |

### 替换范围

`v_effective_mean` 替换所有评分计算中的 `GREATEST(r.mean_duration, 30.0)` / `r.mean_duration * 5.0`：

| 位置 | 替换原因 |
|------|---------|
| B 归一化分母 `GREATEST(r.mean_duration * 5.0, 150.0)` | 防止新生基准失真导致 B 虚高/虚低 |
| B 回落默认值 `GREATEST(r.mean_duration, 30.0) * 5.0` | 同上 |
| T 斜率归一化分母 | 同上 |
| M 达标门槛 `GREATEST(r.mean_duration, 30.0) * 5.0 * 0.70` | 防止新生 M 门槛异常 |
| W 分母 `GREATEST(r.mean_duration, 30.0) * v_elapsed_days` | **核心修复目标** |
| peak_decay 回落值和 cap 基准 | 保持 peak_decay 门槛与 W 一致 |

**保留 `r.mean_duration` 不替换的地方**：
- `student_score_history` INSERT 中的 `mean_duration` 字段（存储真实基线值）
- A 维度 `quality_score` 公式（A 的语义是"与全体对比"，应用真实个人值）
- `hist_mean_dur` 计算（历史均值追踪，与新生收缩无关）

### 新生 W 分稳定性对比

| record_count | 旧版 w_score（mean=120，练40min）| 新版 w_score（v_effective_mean≈46，练40min）|
|---|---|---|
| 1 条 | sigmoid(-0.51) ≈ **0.37**（被惩罚）| sigmoid(0.44) ≈ **0.61**（接近正常）|
| 5 条 | sigmoid(-0.51) ≈ 0.37 | sigmoid(0.25) ≈ **0.56** |
| 15 条+ | sigmoid(-0.51) ≈ 0.37 | sigmoid(-0.51) ≈ **0.37**（回归真实）|

### 受影响函数

`compute_student_score`、`compute_student_score_as_of`（两者已完全对齐）

### 部署后重算步骤

```sql
-- 步骤 1：部署两个函数（FIX-37 已含入完整 SQL）

-- 步骤 2：全量历史重算（新生历史分全部需要用新基准重算）
SELECT public.backfill_score_history();

-- 步骤 3：重算当前综合分
SELECT public.compute_student_score(student_name)
FROM public.student_baseline
WHERE composite_score > 0 OR last_updated IS NOT NULL;
```

---

## FIX-38：T 维度 Sigmoid 参数校正——基于真实数据降低过陡斜率（2026-03-17）

### 问题根因

FIX-33 将 T 维度数据源改为 `practice_sessions` 周总练琴量后，Sigmoid 参数沿用了旧版的 `/0.05 * 3.0`，实际放大倍数为 **×60**，远超设计意图：

```
原设计注释："5% 周增长率 → t_score ≈ 0.82"
实际计算：sigmoid(0.05 / 0.05 * 3.0) = sigmoid(3.0) ≈ 0.95  ← 偏差巨大
```

导致大量历史记录 T 分非 0.5 即 1.0（双峰分布），中间段几乎为空：
- 任何正斜率（哪怕练琴量微增 1 min/周）→ t_score 迅速趋向 1.0
- 数据不足 3 个活跃周 → 硬编码回落 0.5（精确值）

### 真实数据分析（146 名学生 2131 周配对）

| 指标 | 数值 |
|------|------|
| 周配对中位数增长率 | -0.7%（一半为负增长）|
| 学生个人平均增长率中位数 | **3.1%** |
| 学生个人增长率 p75 | **9.4%**（优秀学生）|
| 学生个人增长率 p90 | **13.1%**（顶尖学生）|

### 修复方案（FIX-38）

将 T 维度 Sigmoid 参数从 `/0.05 * 3.0`（×60）改为 `/0.20 * 3.0`（×15）：

```sql
-- 旧（×60，过陡）
1.0 / (1.0 + EXP(-(slope / GREATEST(v_effective_mean * 5.0, 150.0)) / 0.05 * 3.0))

-- 新（×15，基于真实数据校准）
1.0 / (1.0 + EXP(-(slope / GREATEST(v_effective_mean * 5.0, 150.0)) / 0.20 * 3.0))
```

### 修复后各分位学生的 T 分对照

| 学生群体 | 个人平均增长率 | 旧 t_score（×60）| 新 t_score（×15）|
|---------|-------------|-----------------|-----------------|
| 底部（退步）| -2.9% | 0.05 | 0.39 |
| 中位（普通）| 3.1% | 0.97 ≈ **1.0** | **0.61** |
| p75（优秀）| 9.4% | ≈ **1.0** | **0.80** |
| p90（顶尖）| 13.1% | **1.0**（精确）| **0.88** |
| 0%（持平）| 0% | 0.50 | 0.50（不变）|

旧版"中位学生"和"顶尖学生"T 分几乎相同（均趋于 1.0），无法区分优劣。新版 p75 才达到 0.80，形成清晰梯度。

### 受影响函数

`compute_student_score`（第 246 行）、`compute_student_score_as_of`（第 234 行）

---

## FIX-37b：`compute_and_store_w_score` 同步贝叶斯收缩（2026-03-17）

### 问题根因

FIX-37 在 `compute_student_score` 和 `compute_student_score_as_of` 中引入了 `v_effective_mean`（贝叶斯收缩），但 `compute_and_store_w_score`（用于周中实时刷新 W 分的独立函数）仍使用旧的 `r.mean_duration`。若定时任务触发该函数，会用旧逻辑覆盖 W 分，与主评分函数结果不一致。

### 修复方案

在 `compute_and_store_w_score` 中加入同样的贝叶斯收缩逻辑：

```sql
CREATE OR REPLACE FUNCTION public.compute_and_store_w_score(p_student_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_mean_duration   FLOAT8;
  v_weekly_minutes  FLOAT8;
  v_elapsed_days    INT;
  v_ratio           FLOAT8;
  v_w_score         FLOAT8;
  v_dow             INT;
  v_week_start      TIMESTAMPTZ;
  -- FIX-37：贝叶斯收缩变量
  v_median_mean     FLOAT8;
  v_major           TEXT;
  v_major_count     INT;
  v_shrink_alpha    FLOAT8;
  v_effective_mean  FLOAT8;
BEGIN
  SELECT mean_duration, student_major
  INTO v_mean_duration, v_major
  FROM public.student_baseline
  WHERE student_name = p_student_name;

  -- FIX-37：同专业优先计算中位数（与 compute_student_score 对齐）
  SELECT COUNT(*) INTO v_major_count
  FROM public.student_baseline
  WHERE student_major = v_major AND mean_duration > 0;

  IF v_major_count >= 5 THEN
    SELECT percentile_cont(0.50) WITHIN GROUP (ORDER BY mean_duration)
    INTO v_median_mean
    FROM public.student_baseline
    WHERE mean_duration IS NOT NULL AND mean_duration > 0
      AND student_major = v_major;
  ELSE
    SELECT percentile_cont(0.50) WITHIN GROUP (ORDER BY mean_duration)
    INTO v_median_mean
    FROM public.student_baseline
    WHERE mean_duration IS NOT NULL AND mean_duration > 0;
  END IF;

  -- FIX-37：贝叶斯收缩
  SELECT record_count INTO v_shrink_alpha
  FROM public.student_baseline
  WHERE student_name = p_student_name;
  v_shrink_alpha   := LEAST(1.0, COALESCE(v_shrink_alpha, 0)::FLOAT8 / 15.0);
  v_effective_mean := v_shrink_alpha * COALESCE(v_mean_duration, 0.0)
                    + (1.0 - v_shrink_alpha) * COALESCE(v_median_mean, 30.0);
  v_effective_mean := GREATEST(v_effective_mean, 15.0);

  -- FIX-26：北京时间本周一 00:00:00
  v_week_start := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')
                    AT TIME ZONE 'Asia/Shanghai';

  SELECT COALESCE(SUM(cleaned_duration), 0) INTO v_weekly_minutes
  FROM public.practice_sessions
  WHERE student_name = p_student_name
    AND session_start >= v_week_start
    AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

  v_dow := EXTRACT(DOW FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INT;
  -- FIX-53-A：周日(DOW=0)视为本周已过5个工作日，与 compute_student_score 保持一致
  v_elapsed_days := CASE v_dow
    WHEN 0 THEN 5
    WHEN 6 THEN 5
    ELSE v_dow
  END;

  IF v_elapsed_days = 0 OR v_effective_mean <= 0 THEN
    v_w_score := 0.5;
  ELSE
    -- FIX-37：分母改为 v_effective_mean（贝叶斯收缩后基准）
    v_ratio   := v_weekly_minutes / (GREATEST(v_effective_mean, 30.0) * v_elapsed_days);
    v_w_score := 1.0 / (1.0 + EXP(-3.0 * (v_ratio - 0.5)));
  END IF;

  PERFORM set_config('app.skip_score_trigger', 'on', true);
  UPDATE public.student_baseline SET w_score = v_w_score WHERE student_name = p_student_name;
  PERFORM set_config('app.skip_score_trigger', 'off', true);
END;
$$;
```

### 部署后重算步骤（FIX-37 + FIX-38 合并）

```sql
-- 步骤 1：部署三个函数
--   compute_student_score（FIX-37 + FIX-38）
--   compute_student_score_as_of（FIX-37 + FIX-38）
--   compute_and_store_w_score（FIX-37b）

-- 步骤 2：全量历史重算（T 参数和基准均变更）
SELECT public.backfill_score_history();

-- 步骤 3：重算当前综合分（含 W）
SELECT public.compute_student_score(student_name)
FROM public.student_baseline
WHERE composite_score > 0 OR last_updated IS NOT NULL;

-- 步骤 4：同步当前周 W 分（确保与定时任务对齐）
SELECT public.compute_and_store_w_score(student_name)
FROM public.student_baseline;
```

---

## FIX-39：饭点检测逻辑修正——"相交"改为"完全跨越"（2026-03-17）

### 问题描述

FIX-30 中的 `meal_break` 异常检测使用了**"相交"**条件（session 与午/晚饭时段任意重叠即判定异常），导致大量正常练琴被误标：如 11:50~13:30 的练琴（午饭前结束）也被标记。

统计显示：修复前 1372 条记录被错误标记，系统 `median_outlier_rate` 高达 66.7%。

### 修复内容

**受影响函数**：`trigger_insert_session`

**旧逻辑（FIX-30 错误）**：
```sql
-- 与饭点时段"相交"即判定异常（11:50~12:30 或 17:50~18:30 有重叠）
v_spans_meal_break := v_dow BETWEEN 1 AND 5 AND (
    (v_start_time < '12:30:00'::TIME AND v_end_time > '11:50:00'::TIME)
    OR
    (v_start_time < '18:30:00'::TIME AND v_end_time > '17:50:00'::TIME)
);
```

**新逻辑（FIX-39 正确）**：
```sql
-- 必须"完全跨越"饭点：练琴从饭点开始前持续到饭点结束后（饭都没去吃）
v_spans_meal_break := v_dow BETWEEN 1 AND 5 AND (
    (v_start_time < '11:50:00'::TIME AND v_end_time > '12:30:00'::TIME)
    OR
    (v_start_time < '17:50:00'::TIME AND v_end_time > '18:30:00'::TIME)
);
```

### 历史数据修正

```sql
-- 将被错误标记的 meal_break 记录重新判断：
-- 只保留真正完全跨越饭点的会话，其余恢复为非异常
UPDATE public.practice_sessions
SET is_outlier     = FALSE,
    outlier_reason = NULL
WHERE outlier_reason = 'meal_break'
  AND NOT (
      -- 完全跨越午饭
      (EXTRACT(HOUR FROM session_start AT TIME ZONE 'Asia/Shanghai')*60
       + EXTRACT(MINUTE FROM session_start AT TIME ZONE 'Asia/Shanghai') < 710   -- 11:50
       AND EXTRACT(HOUR FROM session_end AT TIME ZONE 'Asia/Shanghai')*60
           + EXTRACT(MINUTE FROM session_end AT TIME ZONE 'Asia/Shanghai') > 750) -- 12:30
      OR
      -- 完全跨越晚饭
      (EXTRACT(HOUR FROM session_start AT TIME ZONE 'Asia/Shanghai')*60
       + EXTRACT(MINUTE FROM session_start AT TIME ZONE 'Asia/Shanghai') < 1070  -- 17:50
       AND EXTRACT(HOUR FROM session_end AT TIME ZONE 'Asia/Shanghai')*60
           + EXTRACT(MINUTE FROM session_end AT TIME ZONE 'Asia/Shanghai') > 1110) -- 18:30
  );
-- 修复了 1372 条误标记记录
```

### 修复效果

| 指标 | 修复前 | 修复后 |
|------|-------|-------|
| `sessions_to_fix` | 1372 | 0 |
| `median_outlier_rate` | 66.7% | 56.7% |

---

## FIX-41：前端 practice_duration 字段废弃——始终用时间戳计算时长（2026-03-17）

### 问题描述

前端传入的 `practice_duration` 字段存在严重 bug：1689 条记录该字段平均值为 8399 分钟（实际时间戳计算约 143 分钟），导致 `raw_duration` 被记录为几千分钟，大量会话被错误标记为 `too_long` 异常。

```
来自 practice_duration 字段：1689 条，avg_raw = 8399 分钟，avg_timestamp = 143 分钟
来自时间戳计算：4229 条，avg_raw = 373 分钟 ✓
```

### 修复内容

**受影响函数**：`trigger_insert_session`

**旧逻辑（依赖前端字段）**：
```sql
v_duration_seconds := NEW.practice_duration;  -- 直接使用前端传入值（可能有 bug）
```

**新逻辑（FIX-41，始终用时间戳）**：
```sql
-- 废弃 practice_duration 字段，始终从时间戳计算，防止前端 bug 污染
v_duration_seconds := EXTRACT(EPOCH FROM (v_clear_time - v_assign_time))::INTEGER;
```

### 历史数据修正

针对 1285 条受影响的记录（`raw_duration` 来自 `practice_duration` 字段且偏差巨大），重新用时间戳计算时长，并重新判断 `is_outlier` 和 `outlier_reason`。

### 修复效果

| 指标 | 修复前 | 修复后 |
|------|-------|-------|
| 受影响记录数 | 1285 | 0 |
| avg_actual_min | 86.6 | 86.6 (正常) |
| `median_outlier_rate` | 56.7% → | 50.0% |

---

## FIX-40：异常率惩罚软化——折点 0.40→0.60，斜率降低（2026-03-17）

### 问题描述

FIX-39 和 FIX-41 修复数据后，`median_outlier_rate` 仍为 50%，主要来源是合法的 `too_long` 会话（学生占琴房或未还卡，平均时长 6.2 小时，属于真实违规行为，应保留惩罚）。

但 FIX-29 的惩罚公式对 50% 异常率时惩罚系数仅 0.485，导致：
- 中位数综合分仅 28，P75 仅 48
- 177/191 学生（92.7%）受到超过 15% 的惩罚
- 分值区分度极低，学生努力练琴的效果被大幅压缩

### 修复内容

**受影响函数**：`compute_student_score`、`compute_student_score_as_of`

**旧公式（FIX-29）**：
```sql
-- 折点 0.40，斜率 0.5（线性段） + 5.0（指数段）
outlier_penalty := CASE
    WHEN outlier_rate <= 0.40
        THEN 1.0 - 0.5 * outlier_rate
    ELSE
        0.80 * EXP(-5.0 * (outlier_rate - 0.40))
END;
```

**新公式（FIX-40）**：
```sql
-- FIX-40：折点 0.4→0.60，斜率降低
-- 连续性验证：1.0 - 0.4×0.60 = 0.76 = 0.76×EXP(0) ✓
outlier_penalty := CASE
    WHEN COALESCE(r.outlier_rate, 0.0) <= 0.60
        THEN 1.0 - 0.4 * COALESCE(r.outlier_rate, 0.0)
    ELSE 0.76 * EXP(-3.0 * (COALESCE(r.outlier_rate, 0.0) - 0.60))
END;
```

### 惩罚系数对照表

| outlier_rate | FIX-29（旧） | FIX-40（新） | 变化 |
|---|---|---|---|
| 0% | 1.00 | 1.00 | 0 |
| 20% | 0.90 | **0.92** | +0.02 |
| 40% | 0.80 | **0.84** | +0.04 |
| 50% | 0.49 | **0.80** | **+0.31** |
| 60% | 0.29 | **0.76** | **+0.47** |
| 70% | 0.18 | 0.56 | +0.38 |
| 80% | 0.11 | 0.41 | +0.30 |
| 100% | 0.04 | 0.22 | +0.18 |

> 0~60% 线性段最多扣 24%（旧：折点 40% 处扣 20%）；>60% 指数衰减更温和（k=3.0 vs 旧 k=5.0）。

### 修复效果（191 名学生，2026-03-17 验证）

| 指标 | FIX-29（旧） | FIX-40（新） |
|------|------------|------------|
| P25 综合分 | ~14 | **22** |
| 中位数综合分 | 28 | **39** |
| P75 综合分 | 48 | **48** |
| P90 综合分 | ~58 | **62** |
| 高分(≥60)人数 | ~9 | **24** |
| 高分(≥50)人数 | ~48 | **95** |

---

---

## FIX-42：M 维度达标阈值 70%→60%（2026-03-17）

### 问题描述

当前 70% 阈值下，158 名有足够历史数据的学生中，仅 14 人（8.9%）在近 4 个活跃周内全部达标，33 人（20.9%）从未达标。而学生实际周均完成率中位数为 0.85，说明均值不差但周内波动大，导致"全达标"门槛过高，M 维度正向激励效果弱。

| 阈值 | 始终达标（4/4周） | 百分比 |
|------|---------------|-------|
| 80% | 10 人 | 6.3% |
| **70%（旧）** | 14 人 | 8.9% |
| **60%（新）** | 26 人 | 16.5% |

### 修复内容

**受影响函数**：`compute_student_score`、`compute_student_score_as_of`

```sql
-- 旧（FIX-34-B，阈值 70%）
IF m_rec.weekly_mins >= GREATEST(v_effective_mean, 30.0) * 5.0 * 0.70 THEN

-- 新（FIX-42，阈值 60%）
IF m_rec.weekly_mins >= GREATEST(v_effective_mean, 30.0) * 5.0 * 0.60 THEN
```

---

## FIX-52：M 维度改为4自然周日历窗口+固定分母（2026-03-19）

### 问题描述

M 动量分基本全员满分（1.0），失去区分意义。

### 根本原因（双重 bug）

**Bug 1（主因）：可变分母 `m_w_total` 导致全达标恒=1.0**

旧公式：`m_score = m_weighted_sum / m_total_weight`

`m_total_weight` 只累积"实际找到的活跃周"的权重。只要找到的 1~4 个活跃周全部满足达标线，分子等于分母，m_score 永远=1.0：

| 活跃周数 | 全达标时 m_score |
|---------|----------------|
| 1 周    | 1.0/1.0 = **1.00** |
| 2 周    | 1.65/1.65 = **1.00** |
| 3 周    | 2.07/2.07 = **1.00** |
| 4 周    | 2.34/2.34 = **1.00** |

**Bug 2（次因）：仅统计活跃周，零练琴周完全免责**

`HAVING SUM(...) > 0` + `LIMIT 4` 自动跳过空白周。学生只要"在练琴的那几周达标"就得满分，中间空窗期毫无惩罚。

### 修复内容（FIX-52）

**受影响函数**：`compute_student_score`、`compute_student_score_as_of`

改为 4 个**自然日历周**窗口（`generate_series(1, 4)`），每周若无练习记录则记 0 分钟（不达标），分母固定为 **2.34**：

```sql
-- ══════════════════════════════════════════════════════════════
-- 10. M 维度 (FIX-52: 4自然周日历窗口，固定分母2.34)
--     近4自然周（含零练琴周）加权达标率，权重 1.0/0.65/0.42/0.27
-- ══════════════════════════════════════════════════════════════
FOR m_rec IN
  SELECT
    gs.wk_offset,
    COALESCE(
      (SELECT SUM(ps2.cleaned_duration)
       FROM   public.practice_sessions ps2
       WHERE  ps2.student_name     = p_student_name
         AND  ps2.cleaned_duration > 0
         AND  EXTRACT(DOW FROM ps2.session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
         AND  DATE_TRUNC('week', ps2.session_start AT TIME ZONE 'Asia/Shanghai') =
              DATE_TRUNC('week',
                (v_week_start_bjt - gs.wk_offset * INTERVAL '1 week')
                AT TIME ZONE 'Asia/Shanghai')
      ), 0.0) AS weekly_mins
  FROM generate_series(1, 4) AS gs(wk_offset)
  ORDER BY gs.wk_offset
LOOP
  m_wk_num       := m_wk_num + 1;
  m_weight       := POWER(0.65, m_wk_num - 1);
  m_total_weight := m_total_weight + m_weight;
  IF m_rec.weekly_mins >= GREATEST(v_effective_mean, 30.0) * 5.0 * 0.60 THEN
    m_weighted_sum := m_weighted_sum + m_weight;
    m_weeks_met   := m_weeks_met + 1;
  END IF;
END LOOP;

-- FIX-52: 固定分母2.34（满4自然周权重之和），缺练周自然拉低分数
m_score := CASE
  WHEN hist_count < 2 THEN 0.5   -- 冷启动：数据不足取中性值
  ELSE m_weighted_sum / 2.34
END;
```

### 修复后 M 分典型值对照

| 达标情况（最近→最早）| 旧 m_score | 新 m_score |
|-------------------|-----------|-----------|
| 4/4 周达标         | **1.00**  | **1.00** |
| 最近3周达标，最早1周缺练 | **1.00** | 2.07/2.34 ≈ **0.88** |
| 最近2周达标，较早2周缺练 | **1.00** | 1.65/2.34 ≈ **0.71** |
| 仅最近1周达标        | **1.00** | 1.00/2.34 ≈ **0.43** |
| 0/4 周达标          | 0.00     | 0.00 |
| 无历史（冷启动）      | 0.50     | 0.50 |

### 部署步骤

```sql
-- 1. 运行 fix44_46_score_functions.sql（含 FIX-52 更新的完整函数）

-- 2. 全量历史重算（M 分全部需要重算）
SELECT public.backfill_score_history();

-- 3. 验证：检查 M 分分布，应不再集中于1.0
SELECT
  ROUND(momentum_score::NUMERIC, 1) AS m_bucket,
  COUNT(*) AS cnt
FROM public.student_baseline
WHERE momentum_score IS NOT NULL
GROUP BY 1
ORDER BY 1;
```

---

## FIX-53：四处系统级漏洞修复（2026-03-19）

> 来源：全面代码审查（经 AI 辅助分析 `fix44_46_score_functions.sql` 与本文档交叉验证）

---

### FIX-53-A：周日 W 分恒=0.5（高危）

**问题**：`v_elapsed_days := CASE v_dow WHEN 0 THEN 0 ...`  
PostgreSQL `DOW=0` 代表**周日**（不是新的一周开始）。周日时 `v_elapsed_days=0`，导致 `IF v_elapsed_days > 0` 条件失败，w_score 保持初始值 0.5，整周练习数据被完全无视。

**受影响**：每逢周日查看的排行榜 W 维度全员归中性，本周练习消失。

**修复**：
```sql
-- 旧
v_elapsed_days := CASE v_dow WHEN 0 THEN 0 WHEN 6 THEN 5 ELSE v_dow END;

-- 新（FIX-53-A）
v_elapsed_days := CASE v_dow WHEN 0 THEN 5 WHEN 6 THEN 5 ELSE v_dow END;
```

---

### FIX-53-B：`peak_decay` cap 绕过贝叶斯收缩（中危）

**问题**：FIX-37 引入贝叶斯收缩（`v_effective_mean`），B/T/M/W 全部改用收缩均值，但 `peak_decay` 的 cap 仍使用原始 `r.mean_duration`：

```sql
-- 旧（绕过贝叶斯，新生高均值未被收缩）
v_peak_weekly_avg := COALESCE(v_peak_weekly_avg, GREATEST(r.mean_duration, 30.0) * 5.0);
v_peak_weekly_avg := LEAST(v_peak_weekly_avg, GREATEST(r.mean_duration, 30.0) * 5.0 * 1.6);
```

新生首次练琴时长极端（如 120 分钟），`r.mean_duration=120` 但 `v_effective_mean≈40`，cap 被虚高撑至 960 分钟（应为 320 分钟），导致 peak_decay 阈值失效。

**修复**：
```sql
-- 新（FIX-53-B，与其他维度统一）
v_peak_weekly_avg := COALESCE(v_peak_weekly_avg, GREATEST(v_effective_mean, 30.0) * 5.0);
v_peak_weekly_avg := LEAST(v_peak_weekly_avg, GREATEST(v_effective_mean, 30.0) * 5.0 * 1.6);
```

---

### FIX-53-C：停练冻结写 0 分与 FIX-12 设计相悖（中危）

**问题**：停练 >30 天冻结分支写入 `composite_score=0`，FIX-12 文档明确记录应"保留最后冻结分"。手动调用 `compute_all_student_scores()` 时会误将停练学生历史全部清零。

**修复**：
```sql
-- 旧
VALUES (p_student_name, v_week_monday, 0, 0.0, ...)

-- 新（FIX-53-C）
VALUES (p_student_name, v_week_monday,
        COALESCE(r.composite_score, 0), COALESCE(r.raw_score, 0.0), ...)
```

---

### FIX-53-D：M 冷启动条件与数据源脱节（低危）

**问题**：FIX-52 将 M 数据源改为直接读 `practice_sessions`，但冷启动判断仍用 `hist_count < 2`（基于 `student_score_history`）。系统初始化/backfill 过渡期可能误触发：学生已有4周练习数据，但 hist_count=0，导致 M 恒=0.5。

**修复**：
```sql
-- 旧
m_score := CASE WHEN hist_count < 2 THEN 0.5 ELSE m_weighted_sum / 2.34 END;

-- 新（FIX-53-D，与 M 数据源对齐）
m_score := CASE
  WHEN m_weighted_sum = 0 AND NOT EXISTS (
    SELECT 1 FROM public.practice_sessions
    WHERE student_name = p_student_name AND cleaned_duration > 0
      AND session_start < v_week_start_bjt LIMIT 1
  ) THEN 0.5
  ELSE m_weighted_sum / 2.34
END;
```

---

### FIX-53-E：W 分双源消除——`compute_student_score` 同步写入 `student_baseline.w_score`（中危）

**问题**：W 分在两处独立计算（`compute_student_score` 内部 + `compute_and_store_w_score`），每次修改 W 公式需同步两处，FIX-26 已因此出现静默偏差。

**修复**：在 `compute_student_score` 的 `UPDATE student_baseline` 中添加 `w_score = w_score`，确保每次全量重算后 `student_baseline.w_score` 始终与 composite_score 来自同一次计算。

```sql
-- fix44_46_score_functions.sql，UPDATE student_baseline 段新增一行：
w_score = w_score,   -- FIX-53-E
```

---

### FIX-53-F：`backfill_score_history` 结尾自动刷新 W 分（低危）

**问题**：backfill 只重算历史周快照，不更新 `student_baseline.w_score`，导致 backfill 后前端 W 卡片显示旧值，直到下次练琴触发器才更新。

**修复**：在 `backfill_score_history`（`fix15_week_aware_score.sql`）步骤 ④ 后，添加对所有学生调用 `compute_and_store_w_score` 的循环（步骤 ⑤）。

---

### FIX-53-G：批量修正 SQL 添加触发器屏蔽包裹（中危）

**问题**：任何对 `practice_sessions` 的批量 UPDATE（FIX-51、FIX-50 等历史修正 SQL）都会触发全链路计算（每行触发 baseline → score 重算），产生大量中间状态快照，性能差且结果不正确。

**修复**：`fix_stale_cleaned_duration.sql` 的 DELETE/UPDATE 操作前后增加：

```sql
-- 操作前
SELECT set_config('app.skip_score_trigger', 'on', false);

-- 操作后
SELECT set_config('app.skip_score_trigger', 'off', false);
```

> ⚠️ 所有未来的批量历史修正 SQL 都必须遵循此模式。

---

### FIX-53-H：`clean_duration` 停练归来降级为全局检测（中危）

**问题**：停练 >30 天回来的学生，`student_baseline` 仍是旧均值。若旧均值低（如 mean=40min, std=8min），新的 90 分钟练习 > 40+3×8=64min，被错误标记为 `personal_outlier` 并截断。

**修复**：`clean_duration`（`baseline_fixes_v1.sql`）中添加"最近练琴时间间隔"检测：

```sql
-- 查询最近一次练琴时间间隔
SELECT MAX(session_start) INTO last_session_date
FROM public.practice_sessions
WHERE student_name = student AND cleaned_duration > 0;

days_since_last := COALESCE(EXTRACT(DAYS FROM (NOW() - last_session_date))::INTEGER, 999);

-- 停练 > 30 天：不使用个人离群检测，降级为全局硬上限
use_personal_det := ... AND days_since_last <= 30;  -- FIX-53-H 新增条件
```

新增 `outlier_reason = 'global_cap_returning'` 标记，与冷启动的 `global_cap_cold_start` 区分。

---

### 已知遗留问题（架构限制，无实用修复方案）

| # | 问题 | 影响 | 说明 |
|---|------|------|------|
| 问题4 | `as_of` 函数 A 维度 IQR 使用当前而非历史学生分布 | 历史回填时 A 分跨年可比性 | 需新建历史分布快照表，改动面过大 |

### 部署步骤（含 FIX-53 全部修复）

```sql
-- 1. 运行 fix44_46_score_functions.sql（含 FIX-52/FIX-53-A/B/C/D/E）
-- 2. 运行 fix15_week_aware_score.sql（含 FIX-53-F：backfill + w_score 刷新）
-- 3. 运行 baseline_fixes_v1.sql（含 FIX-53-H：clean_duration）
-- 4. 全量历史重算（自动刷新 w_score）
SELECT public.backfill_score_history();
-- 5. 刷新当前周分数
SELECT public.compute_all_student_scores();
```

---

## FIX-54：`compute_and_store_w_score` 周日(DOW=0)漏洞（2026-03-19）

### 问题描述

FIX-53-A 修复了 `compute_student_score` 内联 W 分计算的周日问题，但独立函数 `compute_and_store_w_score`（被 `backfill_score_history` 末尾调用）未同步更新，仍保留旧逻辑：

```sql
-- 旧（错误）：周日 elapsed_days=0 → w_score 强制为 0.5
v_elapsed_days := CASE v_dow WHEN 0 THEN 0 WHEN 6 THEN 5 ELSE v_dow END;
```

**影响**：每当周日执行 `backfill_score_history()`，所有学生的 `student_baseline.w_score` 被覆盖为 0.5，整周练琴数据被无视。

### 修复（fix54_w_score_sunday.sql）

```sql
-- 新（正确）：与 compute_student_score 一致
v_elapsed_days := CASE v_dow WHEN 0 THEN 5 WHEN 6 THEN 5 ELSE v_dow END;
```

---

## FIX-56：反霸榜三项优化（2026-03-19）

### 问题描述

系统存在中度霸榜风险：高练量 + 稳定练习的学生因 B/T 绝对水平分量长期加成，无需进步就能占据排名优势；M 门槛过低（60%）导致所有规律练琴学生 M 均为满分，丧失区分度；W 权重偏低导致每周实际努力对排名影响不足。

**核心矛盾**：评分系统 90% 应是"自身对比"，但 B/T 的 35% 绝对水平分量引入了永久性练量优势，破坏了公平性。

### 修复内容

#### 修复一：B/T 绝对水平分量 35% → 20%

| | 旧（FIX-44）| 新（FIX-56）|
|--|------------|------------|
| B | `0.65 × b_change + 0.35 × b_level` | `0.80 × b_change + 0.20 × b_level` |
| T | `0.65 × t_change + 0.35 × t_level` | `0.80 × t_change + 0.20 × t_level` |

**效果**：高练量稳定学生的 B/T 从 0.658 降至约 0.573，与均值进步学生（0.594）接近，排名更多取决于"是否在提升"。

#### 修复二：M 达标线 60% → 100%

```sql
-- 旧：任何规律练琴学生均可轻松满分
IF m_rec.weekly_mins >= GREATEST(v_effective_mean, 30.0) * 5.0 * 0.60

-- 新：需达到自己的周均水平，真正衡量练习强度
IF m_rec.weekly_mins >= GREATEST(v_effective_mean, 30.0) * 5.0 * 1.00
```

**效果**：M 恢复区分度。状态好的周（≥均值）得分，偷懒的周（<均值）失分，真实反映坚持质量。

#### 修复三：hist≥12 权重调整（资深学生）

| 维度 | 旧权重 | 新权重 |
|------|--------|--------|
| B | 25% | **22%** |
| T | 25% | **22%** |
| M | 15% | 15% |
| A | 10% | **11%** |
| W | 25% | **30%** |
| 合计 | 100% | **100%** |

**效果**：W 从 25% 提升到 30%，每周实际练习努力对排名影响更直接，排行榜每周流动性增强。

### 修改后各场景评分对比（hist≥12）

| 学生类型 | B | T | M | A | W | 综合分（修改后）|
|--------|---|---|---|---|---|--------------|
| 高练量 + 同时进步 | 0.77 | 0.77 | 0.71 | 0.8 | 0.89 | **80分** ↓7 |
| 高练量 + 已停止进步 | 0.57 | 0.57 | 0.43 | 0.8 | 0.50 | **55分** ↓13 |
| 均值 + 积极进步 | 0.57 | 0.57 | 0.43 | 0.5 | 0.89 | **64分** ↓3 |
| 均值 + 稳定练习 | 0.50 | 0.50 | 0.71 | 0.5 | 0.50 | **57分** ↑2 |

关键变化：高练量停滞学生从 68 分降至 55 分，不再凭借历史积累压制积极进步的普通学生。

### 部署

```sql
-- 运行 fix44_46_score_functions.sql（已含全部 FIX-56 修改）
-- 重建历史快照
SELECT public.backfill_score_history();
```

---

## FIX-64：稳定榜 & 守则榜科学重设计（2026-03-19）

### 稳定榜 问题描述

原排序为 `mean_dur DESC`（谁练得最久），但"稳定"的科学定义是**练琴行为可预测、不波动**，应以 `α`（基线可信度）为主排序键。`α` 越高，代表该学生的练琴模式越稳定规律。原设计把 `α` 当过滤门槛使用，却不当主排序键，是概念错位。

### 稳定榜 修复内容（`leaderboard_rpc.sql`）

| 项目 | 旧逻辑 | FIX-64 |
|------|--------|--------|
| 主排序键 | `mean_dur DESC`（时长最长） | **`α DESC`（一致性/可预测性）** |
| 次排序键 | `α DESC` | `mean_dur DESC`（同等稳定时，时长更长者排前） |
| 三级排序 | 无 | `outlier_rate ASC`（最终区分） |
| α 门槛 | `>= 0.65` | `>= 0.55`（略微放宽） |
| 近10条数量 | `>= 10` | `>= 8`（近12周约每10天一次即可） |
| 异常率 | `<= 0.35` | `<= 0.40`（略微放宽） |

### 守则榜 问题描述

`week_sessions >= 5` 要求本周练满 5 次（相当于每个工作日均到），是最严苛的单一条件。与其他 4 个条件叠加后，榜单极易为空。"守则"的科学定义是**出勤达标 + 合规（低异常率）+ 时长合格**，并非要求满勤。

### 守则榜 修复内容（`leaderboard_rpc.sql`）

| 项目 | 旧逻辑 | FIX-64 |
|------|--------|--------|
| 本周次数门槛 | `>= 5`（几乎满勤） | **`>= 3`（一周至少3天，合规出勤）** |
| 近10条数量 | `>= 5` | `>= 4`（略微放宽） |
| 平均时长 | `> 30min` | `> 25min`（略微放宽，防走过场仍有效） |
| 异常率门槛 | `<= 0.50` | `<= 0.50`（保持） |
| α 门槛 | `>= 0.60` | `>= 0.55`（对齐稳定榜） |
| 排序逻辑 | `outlier_rate ASC, week_sessions DESC, mean_dur DESC` | 保持不变（正确） |

### 部署方式

```sql
-- 执行 leaderboard_rpc.sql 重新部署 get_weekly_leaderboards()
```

---

## FIX-63：进步榜最小必要门槛设计（2026-03-19）

### 问题描述

经过 FIX-58（收紧）→ FIX-61（放宽）两轮调整后，进步榜仍仅有 1 人上榜。根因是多个独立阈值条件叠加（"分数绝对值"门槛 + α + 异常率 + 次数 + 涨幅），每个条件各自淘汰一批人，组合效果过于严苛。

### 设计原则重构

> **过滤条件只"防假"，不"防小"。**  
> 小进步也是进步，由排名决定位次。取消与"进步"概念无关的分数绝对值门槛。

### 修复内容（`leaderboard_rpc.sql`）

| 条件 | FIX-61 | FIX-63 | 理由 |
|------|--------|--------|------|
| 上周基准分 | `>= 20` | **删除** | 有绝对涨分排序，无需另设基准线 |
| 本周综合分 | `>= 30` | **删除** | 与"进步"概念无关 |
| α 可信度 | `>= 0.50` | **删除** | 新生也应能上进步榜 |
| 本周练琴次数 | `>= 2` | `>= 2` | 保留，最低参与度保证 |
| 绝对涨幅 | `>= 3 分` | `> 0`（任意正增长）| 涨多少由排名决定 |
| 近10条异常率 | `<= 0.40` | `<= 0.50` | 适度放宽，只防明显刷数据 |
| 综合榜 Top10 | 排除 | 排除 | FIX-65 由 Top5 扩至 Top10 |

同时修复了 `trend_score` 计算中 `lw_composite` 为 0 时的除零风险，改为 `NULLIF(lw_composite, 0)`。

### 部署方式

```sql
-- 执行 leaderboard_rpc.sql 重新部署 get_weekly_leaderboards()
```

---

## FIX-62：`backfill_score_history` 覆写当前基线 Bug（2026-03-19）

### 问题描述

`public.backfill_score_history()` 在回溯历史时，会按周循环调用 `compute_baseline_as_of(student, 本周一)`。  
由于最后一次循环的截止日期恰好是"本周一"，函数会把 `student_baseline` 表**整体覆写为截止本周一的历史快照**，导致本周一之后录入的所有练琴记录从基线消失。

**典型案例**：  
学生梁书一有 9 条本周工作日有效记录，但每次执行 `run_weekly_score_update()`（内部调用 `backfill`）后 `record_count` 变回 1，9 条记录被"抹去"。

### 根本原因

```sql
-- backfill 循环末段（旧版）：
-- 最后一轮 v_current_date = DATE_TRUNC('week', CURRENT_DATE)（本周一）
-- 以下调用把所有学生基线"刷回"本周一的历史状态
PERFORM public.compute_baseline_as_of(v_student.student_name, v_current_date);
-- 循环结束后再无补救步骤 → 本周的新记录全部丢失
```

### 修复内容（`fix53_backfill_update.sql`）

在 backfill 主循环结束后**新增步骤⑤**，为所有学生重新调用 `compute_baseline()`（等价于截止 `CURRENT_DATE + 1 day`），将基线恢复到最新状态：

```sql
-- ⑤ FIX-62: 回溯完成后，用今天重新刷新所有学生基线
FOR v_student IN
    SELECT student_name FROM public.student_baseline ORDER BY student_name
LOOP
    BEGIN
        PERFORM public.compute_baseline(v_student.student_name);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING '[backfill rebase] % 失败：%',
            v_student.student_name, SQLERRM;
    END;
END LOOP;
```

原步骤⑤（`compute_and_store_w_score`）顺延为步骤⑥。

### 影响范围

| 场景 | 旧版行为 | 修复后行为 |
|------|---------|-----------|
| 每周日执行 `run_weekly_score_update()` | 本周一后的记录从基线消失 | 基线始终反映截止今天的最新数据 |
| 手动重刷历史（backfill） | 同上 | 同上 |
| 单独调用 `compute_baseline(student)` | 不受影响 | 不受影响 |

### 部署方式

```sql
-- 执行 fix53_backfill_update.sql（已含步骤⑤）
-- 重新部署 backfill_score_history 函数即可
```

### 前端联动（`practiceanalyse.html`）

同步修复了前端练习分析页面的记录数展示逻辑，新增分类计数说明：

- 引入 `totalFetched`（总条数）、`weekendFetched`（周末条数）、`cleanedZeroFetched`（时长清零条数）三个统计变量
- 当存在周末或清零记录时，`recordCountLabel` 展示完整说明，例如：

  ```
  📋 1 条工作日有效 · 共 9 条（8 条时长过短/异常被清零）
  ```

- `coldNote` 冷启动提示同步增加同类说明，避免用户误以为数据丢失

---

## FIX-60：独立部署 `run_weekly_score_update` + `trigger_update_student_baseline`（2026-03-19）

### 问题描述

`check_db_versions.sql` 诊断显示数据库中的 `run_weekly_score_update()` 和 `trigger_update_student_baseline()` 仍是旧版本，需要重新部署。

直接运行 `baseline_fixes_v1.sql`（历史汇总文件）时报错：

```
ERROR: 42P13: cannot change return type of existing function
DETAIL: Row type defined by OUT parameters is different.
HINT: Use DROP FUNCTION compute_student_score(text) first.
```

### 根本原因

`baseline_fixes_v1.sql` 是早期汇总文件，同时包含 `compute_student_score` / `compute_student_score_as_of` 的旧版签名（OUT 参数不同于当前 `fix44_46_score_functions.sql` 部署的版本）。PostgreSQL 不允许直接修改已有函数的返回类型，导致整个脚本执行中断。

### 修复内容

新建 **`fix60_weekly_update_and_baseline_trigger.sql`**，仅包含两个需要更新的函数，**不含其余任何函数**：

| 函数 | 说明 |
|------|------|
| `public.run_weekly_score_update()` | 每周日定时任务：调用 backfill + 全量 W 分刷新（FIX-8） |
| `public.trigger_update_student_baseline()` | 触发器函数：`practice_sessions` 插入/更新时刷新对应学生基线（FIX-9） |

### 经验与规范

> **规范**：今后每次需要部署函数时，若目标函数与历史汇总文件中的其他函数存在签名冲突，应单独新建 `fixNN_xxx.sql` 文件，只包含需要更新的函数，避免整包覆盖导致签名冲突。

### 部署方式

```sql
-- 执行 fix60_weekly_update_and_baseline_trigger.sql（仅含上述两个函数）
```

---

## FIX-65：综合榜 Top 10 退出专项榜（2026-03-19）

### 问题描述

FIX-59 将综合榜 **Top 5** 排除在专项榜之外；实际运营中仍易出现综合强者同时占据多个专项榜前列，希望进一步扩大差异化。

### 修复内容（`leaderboard_rpc.sql`）

- CTE 由 `comp_top5` 重命名为 **`comp_top10`**
- 条件由 `rank_no <= 5` 改为 **`rank_no <= 10`**
- 进步榜 / 稳定榜 / 守则榜统一：`NOT IN (SELECT student_name FROM comp_top10)`

### 效果

综合榜前 **10 名** 不再进入三个分类榜，专项榜名额更多留给综合分未进前十、但在进步/稳定/守则有亮点的学生。

---

## FIX-59：综合榜 Top 5 退出专项榜（2026-03-19）

> **已由 FIX-65 升级为 Top 10**：本节保留历史说明；当前线上以 `comp_top10`、`rank_no <= 10` 为准。

### 问题描述

同一个学生（如王晗如）同时出现在综合榜、进步榜、稳定榜、守则榜四个榜的前十，四个榜失去了差异化激励的意义。

**设计原则**：四个榜的目的是让更多学生都能获得表彰。综合榜前列已获最高荣誉，专项榜应当展示其他有特定优势的学生，覆盖更广泛的激励群体。

### 修复内容（`leaderboard_rpc.sql`，初版）

初版新增 `comp_top5` CTE，取综合榜排名 ≤ 5 的学生名单，在进步榜、稳定榜、守则榜的 `WHERE` 条件中统一排除：

```sql
AND student_name NOT IN (SELECT student_name FROM comp_top5)
```

### 效果

- 综合榜：不受影响，仍显示全部排名
- 进步榜 / 稳定榜 / 守则榜：综合榜 Top 5（现 **Top 10**，见 FIX-65）学生自动退出，名额让给其他学生
- 单次查询内用 CTE 实现，无额外数据库开销

### 部署方式

```sql
-- 执行 leaderboard_rpc.sql 重新部署 get_weekly_leaderboards()
```

---

## FIX-58：进步榜改绝对涨分排序 + 收紧门槛（2026-03-19）

### 问题描述

进步榜原本按 **百分比涨幅** `(本周分 - 上周分) / 上周分 × 100%` 排序，导致"低基数虚高"现象：上周几乎不练（得分 10~15）、本周稍微练一点的学生，百分比涨幅反而最大，霸占进步榜第一。

**典型案例**：
- 学生 A：12 分 → 18 分，涨幅 **+50%**，排第一
- 学生 B：60 分 → 78 分，涨幅 **+30%**，排第三

学生 A 本周实际练习量远少于学生 B，但因基数低导致百分比虚高。

### 修复内容（`leaderboard_rpc.sql`）

| 项目 | 旧逻辑 | FIX-58（过严）| FIX-61（平衡）|
|------|--------|--------------|--------------|
| 排序依据 | 百分比涨幅 DESC | **绝对涨分** DESC | 绝对涨分 DESC |
| 上周基准门槛 | `>= 10` | `>= 35` | **`>= 20`** |
| 本周综合分门槛 | `>= 15` | `>= 45` | **`>= 30`** |
| 本周练琴次数 | 无要求 | `>= 3` 次 | **`>= 2`** 次 |
| 最小涨幅 | `> 0` | `>= 5` 分 | **`>= 3`** 分 |
| 近10条异常率 | `<= 0.70` | `<= 0.40` | `<= 0.40` |

**FIX-61 背景**：FIX-58 门槛过于苛刻导致进步榜无人上榜。放宽原则是只保留"防低基数虚高"的核心约束，其余条件调整到合理的最低值。

百分比涨幅仍作为展示字段（`trend_score`）供前端显示 `+XX.X%`，但不再参与排序。

### 部署方式

```sql
-- 执行 leaderboard_rpc.sql 重新部署 get_weekly_leaderboards()
```

---

## FIX-57：A 维度新生保护 — quality_score Bug + 新生权重优化（2026-03-19）

### 问题一（Bug）：`quality_score` 使用原始 `mean_duration`

**问题描述**：

A 维度的 `quality_score` 原本使用 `r.mean_duration`（未经贝叶斯收缩的原始均值）：

```sql
-- 旧（有 bug）
quality_score := GREATEST(0.0, LEAST(1.0,
    0.5 + (COALESCE(r.mean_duration, 0.0) - COALESCE(median_mean, 0.0))
        / (2.0 * pop_iqr)));
```

新生前几次若练习偏短（如 15~25 分钟），`r.mean_duration` 可能远低于班级中位数，导致 `quality_score → 0`，进而 `a_score → 0`，在 A 权重 25% 的情况下最多拉低综合分 13 分。

其他维度（B/T/M/W）均已使用 `v_effective_mean`（含贝叶斯收缩保护），A 维度存在逻辑不一致。

**修复**：改用 `v_effective_mean`，与其他维度保持一致

```sql
-- 新（FIX-57）
quality_score := GREATEST(0.0, LEAST(1.0,
    0.5 + (v_effective_mean - COALESCE(median_mean, 0.0))
        / (2.0 * pop_iqr)));
```

`v_effective_mean` 在 `record_count = 0` 时等于全班中位数，随记录数增加逐渐信任个人值（15 条后完全个人化）。

### 问题二（设计）：新生阶段 A 权重过高

**问题描述**：

`hist_count < 4`（新生）时，旧权重配置：

| 维度 | B | T | M | A | W |
|------|---|---|---|---|---|
| 旧权重 | 10% | 10% | 5% | **25%** | 50% |

A 维度记录数越少分越低，但权重反而最高，逻辑上不合理。

**修复**：降低 A 权重至 10%，W 提升至 70%，由本周实际练习量主导评价

| 维度 | B | T | M | A | W |
|------|---|---|---|---|---|
| 旧权重 | 10% | 10% | 5% | 25% | 50% |
| 新权重（FIX-57）| 8% | 8% | 4% | **10%** | **70%** |

### 修复后效果对比（新生第1周，3条记录）

| 场景 | 旧综合分 | 新综合分 | 提升 |
|------|---------|---------|------|
| 每天练30分，略低班级均值 | ~40分 | ~62分 | **+22分** |
| 每天练45分，接近班级均值 | ~52分 | ~70分 | **+18分** |
| 每天练60分，超过班级均值 | ~63分 | ~76分 | **+13分** |

### 影响范围

- `compute_student_score`（实时计算）
- `compute_student_score_as_of`（历史回填）

### 部署方式

```sql
-- 运行 fix44_46_score_functions.sql（已含全部 FIX-57 修改）
-- 重建历史快照以更新新生早期分数
SELECT public.backfill_score_history();
```

---

## FIX-55：`compute_baseline_as_of` 全面过滤周末数据（2026-03-19）

### 问题描述

`compute_baseline_as_of` 计算以下指标时未过滤周六（DOW=6）、周日（DOW=0）：

| 字段 | 影响 |
|------|------|
| `mean_duration` | 被周末长时练琴拉高，导致 M/W 达标阈值虚高 |
| `std_duration` | 周末波动纳入，std 偏大，个人离群检测门槛偏宽 |
| `record_count` | 计入周末场次，A 维度积累分轻微虚高 |
| `outlier_rate` / `short_session_rate` | 周末课外练琴的异常比例影响异常率统计 |
| `weekday_pattern` | 周末场次混入工作日分布统计 |

所有 B/T/M/W 维度只统计工作日，但基线阈值（`mean_duration`）却包含周末，造成系统性不一致。

### 修复（fix55_baseline_weekday_filter.sql）

**6 个查询位置**均加 `NOT IN (0, 6)` 过滤（含之前遗漏的 meta 查询）：

| # | 位置 | 修复内容 |
|---|------|---------|
| ① | meta 查询 | 避免仅有周末记录的学生读取错误的专业/年级 |
| ② | `recent_valid` CTE | mean_duration / std / record_count 仅统计工作日 |
| ③ | 异常率 & 短时率子查询 | outlier_rate / short_session_rate 仅统计工作日 |
| ④ | `recent_dow` CTE | weekday_pattern 仅含周一~周五 |
| ⑤ | 冷启动同专业同年级参照 | 群体基准不受周末练琴影响 |
| ⑥ | 冷启动降级同专业参照 | 同上 |

同时同步了 **FIX-47 alpha 分段加速惩罚公式**（旧 `baseline_fixes_v1.sql` 用的是旧线性公式）。

### 当前完整函数代码

```sql
CREATE OR REPLACE FUNCTION public.compute_baseline_as_of(
    p_student_name TEXT,
    p_as_of_date   DATE
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_mean          FLOAT;
    v_std           FLOAT;
    v_count         INTEGER;
    v_outlier_rate  FLOAT;
    v_short_rate    FLOAT;
    v_alpha         FLOAT;
    v_cv            FLOAT;
    v_group_alpha   FLOAT;
    v_lambda        FLOAT;
    v_weekday_json  JSONB;
    v_student_major TEXT;
    v_student_grade TEXT;
    v_last_updated  TIMESTAMPTZ;
BEGIN
    -- ① meta 信息（截止日期前最近一条工作日练琴）
    SELECT student_major, student_grade
    INTO v_student_major, v_student_grade
    FROM public.practice_sessions
    WHERE student_name  = p_student_name
      AND session_start < p_as_of_date::TIMESTAMPTZ
      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
    ORDER BY session_start DESC
    LIMIT 1;

    IF NOT FOUND THEN RETURN; END IF;

    -- ② 有效记录：截止日期前最近30条工作日记录
    WITH recent_valid AS (
        SELECT cleaned_duration
        FROM public.practice_sessions
        WHERE student_name     = p_student_name
          AND cleaned_duration > 0
          AND session_start    < p_as_of_date::TIMESTAMPTZ
          AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
        ORDER BY session_start DESC
        LIMIT 30
    )
    SELECT COUNT(*)::INTEGER, AVG(cleaned_duration), STDDEV(cleaned_duration)
    INTO v_count, v_mean, v_std
    FROM recent_valid;

    IF COALESCE(v_count, 0) = 0 THEN RETURN; END IF;

    -- std 保护：< 2 条时保留 NULL；过小时设最小值 1.0
    v_std := CASE
        WHEN v_count < 2               THEN NULL
        WHEN COALESCE(v_std, 0) < 1.0  THEN 1.0
        ELSE v_std
    END;

    -- CV（变异系数）= std / mean
    v_cv := CASE
        WHEN COALESCE(v_mean, 0) > 0 AND v_std IS NOT NULL
            THEN v_std / v_mean
        ELSE 0.5
    END;

    -- ③ 异常率 & 短时率（仅工作日记录）
    SELECT
        AVG(CASE WHEN is_outlier THEN 1.0 ELSE 0.0 END),
        AVG(CASE WHEN cleaned_duration >= 5 AND cleaned_duration < 30 THEN 1.0 ELSE 0.0 END)
    INTO v_outlier_rate, v_short_rate
    FROM (
        SELECT is_outlier, cleaned_duration
        FROM public.practice_sessions
        WHERE student_name  = p_student_name
          AND session_start < p_as_of_date::TIMESTAMPTZ
          AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
        ORDER BY session_start DESC
        LIMIT 30
    ) recent;

    -- ④ 星期分布（仅工作日记录）
    WITH recent_dow AS (
        SELECT EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai')::INTEGER AS dow
        FROM public.practice_sessions
        WHERE student_name     = p_student_name
          AND cleaned_duration > 0
          AND session_start    < p_as_of_date::TIMESTAMPTZ
          AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
        ORDER BY session_start DESC
        LIMIT 30
    )
    SELECT jsonb_object_agg(dow::TEXT, cnt)
    INTO v_weekday_json
    FROM (SELECT dow, COUNT(*) AS cnt FROM recent_dow GROUP BY dow) agg;

    -- ⑤ alpha 计算（FIX-2② CV + FIX-47 分段异常率惩罚）
    v_alpha := 1.0
        - CASE
            WHEN COALESCE(v_mean, 0) > 0 THEN LEAST(0.15, 5.0 / v_mean)
            ELSE 0.15
          END
        - LEAST(0.20, v_cv * 0.15)
        - CASE
            WHEN COALESCE(v_outlier_rate, 0) <= 0.30
                THEN 0.08 * COALESCE(v_outlier_rate, 0)
            ELSE
                0.024 + 0.40 * (COALESCE(v_outlier_rate, 0) - 0.30)
          END
        - 0.05 * COALESCE(v_short_rate, 0);

    -- ⑥ 冷启动混合（群体参照也只用工作日数据）
    IF COALESCE(v_count, 0) < 10 THEN
        SELECT AVG(calc.mean_alpha)
        INTO v_group_alpha
        FROM (
            SELECT student_name, AVG(cleaned_duration) AS mean_dur
            FROM (
                SELECT student_name, cleaned_duration,
                       ROW_NUMBER() OVER (PARTITION BY student_name ORDER BY session_start DESC) AS rn
                FROM public.practice_sessions
                WHERE student_major    = v_student_major
                  AND student_grade    = v_student_grade
                  AND student_name    <> p_student_name
                  AND cleaned_duration > 0
                  AND session_start    < p_as_of_date::TIMESTAMPTZ
                  AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
            ) sub
            WHERE rn <= 30
            GROUP BY student_name
            HAVING COUNT(*) >= 10
        ) grp
        CROSS JOIN LATERAL (
            SELECT
                1.0
                - LEAST(0.15, 5.0 / NULLIF(grp.mean_dur, 0))
                - LEAST(0.20, CASE WHEN NULLIF(grp.mean_dur, 0) IS NOT NULL
                                   THEN (10.0 / grp.mean_dur) * 0.15
                                   ELSE 0.5 * 0.15 END)
                AS mean_alpha
        ) calc;

        IF v_group_alpha IS NULL THEN
            SELECT AVG(calc2.mean_alpha)
            INTO v_group_alpha
            FROM (
                SELECT student_name, AVG(cleaned_duration) AS mean_dur
                FROM (
                    SELECT student_name, cleaned_duration,
                           ROW_NUMBER() OVER (PARTITION BY student_name ORDER BY session_start DESC) AS rn
                    FROM public.practice_sessions
                    WHERE student_major    = v_student_major
                      AND student_name    <> p_student_name
                      AND cleaned_duration > 0
                      AND session_start    < p_as_of_date::TIMESTAMPTZ
                      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6)
                ) sub
                WHERE rn <= 30
                GROUP BY student_name
                HAVING COUNT(*) >= 10
            ) grp
            CROSS JOIN LATERAL (
                SELECT 1.0 - LEAST(0.15, 5.0 / NULLIF(grp.mean_dur, 0)) AS mean_alpha
            ) calc2;
        END IF;

        v_lambda := 1.0 - (COALESCE(v_count, 0)::FLOAT / 10.0);
        v_alpha  := v_lambda * COALESCE(v_group_alpha, 0.82)
                  + (1.0 - v_lambda) * v_alpha;
    END IF;

    v_alpha := GREATEST(0.5, LEAST(1.0, v_alpha));

    v_last_updated := CASE
        WHEN p_as_of_date > CURRENT_DATE THEN NOW()
        ELSE p_as_of_date::TIMESTAMPTZ
    END;

    INSERT INTO public.student_baseline (
        student_name, student_major, student_grade,
        mean_duration, std_duration,
        outlier_rate, short_session_rate,
        alpha, record_count,
        weekday_pattern, is_cold_start, last_updated
    ) VALUES (
        p_student_name, v_student_major, v_student_grade,
        COALESCE(v_mean, 0), v_std,
        COALESCE(v_outlier_rate, 0), COALESCE(v_short_rate, 0),
        v_alpha, COALESCE(v_count, 0),
        COALESCE(v_weekday_json, '{}'::JSONB),
        (COALESCE(v_count, 0) < 10),
        v_last_updated
    )
    ON CONFLICT (student_name) DO UPDATE SET
        student_major      = EXCLUDED.student_major,
        student_grade      = EXCLUDED.student_grade,
        mean_duration      = EXCLUDED.mean_duration,
        std_duration       = EXCLUDED.std_duration,
        outlier_rate       = EXCLUDED.outlier_rate,
        short_session_rate = EXCLUDED.short_session_rate,
        alpha              = EXCLUDED.alpha,
        record_count       = EXCLUDED.record_count,
        weekday_pattern    = EXCLUDED.weekday_pattern,
        is_cold_start      = EXCLUDED.is_cold_start,
        last_updated       = EXCLUDED.last_updated;
END;
$$;
```

### 部署步骤

```sql
-- 1. 部署函数（fix55_baseline_weekday_filter.sql）
-- 2. 重跑 backfill 更新历史 baseline
SELECT public.backfill_score_history();
```

---

## FIX-43：T 维度重构——线性回归改为块对比（2026-03-17）

### 问题描述

FIX-38 后 T 维度仍严重失效：在 184 名活跃学生中，70.1%（129 人）的 T 分值落在 0.50~0.60，其中绝大多数是触发了 `n_points < 3` 默认值 0.5。

**根本原因**：T 使用 `INTERVAL '8 weeks'` 日历窗口内找 3 个活跃周。寒假（约 2 周）+ 开学适应期 = 窗口内有效数据不足，大量学生触发默认值。一学期只有 16 周，直接扩展到 16 周又会让 T 变成"整学期均值"而失去近期趋势意义。

### 修复方案（FIX-43）

**废弃线性回归，改为块对比**：

- 取最近 **4 个活跃工作日周**（20 周上限，跨学期也可）
- **近块**：rn=1,2（最近 2 个活跃周）的均值
- **远块**：rn=3,4（较早 2 个活跃周）的均值
- 对比：近块均值 vs 远块均值，使用与 B 维度相同的 Sigmoid（k=3.0）归一化

```sql
-- FIX-43：T 维度块对比
SELECT
    AVG(CASE WHEN rn <= 2 THEN weekly_mins END),   -- 近块均值
    AVG(CASE WHEN rn  > 2 THEN weekly_mins END),   -- 远块均值
    COUNT(*)
INTO v_recent_avg, v_older_avg, n_t_weeks
FROM (
    SELECT
        SUM(ps.cleaned_duration) AS weekly_mins,
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

-- v_older_avg IS NOT NULL ⟺ n_t_weeks ≥ 3（有近块 + 远块可对比）
IF v_older_avg IS NOT NULL THEN
    t_score := GREATEST(0.0, LEAST(1.0,
        1.0 / (1.0 + EXP(
            -3.0 * (v_recent_avg - v_older_avg)
            / GREATEST(v_effective_mean * 5.0, 150.0)
        ))));
ELSE
    t_score := 0.5;  -- <3 活跃周，无法对比
END IF;
```

### T vs B 维度区别

| | B 维度 | T 维度（FIX-43） |
|---|---|---|
| 比较对象 | 最近1活跃周 vs 前1活跃周 | 近2活跃周均值 vs 前2活跃周均值 |
| 窗口 | 8 周 | 20 周（跨假期） |
| 信号特征 | 短期波动（噪声较高） | 中期方向（均值更稳定） |
| 所需活跃周数 | ≥2 | ≥3 |

### 变量变更（DECLARE 节）

**删除**（线性回归专用）：`slope FLOAT8`、`n_points INTEGER`、`sum_x/y/xy/x2 FLOAT8`、`rec RECORD`

**新增**：`v_recent_avg FLOAT8`、`v_older_avg FLOAT8`、`n_t_weeks INTEGER`

---

*最后更新：2026-03-19（FIX-26 → … → FIX-46 → BUG-01 → BUG-02 → **FIX-50 饭点检测升级："完全跨越"改为"峰值时刻在场"，修复迟到登记/提前离开的漏判盲区，午饭判定改为 session 在 12:10 时刻仍在场（周一至周五），晚饭改为 18:10 时刻（周三不判定）**）*

---

## FIX-44：B/T 维度引入绝对水平分量（2026-03-18）

### 问题

B 和 T 是纯"变化分量"，对长期稳定高练量学生天然不友好：只要本周与上周一样好（即使远超平均），B = 0.5（中性）。同时低基数学生只要"不下滑"就能维持高 B/T。

### 修复方案（FIX-44）

在 B 和 T 中引入绝对水平分量：

```
b_level = sigmoid(-3 × (week1_mins - v_peer_median_weekly) / max(v_peer_median_weekly, 150))
b_score = 0.65 × b_change + 0.35 × b_level

t_level = sigmoid(-3 × (v_recent_avg - v_peer_median_weekly) / max(v_peer_median_weekly, 150))
t_score = 0.65 × t_change + 0.35 × t_level
```

`v_peer_median_weekly = median_mean × 5`（同专业日均中位数 × 5工作日）

**数据验证（146名学生）**：

| 指标 | FIX-43（旧） | FIX-44（新） |
|------|------------|------------|
| p25_b | 0.091 | 0.266 |
| median_b | 0.351 | 0.407 |
| p75_b | 0.538 | 0.536 |
| 受益学生 | — | 71人（49%） |
| 被影响学生 | — | 37人（25%，因高于中位数被适当加分，而非扣分）|

**边界情况处理**：
- 只有近活跃周（无第二周可比较）：b_change = 0.5，b_score = 0.65×0.5 + 0.35×b_level
- 完全无数据：b_score = 0.5

---

## FIX-46：B/T 假期间隔中性化（2026-03-18）

### 问题根因

B 中位数仅 0.351 的主要原因：寒假等长假（如5周）后，学生返校第一周，B 会拿"刚返校第一活跃周"与"5周前最后一个活跃周"对比。此前5周前的活跃周往往是正常满负荷练习周，而刚返校的第一周通常练得较少（适应期），导致 B 被压至 0.002 甚至更低。

### 修复方案（FIX-46）

**B 维度**：
```sql
b_gap_weeks = (v_week1_start - v_week2_start) / 7
-- 若 gap > 3 周，说明中间有假期
b_neutralize = LEAST(0.70, (b_gap_weeks - 3.0) × 0.15)
b_change = b_change × (1 - b_neutralize) + 0.5 × b_neutralize
```

| gap | 中性化程度 | 效果 |
|-----|----------|------|
| 3周（正常） | 0% | 不干预 |
| 4周（短假） | 15% | 轻微向0.5靠拢 |
| 6周（寒假） | 45% | 明显中性化 |
| 8周（暑假） | 60%（上限） | 最大中性化 |

**T 维度**：
```sql
t_gap_weeks = (v_t_recent_start - v_t_older_end) / 7
-- 近块最早周 - 远块最晚周，gap > 4 周触发
t_neutralize = LEAST(0.60, (t_gap_weeks - 4.0) × 0.10)
t_change = t_change × (1 - t_neutralize) + 0.5 × t_neutralize
```

T 的触发门槛略宽（4周），中性化上限略低（60%），因为 T 使用4周跨度数据，本身已更稳定。

### 预期效果

- 寒假5周后返校：B中性化约45%，从0.002 → 约0.28（不再接近0）
- 正常连续练习：gap ≤ 3周，完全不受影响
- 全局 B 中位数进一步从 0.407（FIX-44后）提升

### 受影响函数

`compute_student_score`、`compute_student_score_as_of`（完整函数见 `fix44_46_score_functions.sql`）

### 部署步骤

```sql
-- 步骤1: 执行 fix44_46_score_functions.sql

-- 步骤2: 全量历史重算
SELECT public.backfill_score_history();

-- 步骤3: 重算当前综合分
SELECT public.compute_student_score(student_name)
  FROM public.student_baseline
  WHERE composite_score > 0 OR last_updated IS NOT NULL;

-- 步骤4: 同步当前周 W 分
SELECT public.compute_and_store_w_score(student_name)
  FROM public.student_baseline;
```

---

## BUG-01：`compute_student_score` 列引用歧义修复（2026-03-18）

**报错**：`ERROR: 42702: column reference "composite_score" is ambiguous`

**根本原因**：函数声明 `RETURNS TABLE(composite_score INT, raw_score FLOAT8)` 后，`composite_score` 同时作为 PL/pgSQL 输出变量和 `student_score_history` 表的列名存在于作用域内，PostgreSQL 无法区分。

**受影响查询（2处 hist_count + 1处 velocity 循环）**：
```sql
-- 修复前（歧义）
FROM public.student_score_history
WHERE composite_score > 0

-- 修复后（加表别名 sh 明确指向表列）
FROM public.student_score_history sh
WHERE sh.composite_score > 0
```

**`compute_student_score` 修复点**：
- 历史深度查询（hist_count）：`FROM ... sh WHERE sh.composite_score > 0 AND sh.snapshot_date < v_week_monday`
- 成长加速度循环：`SELECT sh.composite_score::FLOAT8 FROM ... sh WHERE sh.composite_score > 0`

**`compute_student_score_as_of` 修复点**：
- 历史深度查询（hist_count）：同上加 `sh.` 前缀

---

## BUG-02：B 维度外层 SELECT 跨子查询引用 `ps` 别名修复（2026-03-18）

**报错**：`ERROR: 42P01: missing FROM-clause entry for table "ps"`

**根本原因**：B 维度查询的外层 SELECT 使用了 `ps.cleaned_duration`，但 `ps` 别名只在内层子查询中有效，外层只能使用子查询暴露的列名。

```sql
-- 修复前（错误：ps 别名超出作用域）
SELECT
  SUM(CASE WHEN rn = 1 THEN ps.cleaned_duration ELSE 0 END),
  SUM(CASE WHEN rn = 2 THEN ps.cleaned_duration ELSE 0 END),
  ...
FROM (
  SELECT ps.cleaned_duration, ... FROM public.practice_sessions ps WHERE ...
) sub

-- 修复后（正确：外层直接引用子查询列名）
SELECT
  SUM(CASE WHEN rn = 1 THEN cleaned_duration ELSE 0 END),
  SUM(CASE WHEN rn = 2 THEN cleaned_duration ELSE 0 END),
  ...
FROM (
  SELECT ps.cleaned_duration, ... FROM public.practice_sessions ps WHERE ...
) sub
```

**受影响函数**：`compute_student_score`（第265-266行）、`compute_student_score_as_of`（第832-833行）

**完整修复文件**：`fix44_46_score_functions.sql`（已同步更新）

---

## FIX-47：compute_baseline_as_of alpha 异常率惩罚加速（2026-03-13）

### 问题根因

旧公式第 ⑤ 步 alpha 计算中，异常率惩罚为：

```sql
- 0.02 * COALESCE(v_outlier_rate, 0)
```

对于异常率 73.3% 的学生，实际仅扣减 **0.0147（约 1.5%）**，几乎无效。

加之该学生 `too_long` 占比极高，所有超时记录的 `cleaned_duration` 都被截断至 120 分钟，
其余正常练习也约为 120 分钟，导致 `STDDEV(cleaned_duration) ≈ 0`，CV ≈ 0，波动惩罚趋近于零。
两种效应叠加，造成 α = 0.9424 这一虚高值（表现为"稳定性极佳"，实际恰好相反）。

### 修复方案（分段加速惩罚）

| 异常率区间 | 公式 | 典型扣减 |
|:---:|:---|:---:|
| 0 ~ 30% | `0.08 × rate` | 最多 -0.024 |
| > 30% | `0.024 + 0.40 × (rate - 0.30)` | 50% → -0.10，73% → -0.20，100% → -0.30 |

```sql
-- [FIX-47] 异常率惩罚（分段加速）
- CASE
    WHEN COALESCE(v_outlier_rate, 0) <= 0.30
        THEN 0.08 * COALESCE(v_outlier_rate, 0)
    ELSE
        0.024 + 0.40 * (COALESCE(v_outlier_rate, 0) - 0.30)
  END
```

**修复效果对比（马逸诚，mean=120，CV≈0，outlier_rate=73.3%）**：

| 版本 | alpha |
|:---:|:---:|
| 旧版 | 0.9424 |
| FIX-47 | 约 0.761 |

### 配套前端补丁（dashboard.html 稳定榜）

稳定榜已额外加入过滤条件 `(s.outlier_rate ?? 1) <= 0.35`，
作为 SQL 修复未部署前的即时防护，避免高异常率学生通过虚高 α 进入稳定榜。

### 受影响函数

- `public.compute_baseline_as_of`：⑤ alpha 计算替换
- `public.compute_baseline`：无逻辑变更（薄封装，随实现函数一起部署）

**完整修复文件**：`fix47_alpha_outlier_penalty.sql`

### 部署步骤

```sql
-- 1. 粘贴 fix47_alpha_outlier_penalty.sql 中两个 CREATE OR REPLACE FUNCTION
-- 2. 全量重算基线
SELECT public.recompute_all_baselines();
```

---

## FIX-48：get_weekly_leaderboards() RPC 函数 — 排行榜后端化（2026-03-18）

### 背景
原排行榜逻辑（综合榜/进步榜/稳定榜/守则榜）全部在前端 dashboard.html 中通过多次 REST 查询计算：
- `fetchRecentSessions()`：拉取12周内所有 session（limit 5000）
- `fetchCurrentWeekScores()`：拉取本周快照
- JS 侧按学生分桶、聚合、过滤、排序

**存在的问题**：
1. 前端需要下载大量原始数据再计算，慢且浪费流量
2. 简化版前端（练琴跟踪优化简化版本.html）无法展示分类排行榜
3. 规则变动需要同时修改多个前端文件

### 修改内容

**新增函数**：`public.get_weekly_leaderboards()`

| 参数 | 无 |
|------|---|
| 返回 | TABLE：board / rank_no / student_name / student_major / student_grade / display_score / alpha / trend_score / mean_duration / record_count / recent10_outlier_rate / recent10_mean_dur / recent10_count |

一次调用返回全部四个榜数据（约 34 行），前端按 `board` 字段分组渲染。

**计算口径（与原前端一致）**：
- `recent10`：近12周内每个学生最多10条有效 session，不过滤工作日
- `week_cnt`：本周 session 数（不过滤工作日）
- `week_scores`：`student_score_history WHERE snapshot_date = 本周一`
- `ranked_pool`：本周有 session + composite_score > 0
- 四榜过滤/排序规则与 dashboard.html 原 JS 完全一致

**部署文件**：`leaderboard_rpc.sql`

**前端变动**：
- `dashboard.html`：新增 `rpc()` 辅助函数；`fetchRecentSessions()` 替换为 `fetchLeaderboards()`；`renderCatBoards()` 改为接收后端数据；新增 60s 轮询 `startLbPolling()`
- `练琴跟踪优化简化版本.html`：新增周榜区域（CSS+HTML+JS）；四榜 Tab 切换；`supabaseClient.rpc()` 调用；practice_logs clear 事件触发 5s 延迟刷新；60s 定时轮询

### 部署步骤

```sql
-- 1. 在 Supabase SQL Editor 中粘贴并执行 leaderboard_rpc.sql 全文
-- 2. 验证：
SELECT board, count(*) FROM public.get_weekly_leaderboards() GROUP BY board ORDER BY board;
-- 预期：综合榜(≤10行) 进步榜(≤6行) 守则榜(≤6行) 稳定榜(≤6行)
```

---

## FIX-50：饭点检测升级——"完全跨越"改为"峰值时刻在场"（2026-03-19）

### 问题描述

FIX-39 将 `meal_break` 判定条件由"相交"收紧为"完全跨越"（session_start < 11:50 AND session_end > 12:30），虽然解决了 FIX-30 的大量误标，但引入了两个新的漏判盲区：

**盲区 A：提前离开型**
```
session:  [11:40 ─────────── 12:25]
饭点窗口:       [11:50 ─── 12:30]
end=12:25 < 12:30 → 不满足"完全跨越" → 漏判 ❌
```

**盲区 B：迟到登记型**（用户反馈的主要场景）
```
session:        [12:05 ─────────── 14:00]
饭点窗口: [11:50 ─── 12:30]
start=12:05 > 11:50 → 不满足"完全跨越" → 漏判 ❌
```
学生 11:40 进食堂，12:00 返回后才刷卡登记，有效规避了旧逻辑。晚饭同理（17:45 去吃饭，18:00-18:30 刷卡）。

### 修复方案

**核心思路**：将"是否跨越整个窗口"改为"是否在最核心吃饭时刻仍在占用琴房"。

```
午饭峰值时刻：12:10（周一至周五，DOW 1-5）
晚饭峰值时刻：18:10（周一/二/四/五，周三不判定，DOW IN (1,2,4,5)）

判定条件：
  午饭：session_start < 12:10 AND session_end > 12:10
  晚饭：session_start < 18:10 AND session_end > 18:10
```

各场景覆盖情况：

| 场景 | start | end | 是否判异常 | 准确性 |
|---|---|---|---|---|
| 完全跨越（FIX-39 已判）| 11:00 | 14:00 | ✅ | ✅ |
| 提前离开（盲区 A）| 11:40 | 12:25 | ✅ | ✅ |
| 迟到登记（盲区 B）| 12:05 | 13:30 | ✅ | ✅ |
| 合法早午练（11点出）| 10:00 | 12:05 | ❌ | ✅ |
| 合法午后练 | 12:20 | 14:00 | ❌ | ✅ |
| 误差边缘 | 12:15 | 14:00 | ❌ | ⚠️ 极少数漏判 |

### 优先级规则（不变）

| 原 outlier_reason | spans_meal_break | 结果 |
|---|---|---|
| `too_long`（>180 分钟） | 任意 | 保持 `too_long`，不降级 |
| `capped_120`（120~180 分钟） | TRUE | 升级为 `meal_break`，is_outlier=TRUE |
| NULL（正常时长） | TRUE | 标记 `meal_break`，cleaned_duration 不变 |

### 受影响函数

**`trigger_insert_session`**：修改 `v_spans_meal_break` 赋值逻辑。

**旧逻辑（FIX-39）**：
```sql
v_spans_meal_break := v_dow BETWEEN 1 AND 5 AND (
    (v_start_time < '11:50:00'::TIME AND v_end_time > '12:30:00'::TIME)
    OR
    (v_start_time < '17:50:00'::TIME AND v_end_time > '18:30:00'::TIME)
);
```

**新逻辑（FIX-50）**：
```sql
v_spans_meal_break := (
    -- 午饭峰值时刻 12:10：周一至周五（DOW 1-5）
    (v_dow BETWEEN 1 AND 5
        AND v_start_time < '12:10:00'::TIME
        AND v_end_time   > '12:10:00'::TIME)
    OR
    -- 晚饭峰值时刻 18:10：周一/二/四/五（DOW 1,2,4,5；周三不判定）
    (v_dow IN (1, 2, 4, 5)
        AND v_start_time < '18:10:00'::TIME
        AND v_end_time   > '18:10:00'::TIME)
);
```

### 历史数据修正 SQL

```sql
-- 步骤 1：预览新增漏判记录数
SELECT COUNT(*) AS new_lunch_violations
FROM public.practice_sessions
WHERE is_outlier = FALSE
  AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') BETWEEN 1 AND 5
  AND (session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '12:10:00'
  AND (session_end   AT TIME ZONE 'Asia/Shanghai')::TIME > '12:10:00';

SELECT COUNT(*) AS new_dinner_violations
FROM public.practice_sessions
WHERE is_outlier = FALSE
  AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') IN (1, 2, 4, 5)
  AND (session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '18:10:00'
  AND (session_end   AT TIME ZONE 'Asia/Shanghai')::TIME > '18:10:00';

-- 步骤 2：标记漏判的正常时长记录
UPDATE public.practice_sessions
SET is_outlier     = TRUE,
    outlier_reason = 'meal_break'
WHERE is_outlier = FALSE
  AND (
      (EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') BETWEEN 1 AND 5
        AND (session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '12:10:00'
        AND (session_end   AT TIME ZONE 'Asia/Shanghai')::TIME > '12:10:00')
      OR
      (EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') IN (1, 2, 4, 5)
        AND (session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '18:10:00'
        AND (session_end   AT TIME ZONE 'Asia/Shanghai')::TIME > '18:10:00')
  );

-- 步骤 3：capped_120（120~180 分钟）升级为 meal_break
UPDATE public.practice_sessions
SET is_outlier     = TRUE,
    outlier_reason = 'meal_break'
WHERE outlier_reason = 'capped_120'
  AND (
      (EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') BETWEEN 1 AND 5
        AND (session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '12:10:00'
        AND (session_end   AT TIME ZONE 'Asia/Shanghai')::TIME > '12:10:00')
      OR
      (EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') IN (1, 2, 4, 5)
        AND (session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '18:10:00'
        AND (session_end   AT TIME ZONE 'Asia/Shanghai')::TIME > '18:10:00')
  );

-- 步骤 4：将 FIX-39 标记但 FIX-50 不认为异常的 meal_break 记录恢复正常
--（即：只跨越了旧窗口边缘，但在峰值时刻 12:10/18:10 未在场）
UPDATE public.practice_sessions
SET is_outlier     = FALSE,
    outlier_reason = NULL
WHERE outlier_reason = 'meal_break'
  AND raw_duration <= 120
  AND NOT (
      (EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') BETWEEN 1 AND 5
        AND (session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '12:10:00'
        AND (session_end   AT TIME ZONE 'Asia/Shanghai')::TIME > '12:10:00')
      OR
      (EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') IN (1, 2, 4, 5)
        AND (session_start AT TIME ZONE 'Asia/Shanghai')::TIME < '18:10:00'
        AND (session_end   AT TIME ZONE 'Asia/Shanghai')::TIME > '18:10:00')
  );

-- 步骤 5：重算所有学生基线和综合分
SELECT public.recompute_all_baselines();
SELECT public.backfill_score_history();
SELECT public.compute_student_score(student_name)
FROM public.student_baseline;
```

---

## FIX-51：修复 FIX-41 遗留的 cleaned_duration 污染记录（2026-03-19）

### 问题现象

部分学生在 `practiceanalyse.html` 的练琴记录中出现"2分钟却截断至45分钟"的矛盾显示：
- `raw_duration = 2`（正确，由 FIX-41 从时间戳重算）
- `cleaned_duration = 45`（污染值，来自旧版触发器中的 `practice_duration` 字段）
- `is_outlier = FALSE`（不是异常，正常显示 "↩ 截断至45min"）
- 这些记录被 `compute_baseline_as_of` 当成 45 分钟有效练琴计入均值！

### 根本原因

**三段故障链：**

1. **旧触发器（FIX-41 之前）**：使用前端传入的 `practice_duration` 字段作为时长，该字段存在严重 bug，部分记录被设为 8399 分钟。对于时间戳只有 2 分钟的会话，`practice_duration` 却是 2700 秒（45 分钟），导致：
   - `raw_duration = 45`，`cleaned_duration = 45`，`session_start/end = 12:59-13:01`（真实只有2分钟）

2. **FIX-41 历史修正 SQL**：针对 1285 条"偏差巨大"的记录用时间戳重算了 `raw_duration`（→ 2 分钟）和重判了 `is_outlier`。**但 `cleaned_duration` 未同步更新**，仍留在 45 分钟。

3. **触发器早退逻辑的盲区**：新触发器在 `< 300 秒` 时 `RETURN NEW`（不写入），但**不清理已有的脏记录**，导致这批记录永远无法被自动修复。

### 影响范围

- 所有 `raw_duration < 5` 的 practice_sessions 记录（应不存在）
- 所有 `cleaned_duration > raw_duration` 的 practice_sessions 记录（逻辑矛盾）
- 这些记录被计入学生基线均值，人为拉高了 `mean_duration` 和评分

### 修复内容

**数据修复 SQL（`fix_stale_cleaned_duration.sql`）**：
1. 删除 `raw_duration < 5` 的僵尸记录
2. 将 `cleaned_duration > raw_duration` 的记录按当前触发器规则重新计算 `cleaned_duration`
3. 重算受影响学生的基线

**触发器加固（FIX-51B）**：
- 旧行为：`v_duration_seconds < 300` 时 `RETURN NEW`（静默丢弃，不清理已有脏数据）
- 新行为：先 `DELETE FROM practice_sessions WHERE student_name=... AND session_start=v_assign_time`，再 `RETURN NEW`
- 效果：未来无论何时同一 (student, session_start) 产生 < 5 分钟的会话，历史脏记录都会被主动清除

**前端显示修复（`practiceanalyse.html`）**：
- 旧行为：`cleanMin > rawMin` 时显示"↩ 截断至Xmin"（误导用户以为是正常截断）
- 新行为：`cleanMin > rawMin` 时显示"⚠ 数据异常"（红色警示，鼠标悬停提示根本原因）

### 数据修复 SQL（完整版）

```sql
-- ── 步骤 0：预览受影响记录 ──────────────────────────────────────────────
-- 情况A：raw_duration < 5（不应存在于 practice_sessions）
SELECT COUNT(*) AS too_short_records,
       COUNT(DISTINCT student_name) AS affected_students,
       AVG(cleaned_duration)::NUMERIC(6,1) AS avg_stale_cleaned
FROM public.practice_sessions WHERE raw_duration < 5;

-- 情况B：cleaned_duration > raw_duration（逻辑矛盾）
SELECT COUNT(*) AS inverted_records,
       COUNT(DISTINCT student_name) AS affected_students,
       SUM(cleaned_duration - raw_duration)::INTEGER AS total_inflated_minutes
FROM public.practice_sessions WHERE cleaned_duration > raw_duration;

-- ── 步骤 1：删除 raw_duration < 5 的僵尸记录 ────────────────────────────
DELETE FROM public.practice_sessions WHERE raw_duration < 5;

-- ── 步骤 2：修复 cleaned_duration > raw_duration 的矛盾记录 ─────────────
UPDATE public.practice_sessions
SET
    cleaned_duration = CASE
        WHEN raw_duration > 180 THEN 120
        WHEN raw_duration > 120 THEN 120
        ELSE raw_duration
    END,
    is_outlier = CASE
        WHEN raw_duration > 180 THEN TRUE
        ELSE is_outlier
    END,
    outlier_reason = CASE
        WHEN raw_duration > 180 THEN 'too_long'
        WHEN raw_duration > 120 THEN 'capped_120'
        ELSE outlier_reason
    END
WHERE cleaned_duration > raw_duration;

-- ── 步骤 3：重算受影响学生基线 ──────────────────────────────────────────
-- 找出受影响学生（在步骤1/2执行前先运行）
SELECT DISTINCT student_name
FROM public.practice_sessions
WHERE raw_duration < 5 OR cleaned_duration > raw_duration
ORDER BY student_name;

-- 全量重建（受影响学生较多时使用）
-- SELECT public.backfill_score_history();
```

### 操作步骤

1. 在 Supabase Dashboard > SQL Editor 中执行上方 SQL（步骤 0→1→2）
2. 执行步骤 3（重算基线）或 `SELECT public.backfill_score_history()` 全量重建
3. 在 Supabase Dashboard > Database > Functions 中确认 `trigger_insert_session` 已更新（含 FIX-51B）
4. 完成后在 `practiceanalyse.html` 验证不再出现"数据异常"红色标记

---

## FIX-67：admin_coins.html 音符币后台 406 错误修复

**日期**：2026-03-20
**文件**：`admin_coins.html`

### 问题

`admin_coins.html` 在加载"自动结算开关"时报错：
```
Failed to load resource: 406 (Cannot coerce the result to a single JSON object)
```

### 根本原因

前端使用了 Supabase 的 `.single()` 方法查询 `system_settings` 表的 `auto_coin_reward_enabled` 键。`.single()` 要求查询**恰好返回 1 行**，当该键尚未写入数据库时返回 0 行，PostgREST 报 406。

### 修复内容

`admin_coins.html` 中 `loadAutoRewardSetting` 函数改为：
- `.single()` → `.maybeSingle()`（允许 0 或 1 行）
- 添加 `data` 为 `null` 时的兜底逻辑（默认为 `false`/关闭）

```javascript
const { data, error } = await supabaseClient
  .from('system_settings')
  .select('value, updated_at')
  .eq('key', 'auto_coin_reward_enabled')
  .maybeSingle(); // 改为 maybeSingle，允许记录不存在

if (error) throw error;
const enabled = data ? (data.value === 'true') : false;
```

---

## FIX-68：自动结算开关 RLS 拦截——刷新后状态丢失

**日期**：2026-03-20
**文件**：`admin_coins.html`、`fix_auto_reward_rls.sql`（新增）

### 问题

管理员在 `admin_coins.html` 开启"自动结算"开关后，刷新页面开关恢复关闭，无法持久化。

### 根本原因

`system_settings` 表启用了 Row Level Security（RLS），且没有配置读取策略。虽然设置了 `GRANT SELECT`，但 RLS 默认屏蔽所有行，导致前端直接 SELECT 时返回 0 行 → `maybeSingle()` 返回 `null` → 界面显示关闭。

写入（`set_auto_reward_enabled` RPC）因为是 `SECURITY DEFINER` 可以绕过 RLS 正常写入，所以数据其实保存成功了，只是读不回来。

### 修复内容

**新增 `fix_auto_reward_rls.sql`**：

```sql
-- 1. 确保初始记录存在（默认开启）
INSERT INTO public.system_settings (key, value, updated_at)
VALUES ('auto_coin_reward_enabled', 'true', NOW())
ON CONFLICT (key) DO NOTHING;

-- 2. 新增 SECURITY DEFINER 读取函数（绕过 RLS）
CREATE OR REPLACE FUNCTION public.get_auto_reward_setting()
RETURNS TABLE(enabled BOOLEAN, updated_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT (value = 'true') AS enabled, s.updated_at
    FROM public.system_settings s
    WHERE s.key = 'auto_coin_reward_enabled'
    LIMIT 1;
    IF NOT FOUND THEN
        RETURN QUERY SELECT TRUE, NOW();
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_auto_reward_setting() TO anon, authenticated;
```

**`admin_coins.html` `loadAutoRewardSetting` 改为调用 RPC**：

```javascript
// 使用 SECURITY DEFINER RPC 读取，绕过 RLS 策略
const { data, error } = await supabaseClient.rpc('get_auto_reward_setting');
if (error) throw error;
const row = data && data.length > 0 ? data[0] : null;
const enabled = row ? row.enabled : true;  // 默认开启
```

### 部署步骤

在 Supabase SQL Editor 运行 `fix_auto_reward_rls.sql` 即可。

---

## FIX-69：进步榜右侧由百分比涨幅改为绝对涨分显示

**日期**：2026-03-20
**文件**：`leaderboard_rpc.sql`、`practiceanalyse.html`、`menuhin-school-system/index.html`

### 问题

进步榜右侧显示的百分比涨幅（`+X.X%`）大多数时候为 `+0.0%`，毫无区分度。

### 根本原因

综合分（`composite_score`）是整数（0-100），学生单周实际涨幅通常为 0.1~3 分。换算成百分比（如 0.5/60 × 100 = 0.8%），经 `ROUND(..., 1)` 后极易变成 `0.0%`。

### 修复内容

**`leaderboard_rpc.sql` — `prog` CTE 的 `trend_score` 改为绝对涨分**：

```sql
-- 旧（百分比，几乎全为 0.0%）
ROUND((rp.display_score - lws.lw_composite)
      / NULLIF(lws.lw_composite, 0) * 100, 1) AS trend_score

-- 新（绝对涨分，单位：分）
ROUND((rp.display_score - lws.lw_composite)::NUMERIC, 1) AS trend_score
```

**前端 `valFns['进步榜']` 颜色/标签阈值同步调整**：

| 档位 | 旧（百分比） | 新（绝对分） |
|---|---|---|
| 高档（绿） | ≥30% | ≥8 分 |
| 中档（浅绿）| ≥15% | ≥3 分 |
| 低档（蓝） | <15% | <3 分 |

显示由 `+3.0%` 变为 `+3.0 分`（两个前端同步修改）。

同步更新副标题：
- 进步榜：`"本周综合分相对涨幅最大 · α ≥0.50"` → `"本周综合分绝对涨分最大 · 本周 ≥2 次 · 异常率 ≤50%"`
- 稳定榜：α 阈值 0.65→0.55，近10条 ≥10→≥8，异常率 ≤35%→≤40%
- 守则榜：α 阈值 0.60→0.55，均时 >30→>25min，补充"近10条 ≥4条"

---

## FIX-70：composite_score 改为 NUMERIC(6,1) 保留小数点后一位

**日期**：2026-03-20
**文件**：`fix44_46_score_functions.sql`、`fix53_backfill_update.sql`、`migrate_composite_score_numeric.sql`（新增）、`practiceanalyse.html`、`menuhin-school-system/index.html`

### 问题

综合分（`composite_score`）以往存储为 `INT`（整数），前端显示 `toFixed(1)` 时全部为 `XX.0`，无法区分相近分数的学生。

### 修复内容

**数据库表迁移（`migrate_composite_score_numeric.sql`）**：

```sql
ALTER TABLE public.student_score_history
    ALTER COLUMN composite_score TYPE NUMERIC(6,1)
    USING ROUND(composite_score::NUMERIC, 1);

ALTER TABLE public.student_baseline
    ALTER COLUMN composite_score TYPE NUMERIC(6,1)
    USING ROUND(composite_score::NUMERIC, 1);
```

**`fix44_46_score_functions.sql` — 共 4 处修改**：

```sql
-- 返回类型
RETURNS TABLE(composite_score NUMERIC, raw_score FLOAT8)  -- INT → NUMERIC

-- 变量声明（2个函数各1处）
v_composite_score  NUMERIC;  -- INT → NUMERIC

-- 赋值计算（2个函数各1处）
v_composite_score := ROUND((composite_raw * 100)::NUMERIC, 1);
-- 旧: ROUND(composite_raw * 100)::INT

-- 早退分支返回值（修复类型匹配错误）
RETURN QUERY SELECT COALESCE(r.composite_score, 0::NUMERIC), ...;
RETURN QUERY SELECT 0::NUMERIC, 0.0::FLOAT8;
```

**关键细节**：PostgreSQL 的 `ROUND(x, n)` 两参数版本**只接受 `NUMERIC`**，`FLOAT8` 不支持，必须显式转型：
```sql
ROUND((composite_raw * 100)::NUMERIC, 1)  -- ✅ 正确
ROUND(composite_raw * 100, 1)             -- ❌ ERROR: function round(double precision, integer) does not exist
```

**`fix53_backfill_update.sql`**：
```sql
SET composite_score = ROUND((raw_score * 100)::NUMERIC, 1)
-- 旧: ROUND(raw_score * 100)::INT
```

**前端**：两个前端均恢复 `toFixed(1)` 显示（等数据库迁移完成后自动显示真实小数）。

### 部署顺序（严格按序）

1. **运行 `migrate_composite_score_numeric.sql`** — 修改两张表列类型
2. **DROP 旧函数**（返回类型变了，必须先删）：
   ```sql
   DROP FUNCTION IF EXISTS public.compute_student_score(TEXT);
   DROP FUNCTION IF EXISTS public.compute_student_score_as_of(TEXT, DATE);
   ```
3. **重新部署 `fix44_46_score_functions.sql`**
4. **历史重算**：`SELECT public.backfill_score_history();`

---

## FIX-71：trigger_update_student_baseline 改为每次练琴都立即触发

**日期**：2026-03-20
**文件**：`fix60_weekly_update_and_baseline_trigger.sql`

### 问题

原触发函数 `trigger_update_student_baseline` 使用动态间隔（新生每次、成熟老生最多每 10 次）才调用 `update_student_baseline()`，导致排行榜分数不够实时——老生练琴后可能要等多次才更新一次排名。

### 修复内容

将 `trigger_update_student_baseline()` 精简为**每次都立即触发**，删除全部动态间隔逻辑：

```sql
-- 旧版（约 60 行，含动态间隔计算）
CREATE OR REPLACE FUNCTION public.trigger_update_student_baseline()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_record_count  INTEGER;
    v_interval      INTEGER;
    -- ... 大量变量声明 ...
BEGIN
    -- ... 复杂的间隔判断逻辑 ...
    IF v_force_update OR (v_live_count % v_interval = 0) THEN
        PERFORM public.update_student_baseline(NEW.student_name);
    END IF;
    RETURN NEW;
END;
$$;

-- 新版（FIX-71）
CREATE OR REPLACE FUNCTION public.trigger_update_student_baseline()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM public.update_student_baseline(NEW.student_name);
    RETURN NEW;
END;
$$;
```

### 触发链路（更新后）

```
学生还卡 → practice_sessions INSERT
  → trigger_update_student_baseline()  ← 每次必触发
      → update_student_baseline()
  → trg_fn_compute_score_on_baseline_update
      → compute_student_score()        ← 重算5维分数
  → 前端60秒轮询 → 排行榜更新
```

### 部署

在 Supabase SQL Editor 运行 `fix60_weekly_update_and_baseline_trigger.sql` 后半段的 `trigger_update_student_baseline` 函数即可，无需 DROP。

---

## FIX-72：饭点检测时区 Bug 导致 meal_break 误判

**日期**：2026-03-20
**文件**：`fix_stale_cleaned_duration.sql`（修复触发器）、`fix72_meal_break_timezone.sql`（新增，历史数据修复）

### 问题

部分学生练琴记录被错误标记为 `meal_break`（跨饭点未还卡），但实际上根本没有跨过午/晚饭峰值时刻。例如：

- 王申崚 BJT 08:05→10:11，远在 12:10 午饭峰值之前结束，却被标为 meal_break

### 两类误判来源

**① 时区 Bug（直接原因）**：`trigger_insert_session` 函数计算北京时间时使用了错误的双重转换：

```sql
-- 旧（错误）：对 TIMESTAMPTZ 输入产生双重偏移
v_start_bjt  := v_assign_time AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Shanghai';
v_start_time := v_start_bjt::TIME;  -- UTC 服务器上 ::TIME 取的是 UTC 小时，非北京时间
v_dow        := EXTRACT(DOW FROM v_start_bjt)::INTEGER;
```

推导（以 BJT 08:05 = UTC 00:05 为例）：
```
TIMESTAMPTZ(00:05 UTC)
  → AT TIME ZONE 'UTC' → TIMESTAMP(00:05)（丢失 tz 信息）
  → AT TIME ZONE 'Asia/Shanghai' → 把 00:05 当上海时间解释 → TIMESTAMPTZ(前一天 16:05 UTC)
  → ::TIME（UTC 服务器）→ 16:05
end 同理：02:11 UTC → 18:11
→ 检测：16:05 < 18:10 ✓ AND 18:11 > 18:10 ✓ → 误判 meal_break ❌
```

**影响范围**：BJT 开始时间 < 10:10、结束时间在 10:11~15:59 之间的 session 均被误判为 dinner meal_break。

**② 旧触发器未部署 FIX-50 的周三排除**：历史上所有周三（DOW=3）下午练琴跨过 18:10 的 session，因数据库中运行的是未含 Wednesday 排除的旧版触发器，被错误标记为 meal_break（按现行规则周三晚饭不判定）。

### 修复内容

**`fix_stale_cleaned_duration.sql` — `trigger_insert_session` 时区计算修正**：

```sql
-- 新（正确）：TIMESTAMPTZ AT TIME ZONE 直接给出北京时间 TIMESTAMP，::TIME 取北京时钟
v_start_time := (v_assign_time AT TIME ZONE 'Asia/Shanghai')::TIME;
v_end_time   := (v_clear_time  AT TIME ZONE 'Asia/Shanghai')::TIME;
v_dow        := EXTRACT(DOW FROM (v_assign_time AT TIME ZONE 'Asia/Shanghai'))::INTEGER;
```

同时删除不再需要的 `v_start_bjt`、`v_end_bjt` 中间变量声明。

**新增 `fix72_meal_break_timezone.sql` — 历史误判数据修复**：

```sql
-- 查找误判：outlier_reason='meal_break' 但北京时间实际未跨峰值
SELECT student_name, ... FROM public.practice_sessions
WHERE outlier_reason = 'meal_break'
  AND NOT (
    (DOW 1-5 AND bjt_start < 12:10 AND bjt_end > 12:10)  -- 真正跨午饭
    OR
    (DOW IN (1,2,4,5) AND bjt_start < 18:10 AND bjt_end > 18:10)  -- 真正跨晚饭
  );

-- 修正：改回 capped_120（>120min）或 NULL（正常）
UPDATE public.practice_sessions
SET is_outlier = FALSE,
    outlier_reason = CASE WHEN raw_duration > 120 THEN 'capped_120' ELSE NULL END
WHERE outlier_reason = 'meal_break' AND NOT (...);
```

### 实际影响

运行预览查询，发现 38 条历史误判记录，分为两类：

| 类型 | 条数 | 特征 |
|---|---|---|
| 时区 Bug | 1（王申崚） | 周五 BJT 08:05-10:11，完全不跨峰值 |
| 周三晚饭旧触发器 | 37 | 全部为周三 BJT 16:xx-19:xx，真实跨 18:10 但周三排除 |

### 部署步骤

1. 在 Supabase SQL Editor 运行 `fix72_meal_break_timezone.sql`：
   - 步骤①：预览误判记录
   - 步骤②：批量修正历史数据（UPDATE）
   - 步骤④：`SELECT public.backfill_score_history()` 重算受影响学生分数
2. 重新部署 `fix_stale_cleaned_duration.sql`（修复触发器，防止新记录继续误判）

---

# ══════════════════════════════════════════════════════════════════
# 最新部署版本 — 完整函数代码备份
# 备份日期：2026-03-20
# 说明：此区块包含数据库中所有核心函数/触发器函数的**本地最新版本**完整代码，
#       方便在数据库迁移、意外覆盖或重建时快速恢复，无需重新翻阅分散的 .sql 文件。
# ══════════════════════════════════════════════════════════════════

## 函数清单（10个）

| # | 函数名 | 最新文件 | 最新 Fix | 关键特征 |
|---|--------|---------|---------|---------|
| 1 | `trigger_insert_session` | `fix_stale_cleaned_duration.sql` | FIX-72 | 时区修正：`AT TIME ZONE 'Asia/Shanghai')::TIME` |
| 2 | `trigger_update_student_baseline` | `fix60_weekly_update_and_baseline_trigger.sql` | FIX-71 | 每次必触发，无 v_live_count |
| 3 | `run_weekly_score_update` | `fix60_weekly_update_and_baseline_trigger.sql` | FIX-8/60 | `raw_score IS NOT NULL` 保护 |
| 4 | `backfill_score_history` | `fix53_backfill_update.sql` | FIX-62/53F | backfill 后重刷基线+W分 |
| 5 | `get_weekly_leaderboards` | `leaderboard_rpc.sql` | FIX-65/69 | comp_top10 + 绝对涨分 |
| 6 | `get_auto_reward_setting` | `fix_auto_reward_rls.sql` | FIX-68 | SECURITY DEFINER 绕过 RLS |
| 7 | `compute_student_score` | `fix44_46_score_functions.sql` | FIX-70/57 | 返回 NUMERIC，新生 w_week=0.70 |
| 8 | `compute_student_score_as_of` | `fix44_46_score_functions.sql` | FIX-70/57 | 同上，历史回填版 |
| 9 | `compute_baseline_as_of` | `fix55_baseline_weekday_filter.sql` | FIX-55 | NOT IN (0,6) ≥6 处 |
| 10 | `compute_and_store_w_score` | `fix54_w_score_sunday.sql` | FIX-54 | WHEN 0 THEN 5（周日DOW修复）|

> **注**：`compute_student_score` / `compute_student_score_as_of` / `compute_baseline_as_of` 函数体超过 600 行，
> 完整代码以对应 .sql 文件为准，此处不重复抄录，只记录版本特征以供核查。

---

## 1. trigger_insert_session（FIX-72 最新版）

> 文件：`fix_stale_cleaned_duration.sql`  最后修改：FIX-72（2026-03-20）

```sql
CREATE OR REPLACE FUNCTION public.trigger_insert_session()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_assign           RECORD;
    v_duration_seconds INTEGER;
    v_assign_time      TIMESTAMPTZ;
    v_clear_time       TIMESTAMPTZ;
    v_cleaned_duration INTEGER;
    v_is_outlier       BOOLEAN;
    v_outlier_reason   TEXT;
    v_start_time       TIME;
    v_end_time         TIME;
    v_dow              INTEGER;
    v_spans_meal_break BOOLEAN;
BEGIN
    IF NEW.action != 'clear' THEN
        RETURN NEW;
    END IF;

    v_clear_time := NEW.created_at;

    -- 第一步：找最近的 assign（16小时内，同学生+同琴房）
    SELECT pl.*
    INTO v_assign
    FROM public.practice_logs pl
    WHERE pl.student_name = NEW.student_name
      AND pl.room_name    = NEW.room_name
      AND pl.action       = 'assign'
      AND pl.created_at   < v_clear_time
      AND pl.created_at   > v_clear_time - INTERVAL '16 hours'
    ORDER BY pl.created_at DESC
    LIMIT 1;

    IF v_assign IS NULL THEN
        RETURN NEW;
    END IF;

    v_assign_time := v_assign.created_at;

    -- 第二步：检查中间断点（防止重复消费同一个 assign）
    IF EXISTS (
        SELECT 1
        FROM public.practice_logs mid
        WHERE mid.student_name = NEW.student_name
          AND mid.room_name    = NEW.room_name
          AND mid.action       = 'clear'
          AND mid.created_at   > v_assign_time
          AND mid.created_at   < v_clear_time
          AND mid.id           != NEW.id
    ) THEN
        RETURN NEW;
    END IF;

    -- FIX-41：始终从时间戳计算，废弃 practice_duration 字段
    v_duration_seconds := EXTRACT(EPOCH FROM (v_clear_time - v_assign_time))::INTEGER;

    -- FIX-51B：不足 5 分钟时，主动删除已有的错误记录
    IF v_duration_seconds < 300 THEN
        DELETE FROM public.practice_sessions
        WHERE student_name = NEW.student_name
          AND session_start = v_assign_time;
        RETURN NEW;
    END IF;

    -- 时长分级处理（FIX-24 规则）
    IF v_duration_seconds > 10800 THEN        -- > 180 分钟
        v_cleaned_duration := 120;
        v_is_outlier       := TRUE;
        v_outlier_reason   := 'too_long';
    ELSIF v_duration_seconds > 7200 THEN      -- 120~180 分钟
        v_cleaned_duration := 120;
        v_is_outlier       := FALSE;
        v_outlier_reason   := 'capped_120';
    ELSE
        v_cleaned_duration := ROUND(v_duration_seconds / 60.0)::INTEGER;
        v_is_outlier       := FALSE;
        v_outlier_reason   := NULL;
    END IF;

    -- FIX-72：修正时区转换 Bug
    --   TIMESTAMPTZ AT TIME ZONE 'Asia/Shanghai' 直接返回北京时间的 TIMESTAMP，
    --   ::TIME 取出的就是正确的北京时间，不依赖服务器时区设置
    v_start_time := (v_assign_time AT TIME ZONE 'Asia/Shanghai')::TIME;
    v_end_time   := (v_clear_time  AT TIME ZONE 'Asia/Shanghai')::TIME;
    v_dow        := EXTRACT(DOW FROM (v_assign_time AT TIME ZONE 'Asia/Shanghai'))::INTEGER;

    v_spans_meal_break := (
        -- 午饭峰值时刻 12:10（周一至周五，DOW 1-5）
        (v_dow BETWEEN 1 AND 5
            AND v_start_time < '12:10:00'::TIME
            AND v_end_time   > '12:10:00'::TIME)
        OR
        -- 晚饭峰值时刻 18:10（周一/二/四/五，周三不判定，DOW 1,2,4,5）
        (v_dow IN (1, 2, 4, 5)
            AND v_start_time < '18:10:00'::TIME
            AND v_end_time   > '18:10:00'::TIME)
    );

    -- 饭点升级逻辑（too_long 最高优先级，不被降级）
    IF v_spans_meal_break AND v_outlier_reason != 'too_long' THEN
        v_is_outlier     := TRUE;
        v_outlier_reason := 'meal_break';
    END IF;

    INSERT INTO public.practice_sessions (
        student_name, student_major, student_grade,
        room_name, piano_type,
        session_start, session_end,
        raw_duration, cleaned_duration,
        is_outlier, outlier_reason, created_at
    ) VALUES (
        NEW.student_name, NEW.student_major, NEW.student_grade,
        NEW.room_name, NEW.piano_type,
        v_assign_time, v_clear_time,
        ROUND(v_duration_seconds / 60.0)::INTEGER,
        v_cleaned_duration,
        v_is_outlier,
        v_outlier_reason,
        NOW()
    )
    ON CONFLICT (student_name, session_start) DO UPDATE SET
        session_end      = EXCLUDED.session_end,
        raw_duration     = EXCLUDED.raw_duration,
        cleaned_duration = EXCLUDED.cleaned_duration,
        is_outlier       = EXCLUDED.is_outlier,
        outlier_reason   = EXCLUDED.outlier_reason;

    RETURN NEW;
END;
$$;
```

---

## 2. trigger_update_student_baseline（FIX-71 最新版）

> 文件：`fix60_weekly_update_and_baseline_trigger.sql`  最后修改：FIX-71（2026-03-20）

```sql
CREATE OR REPLACE FUNCTION public.trigger_update_student_baseline()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM public.update_student_baseline(NEW.student_name);
    RETURN NEW;
END;
$$;
```

---

## 3. run_weekly_score_update（FIX-8/60 最新版）

> 文件：`fix60_weekly_update_and_baseline_trigger.sql`

```sql
CREATE OR REPLACE FUNCTION public.run_weekly_score_update()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_student RECORD;
    v_monday  DATE;
    v_student_count INTEGER;
BEGIN
    PERFORM set_config('app.skip_score_trigger', 'on', TRUE);

    v_monday := DATE_TRUNC('week', CURRENT_DATE)::DATE;
    RAISE NOTICE '[%] 每周评分更新，快照日期：%', NOW(), v_monday;

    -- ① 更新所有学生 baseline
    FOR v_student IN SELECT student_name FROM public.student_baseline ORDER BY student_name
    LOOP
        BEGIN
            PERFORM public.compute_baseline_as_of(
                v_student.student_name, (CURRENT_DATE + INTERVAL '1 day')::DATE
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[weekly baseline] 学生 % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    -- ② 计算本周成长分快照
    FOR v_student IN SELECT student_name FROM public.student_baseline ORDER BY student_name
    LOOP
        BEGIN
            PERFORM public.compute_student_score_as_of(v_student.student_name, v_monday);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[weekly score] 学生 % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    -- ③ 归一化本周历史快照（带人数保护）
    SELECT COUNT(DISTINCT student_name) INTO v_student_count
    FROM public.student_score_history
    WHERE snapshot_date = v_monday AND raw_score IS NOT NULL;

    IF v_student_count >= 5 THEN
        UPDATE public.student_score_history h
        SET composite_score = norm.normalized
        FROM (
            SELECT student_name,
                   ROUND(PERCENT_RANK() OVER (ORDER BY raw_score) * 100)::INT AS normalized
            FROM public.student_score_history
            WHERE snapshot_date = v_monday AND raw_score IS NOT NULL
        ) norm
        WHERE h.snapshot_date = v_monday AND h.student_name = norm.student_name;
    END IF;

    -- ④ [FIX-8] 基于当前最新 raw_score 归一化 student_baseline.composite_score
    SELECT COUNT(*) INTO v_student_count
    FROM public.student_baseline WHERE raw_score IS NOT NULL;

    IF v_student_count >= 5 THEN
        UPDATE public.student_baseline b
        SET composite_score = norm.normalized
        FROM (
            SELECT student_name,
                   ROUND(PERCENT_RANK() OVER (ORDER BY raw_score) * 100)::INT AS normalized
            FROM public.student_baseline
            WHERE raw_score IS NOT NULL
        ) norm
        WHERE b.student_name = norm.student_name;
    END IF;

    -- ⑤ 同步 composite_score 到 baseline
    UPDATE public.student_baseline b
    SET composite_score = h.composite_score
    FROM public.student_score_history h
    WHERE h.student_name  = b.student_name
      AND h.snapshot_date = v_monday
      AND h.composite_score IS NOT NULL;

    PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
    RAISE NOTICE '[%] 每周更新完成', NOW();
END;
$$;
```

---

## 4. backfill_score_history（FIX-62/53F 最新版）

> 文件：`fix53_backfill_update.sql`

```sql
CREATE OR REPLACE FUNCTION public.backfill_score_history()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_start_date    DATE;
    v_end_date      DATE;
    v_current_date  DATE;
    v_next_date     DATE;
    v_student       RECORD;
    v_week_count    INTEGER := 0;
    v_active_count  INTEGER := 0;
    v_zero_count    INTEGER := 0;
    v_student_count INTEGER;
BEGIN
    PERFORM set_config('app.skip_score_trigger', 'on', TRUE);

    SELECT DATE_TRUNC('week', MIN(session_start))::DATE INTO v_start_date
    FROM public.practice_sessions WHERE cleaned_duration > 0;

    v_end_date     := DATE_TRUNC('week', CURRENT_DATE)::DATE;
    v_current_date := v_start_date;
    RAISE NOTICE '回溯范围：% → %（FIX-15）', v_start_date, v_end_date;

    WHILE v_current_date <= v_end_date LOOP
        v_week_count := v_week_count + 1;
        v_next_date  := v_current_date + INTERVAL '7 days';

        -- ① baseline
        FOR v_student IN
            SELECT DISTINCT student_name FROM public.practice_sessions
            WHERE session_start < v_current_date::TIMESTAMPTZ AND cleaned_duration > 0
            ORDER BY student_name
        LOOP
            BEGIN
                PERFORM public.compute_baseline_as_of(v_student.student_name, v_current_date);
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '[backfill baseline] % @ % 失败：%',
                    v_student.student_name, v_current_date, SQLERRM;
            END;
        END LOOP;

        -- ② 成长分：本周活跃 → 重算；本周无练 → 写 0
        FOR v_student IN
            SELECT DISTINCT student_name FROM public.practice_sessions
            WHERE session_start < v_current_date::TIMESTAMPTZ AND cleaned_duration > 0
            ORDER BY student_name
        LOOP
            BEGIN
                IF EXISTS (
                    SELECT 1 FROM public.practice_sessions
                    WHERE student_name    = v_student.student_name
                      AND cleaned_duration > 0
                      AND session_start  >= v_current_date::TIMESTAMPTZ
                      AND session_start  <  v_next_date::TIMESTAMPTZ
                ) THEN
                    PERFORM public.compute_student_score_as_of(v_student.student_name, v_current_date);
                    v_active_count := v_active_count + 1;
                ELSE
                    INSERT INTO public.student_score_history
                        (student_name, snapshot_date, raw_score, composite_score,
                         baseline_score, trend_score, momentum_score, accum_score,
                         outlier_rate, short_session_rate, mean_duration, record_count)
                    VALUES
                        (v_student.student_name, v_current_date, 0, 0,
                         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
                    ON CONFLICT (student_name, snapshot_date) DO NOTHING;
                    v_zero_count := v_zero_count + 1;
                END IF;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING '[backfill score] % @ % 失败：%',
                    v_student.student_name, v_current_date, SQLERRM;
            END;
        END LOOP;

        -- ③ PERCENT_RANK（仅活跃学生，人数<5时降级为直接存 raw）
        SELECT COUNT(DISTINCT sh.student_name) INTO v_student_count
        FROM public.student_score_history sh
        WHERE sh.snapshot_date = v_current_date
          AND sh.raw_score IS NOT NULL AND sh.raw_score > 0
          AND EXISTS (
              SELECT 1 FROM public.practice_sessions ps
              WHERE ps.student_name    = sh.student_name
                AND ps.cleaned_duration > 0
                AND ps.session_start  >= v_current_date::TIMESTAMPTZ
                AND ps.session_start  <  v_next_date::TIMESTAMPTZ);

        IF v_student_count >= 5 THEN
            UPDATE public.student_score_history h
            SET composite_score = norm.normalized
            FROM (
                SELECT sh.student_name,
                       ROUND(PERCENT_RANK() OVER (ORDER BY sh.raw_score) * 100)::INT AS normalized
                FROM public.student_score_history sh
                WHERE sh.snapshot_date = v_current_date
                  AND sh.raw_score IS NOT NULL AND sh.raw_score > 0
                  AND EXISTS (
                      SELECT 1 FROM public.practice_sessions ps
                      WHERE ps.student_name    = sh.student_name
                        AND ps.cleaned_duration > 0
                        AND ps.session_start  >= v_current_date::TIMESTAMPTZ
                        AND ps.session_start  <  v_next_date::TIMESTAMPTZ)
            ) norm
            WHERE h.snapshot_date = v_current_date AND h.student_name = norm.student_name;
        ELSE
            UPDATE public.student_score_history
            SET composite_score = ROUND((raw_score * 100)::NUMERIC, 1)
            WHERE snapshot_date = v_current_date
              AND raw_score IS NOT NULL AND raw_score > 0
              AND EXISTS (
                  SELECT 1 FROM public.practice_sessions ps
                  WHERE ps.student_name    = student_score_history.student_name
                    AND ps.cleaned_duration > 0
                    AND ps.session_start  >= v_current_date::TIMESTAMPTZ
                    AND ps.session_start  <  v_next_date::TIMESTAMPTZ);
        END IF;

        v_current_date := v_next_date;
    END LOOP;

    -- ④ 同步最新有效分数到 student_baseline
    UPDATE public.student_baseline b
    SET composite_score = latest.composite_score
    FROM (
        SELECT DISTINCT ON (student_name) student_name, composite_score
        FROM public.student_score_history
        WHERE composite_score > 0
        ORDER BY student_name, snapshot_date DESC
    ) latest
    WHERE b.student_name = latest.student_name;

    -- ⑤ FIX-62: backfill 完成后重刷所有学生基线（恢复本周状态）
    FOR v_student IN SELECT student_name FROM public.student_baseline ORDER BY student_name LOOP
        BEGIN
            PERFORM public.compute_baseline(v_student.student_name);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[backfill rebase] % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    -- ⑥ FIX-53-F: 刷新所有学生的实时 W 分
    FOR v_student IN SELECT DISTINCT student_name FROM public.student_baseline LOOP
        BEGIN
            PERFORM public.compute_and_store_w_score(v_student.student_name);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '[backfill w_score] % 失败：%', v_student.student_name, SQLERRM;
        END;
    END LOOP;

    PERFORM set_config('app.skip_score_trigger', 'off', TRUE);
    RAISE NOTICE '回溯完成（FIX-62）：共 % 周，重算 % 条，零分 % 条',
        v_week_count, v_active_count, v_zero_count;
END;
$$;
```

---

## 5. get_weekly_leaderboards（FIX-65/69 最新版）

> 文件：`leaderboard_rpc.sql`

```sql
CREATE OR REPLACE FUNCTION public.get_weekly_leaderboards()
RETURNS TABLE (
    board                 TEXT,
    rank_no               INTEGER,
    student_name          TEXT,
    student_major         TEXT,
    student_grade         TEXT,
    display_score         NUMERIC,
    alpha                 NUMERIC,
    trend_score           NUMERIC,
    mean_duration         NUMERIC,
    record_count          INTEGER,
    recent10_outlier_rate NUMERIC,
    recent10_mean_dur     NUMERIC,
    recent10_count        INTEGER
)
LANGUAGE SQL
STABLE
AS $$
WITH
week_monday AS (
    SELECT DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')::DATE AS monday
),
recent10 AS (
    SELECT
        student_name,
        COUNT(*)::INTEGER                                      AS cnt,
        ROUND(AVG((is_outlier)::INT)::NUMERIC, 4)             AS outlier_rate,
        ROUND(AVG(cleaned_duration)::NUMERIC, 2)              AS mean_dur
    FROM (
        SELECT
            student_name,
            is_outlier,
            cleaned_duration,
            ROW_NUMBER() OVER (PARTITION BY student_name ORDER BY session_start DESC) AS rn
        FROM public.practice_sessions
        WHERE cleaned_duration > 0
          AND session_start >= NOW() - INTERVAL '12 weeks'
    ) sub
    WHERE rn <= 10
    GROUP BY student_name
),
week_cnt AS (
    SELECT student_name, COUNT(*)::INTEGER AS cnt
    FROM public.practice_sessions
    CROSS JOIN week_monday
    WHERE session_start >= monday::TIMESTAMPTZ
    GROUP BY student_name
),
week_scores AS (
    SELECT ssh.student_name, ssh.composite_score, ssh.raw_score,
           ssh.trend_score, ssh.baseline_score, ssh.mean_duration,
           ssh.record_count::INTEGER, ssh.outlier_rate
    FROM public.student_score_history ssh
    CROSS JOIN week_monday wm
    WHERE ssh.snapshot_date = wm.monday AND ssh.composite_score > 0
),
last_week_scores AS (
    SELECT student_name, MAX(composite_score) AS lw_composite
    FROM (
        SELECT ssh.student_name, ssh.composite_score,
               ROW_NUMBER() OVER (PARTITION BY ssh.student_name ORDER BY ssh.snapshot_date DESC) AS rn
        FROM public.student_score_history ssh
        CROSS JOIN week_monday wm
        WHERE ssh.snapshot_date <  wm.monday
          AND ssh.snapshot_date >= wm.monday - INTERVAL '12 weeks'
          AND ssh.composite_score > 0
    ) recent
    WHERE rn <= 2
    GROUP BY student_name
),
ranked_pool AS (
    SELECT
        wc.student_name,
        sb.student_major,
        sb.student_grade,
        COALESCE(ws.composite_score, sb.composite_score)          AS display_score,
        sb.alpha,
        ws.trend_score,
        COALESCE(ws.mean_duration, sb.mean_duration)              AS mean_duration,
        COALESCE(ws.record_count, sb.record_count)::INTEGER        AS record_count,
        wc.cnt                                                    AS week_sessions
    FROM week_cnt wc
    JOIN public.student_baseline sb ON sb.student_name = wc.student_name
    LEFT JOIN week_scores ws        ON ws.student_name = wc.student_name
    WHERE COALESCE(ws.composite_score, sb.composite_score, 0) > 0
),
comp AS (
    SELECT '综合榜'::TEXT AS board,
           RANK() OVER (ORDER BY rp.display_score DESC NULLS LAST,
                                 rp.mean_duration  DESC NULLS LAST,
                                 rp.record_count   DESC NULLS LAST)::INTEGER AS rank_no,
           rp.student_name, rp.student_major, rp.student_grade,
           rp.display_score, rp.alpha, rp.trend_score, rp.mean_duration, rp.record_count,
           r10.outlier_rate AS recent10_outlier_rate,
           r10.mean_dur     AS recent10_mean_dur,
           r10.cnt          AS recent10_count
    FROM ranked_pool rp
    LEFT JOIN recent10 r10 ON r10.student_name = rp.student_name
),
comp_top10 AS (SELECT student_name FROM comp WHERE rank_no <= 10),
prog AS (
    SELECT '进步榜'::TEXT AS board,
           RANK() OVER (ORDER BY (rp.display_score - lws.lw_composite) DESC NULLS LAST,
                                  rp.display_score DESC NULLS LAST,
                                  rp.mean_duration DESC NULLS LAST)::INTEGER AS rank_no,
           rp.student_name, rp.student_major, rp.student_grade,
           rp.display_score, rp.alpha,
           ROUND((rp.display_score - lws.lw_composite)::NUMERIC, 1) AS trend_score,
           rp.mean_duration, rp.record_count,
           r10.outlier_rate AS recent10_outlier_rate,
           r10.mean_dur     AS recent10_mean_dur,
           r10.cnt          AS recent10_count
    FROM ranked_pool rp
    INNER JOIN last_week_scores lws ON lws.student_name = rp.student_name
    LEFT JOIN  recent10         r10 ON r10.student_name = rp.student_name
    WHERE (rp.display_score - lws.lw_composite) >  0
      AND rp.week_sessions                      >= 2
      AND COALESCE(r10.outlier_rate, 1)         <= 0.50
      AND rp.student_name NOT IN (SELECT student_name FROM comp_top10)
),
stable AS (
    SELECT '稳定榜'::TEXT AS board,
           RANK() OVER (ORDER BY rp.alpha               DESC NULLS LAST,
                                 COALESCE(r10.mean_dur, 0) DESC NULLS LAST,
                                 COALESCE(r10.outlier_rate, 1) ASC)::INTEGER AS rank_no,
           rp.student_name, rp.student_major, rp.student_grade,
           rp.display_score, rp.alpha, rp.trend_score, rp.mean_duration, rp.record_count,
           r10.outlier_rate AS recent10_outlier_rate,
           r10.mean_dur     AS recent10_mean_dur,
           r10.cnt          AS recent10_count
    FROM ranked_pool rp
    LEFT JOIN recent10 r10 ON r10.student_name = rp.student_name
    WHERE COALESCE(rp.alpha, 0)         >= 0.55
      AND COALESCE(r10.cnt, 0)          >= 8
      AND COALESCE(r10.outlier_rate, 1) <= 0.40
      AND rp.student_name NOT IN (SELECT student_name FROM comp_top10)
),
rules AS (
    SELECT '守则榜'::TEXT AS board,
           RANK() OVER (ORDER BY COALESCE(r10.outlier_rate, 1) ASC,
                                 rp.week_sessions              DESC NULLS LAST,
                                 COALESCE(r10.mean_dur, 0)     DESC)::INTEGER AS rank_no,
           rp.student_name, rp.student_major, rp.student_grade,
           rp.display_score, rp.alpha, rp.trend_score, rp.mean_duration, rp.record_count,
           r10.outlier_rate AS recent10_outlier_rate,
           r10.mean_dur     AS recent10_mean_dur,
           r10.cnt          AS recent10_count
    FROM ranked_pool rp
    LEFT JOIN recent10 r10 ON r10.student_name = rp.student_name
    WHERE rp.week_sessions              >= 3
      AND COALESCE(r10.cnt, 0)          >= 4
      AND COALESCE(r10.mean_dur, 0)     > 25
      AND COALESCE(r10.outlier_rate, 1) <= 0.50
      AND COALESCE(rp.alpha, 0)         >= 0.55
      AND rp.student_name NOT IN (SELECT student_name FROM comp_top10)
)
SELECT board, rank_no, student_name, student_major, student_grade,
       display_score, alpha, trend_score, mean_duration, record_count,
       recent10_outlier_rate, recent10_mean_dur, recent10_count
FROM comp
UNION ALL
SELECT board, rank_no, student_name, student_major, student_grade,
       display_score, alpha, trend_score, mean_duration, record_count,
       recent10_outlier_rate, recent10_mean_dur, recent10_count
FROM prog
UNION ALL
SELECT board, rank_no, student_name, student_major, student_grade,
       display_score, alpha, trend_score, mean_duration, record_count,
       recent10_outlier_rate, recent10_mean_dur, recent10_count
FROM stable
UNION ALL
SELECT board, rank_no, student_name, student_major, student_grade,
       display_score, alpha, trend_score, mean_duration, record_count,
       recent10_outlier_rate, recent10_mean_dur, recent10_count
FROM rules
ORDER BY board, rank_no;
$$;

GRANT EXECUTE ON FUNCTION public.get_weekly_leaderboards() TO anon, authenticated;
```

---

## 6. get_auto_reward_setting（FIX-68 最新版）

> 文件：`fix_auto_reward_rls.sql`

```sql
CREATE OR REPLACE FUNCTION public.get_auto_reward_setting()
RETURNS TABLE(enabled BOOLEAN, updated_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT
        (value = 'true') AS enabled,
        s.updated_at
    FROM public.system_settings s
    WHERE s.key = 'auto_coin_reward_enabled'
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN QUERY SELECT TRUE, NOW();
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_auto_reward_setting() TO anon, authenticated;
```

---

## 触发器绑定关系（当前最新）

| 触发器名 | 所属表 | 时机 | 事件 | 绑定函数 |
|---------|--------|------|------|---------|
| `trg_insert_session` | `practice_logs` | AFTER | INSERT | `trigger_insert_session()` |
| `trg_update_baseline` | `practice_sessions` | AFTER | INSERT | `trigger_update_student_baseline()` |
| `trg_compute_score_on_baseline_update` | `student_baseline` | AFTER | UPDATE | `trigger_compute_student_score()` |


---

## 7. compute_baseline（最新版）

> 简单 wrapper，调用 `compute_baseline_as_of(今天+1天)`，确保包含今天所有数据。

```sql
CREATE OR REPLACE FUNCTION public.compute_baseline(p_student_name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    PERFORM public.compute_baseline_as_of(
        p_student_name,
        (CURRENT_DATE + INTERVAL '1 day')::DATE
    );
END;
$$;
```

---

## 8. update_student_baseline（最新版）

> 简单 wrapper，供触发器调用。

```sql
CREATE OR REPLACE FUNCTION public.update_student_baseline(p_student_name text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM public.compute_baseline(p_student_name);
END;
$$;
```

---

## 9. set_auto_reward_enabled（FIX-68 最新版）

> 文件：`fix_auto_reward_rls.sql`  SECURITY DEFINER，写入 system_settings 表。

```sql
CREATE OR REPLACE FUNCTION public.set_auto_reward_enabled(p_enabled boolean)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    INSERT INTO public.system_settings (key, value, updated_at)
    VALUES ('auto_coin_reward_enabled', p_enabled::TEXT, NOW())
    ON CONFLICT (key) DO UPDATE
        SET value      = p_enabled::TEXT,
            updated_at = NOW();
    RETURN p_enabled;
END;
$$;
```

---

## 10. clean_duration（FIX-53-H 最新版，新签名：student text, raw_dur float8）

> 文件：`fix53_clean_duration.sql`  注意：数据库中有两个重载，旧签名 `(raw_dur, student)` 保留兼容，新签名 `(student, raw_dur)` 为最新版。

```sql
CREATE OR REPLACE FUNCTION public.clean_duration(student text, raw_dur double precision)
RETURNS TABLE(cleaned_dur double precision, is_outlier boolean, reason text)
LANGUAGE plpgsql
AS $$
DECLARE
    student_mean      FLOAT;
    student_std       FLOAT;
    record_cnt        INTEGER;
    last_session_date TIMESTAMPTZ;
    days_since_last   INTEGER;
    use_personal_det  BOOLEAN;
BEGIN
    SELECT mean_duration, std_duration, record_count
    INTO student_mean, student_std, record_cnt
    FROM public.student_baseline
    WHERE student_name = student;

    IF raw_dur IS NULL THEN
        RETURN QUERY SELECT 0::FLOAT, TRUE, 'no_duration'::TEXT;
        RETURN;
    END IF;

    IF raw_dur < 5 THEN
        RETURN QUERY SELECT 0::FLOAT, TRUE, 'too_short'::TEXT;
        RETURN;
    END IF;

    -- FIX-53-H: 停练归来检测——查最近一次有效练琴时间间隔
    SELECT MAX(session_start) INTO last_session_date
    FROM public.practice_sessions
    WHERE student_name = student AND cleaned_duration > 0;

    days_since_last := COALESCE(
        EXTRACT(DAYS FROM (NOW() - last_session_date))::INTEGER,
        999
    );

    -- 同时满足以下全部条件才使用个人离群检测：
    -- ① record_count >= 10  ② std > 1.0  ③ 近期有持续练琴（30天内）
    use_personal_det := student_mean IS NOT NULL
                    AND student_std IS NOT NULL
                    AND student_std > 1.0
                    AND COALESCE(record_cnt, 0) >= 10
                    AND days_since_last <= 30;

    IF use_personal_det THEN
        IF raw_dur > student_mean + 3 * student_std THEN
            RETURN QUERY SELECT (student_mean + student_std)::FLOAT, TRUE, 'personal_outlier'::TEXT;
            RETURN;
        END IF;
    ELSE
        -- 冷启动期 / std 不可靠 / 停练归来：改用全局硬上限 180 分钟
        IF raw_dur > 180 THEN
            RETURN QUERY SELECT 120::FLOAT, TRUE,
                CASE WHEN days_since_last > 30
                     THEN 'global_cap_returning'   -- 停练归来降级标记
                     ELSE 'global_cap_cold_start'
                END::TEXT;
            RETURN;
        END IF;
    END IF;

    IF raw_dur > 120 THEN
        RETURN QUERY SELECT 120::FLOAT, FALSE, 'capped_120'::TEXT;
        RETURN;
    END IF;

    RETURN QUERY SELECT raw_dur, FALSE, NULL::TEXT;
END;
$$;
```

---

## 11. compute_and_store_w_score（FIX-54 最新版）

> 文件：`fix54_w_score_sunday.sql`  SECURITY DEFINER，计算并写入本周 W 分。

```sql
CREATE OR REPLACE FUNCTION public.compute_and_store_w_score(p_student_name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_mean_duration   FLOAT8;
    v_weekly_minutes  FLOAT8;
    v_elapsed_days    INT;
    v_ratio           FLOAT8;
    v_w_score         FLOAT8;
    v_dow             INT;
    v_week_start      TIMESTAMPTZ;
    v_median_mean     FLOAT8;
    v_major           TEXT;
    v_major_count     INT;
    v_shrink_alpha    FLOAT8;
    v_effective_mean  FLOAT8;
BEGIN
    SELECT mean_duration, student_major
    INTO v_mean_duration, v_major
    FROM public.student_baseline
    WHERE student_name = p_student_name;

    -- FIX-37: 同专业优先计算中位数
    SELECT COUNT(*) INTO v_major_count
    FROM public.student_baseline
    WHERE student_major = v_major AND mean_duration > 0;

    IF v_major_count >= 5 THEN
        SELECT percentile_cont(0.50) WITHIN GROUP (ORDER BY mean_duration)
        INTO v_median_mean
        FROM public.student_baseline
        WHERE mean_duration IS NOT NULL AND mean_duration > 0
          AND student_major = v_major;
    ELSE
        SELECT percentile_cont(0.50) WITHIN GROUP (ORDER BY mean_duration)
        INTO v_median_mean
        FROM public.student_baseline
        WHERE mean_duration IS NOT NULL AND mean_duration > 0;
    END IF;

    -- 贝叶斯收缩
    SELECT record_count INTO v_shrink_alpha
    FROM public.student_baseline
    WHERE student_name = p_student_name;
    v_shrink_alpha   := LEAST(1.0, COALESCE(v_shrink_alpha, 0)::FLOAT8 / 15.0);
    v_effective_mean := v_shrink_alpha * COALESCE(v_mean_duration, 0.0)
                      + (1.0 - v_shrink_alpha) * COALESCE(v_median_mean, 30.0);
    v_effective_mean := GREATEST(v_effective_mean, 15.0);

    -- FIX-26: 北京时间本周一
    v_week_start := DATE_TRUNC('week', NOW() AT TIME ZONE 'Asia/Shanghai')
                      AT TIME ZONE 'Asia/Shanghai';

    -- 只统计工作日
    SELECT COALESCE(SUM(cleaned_duration), 0) INTO v_weekly_minutes
    FROM public.practice_sessions
    WHERE student_name = p_student_name
      AND session_start >= v_week_start
      AND EXTRACT(DOW FROM session_start AT TIME ZONE 'Asia/Shanghai') NOT IN (0, 6);

    v_dow := EXTRACT(DOW FROM NOW() AT TIME ZONE 'Asia/Shanghai')::INT;
    -- FIX-54: 周日(DOW=0)和周六(DOW=6)均视为已过5个工作日
    v_elapsed_days := CASE v_dow
        WHEN 0 THEN 5
        WHEN 6 THEN 5
        ELSE v_dow
    END;

    IF v_elapsed_days = 0 OR v_effective_mean <= 0 THEN
        v_w_score := 0.5;
    ELSE
        v_ratio   := v_weekly_minutes / (GREATEST(v_effective_mean, 30.0) * v_elapsed_days);
        v_w_score := 1.0 / (1.0 + EXP(-3.0 * (v_ratio - 0.5)));
    END IF;

    PERFORM set_config('app.skip_score_trigger', 'on', true);
    UPDATE public.student_baseline SET w_score = v_w_score WHERE student_name = p_student_name;
    PERFORM set_config('app.skip_score_trigger', 'off', true);
END;
$$;
```

---

## 完整函数版本对照表（数据库 vs 本地，2026-03-20 核查）

| 函数名 | 数据库状态 | 本地最新文件 | 版本特征 |
|--------|----------|------------|---------|
| `trigger_insert_session` | ✅ 最新 | `fix_stale_cleaned_duration.sql` | FIX-72 时区修正 |
| `trigger_update_student_baseline` | ✅ 最新 | `fix60_weekly_update_and_baseline_trigger.sql` | FIX-71 每次必触发 |
| `run_weekly_score_update` | ✅ 最新 | `fix60_weekly_update_and_baseline_trigger.sql` | FIX-8 raw_score IS NOT NULL |
| `backfill_score_history` | ✅ 最新 | `fix53_backfill_update.sql` | FIX-62/70 NUMERIC 精度 |
| `get_weekly_leaderboards` | ✅ 最新 | `leaderboard_rpc.sql` | FIX-65/69 comp_top10+绝对涨分 |
| `get_auto_reward_setting` | ✅ 最新 | `fix_auto_reward_rls.sql` | FIX-68 SECURITY DEFINER |
| `set_auto_reward_enabled` | ✅ 最新 | `fix_auto_reward_rls.sql` | FIX-68 UPSERT |
| `compute_student_score` | ✅ 最新 | `fix44_46_score_functions.sql` | FIX-70 NUMERIC + FIX-57 W=70% |
| `compute_student_score_as_of` | ✅ 最新 | `fix44_46_score_functions.sql` | FIX-57 W=70% |
| `compute_baseline_as_of` | ✅ 最新 | `fix55_baseline_weekday_filter.sql` | FIX-55 NOT IN(0,6)×6+ |
| `compute_baseline` | ✅ 最新 | — | 简单 wrapper |
| `update_student_baseline` | ✅ 最新 | — | 简单 wrapper |
| `clean_duration`（新） | ✅ 最新 | `fix53_clean_duration.sql` | FIX-53-H global_cap_returning |
| `clean_duration`（旧） | ⚠️ 旧重载 | 已废弃 | 旧签名 (raw_dur, student)，保留兼容 |
| `compute_and_store_w_score` | ✅ 最新 | `fix54_w_score_sunday.sql` | FIX-54 WHEN 0 THEN 5 |


---

## FIX-73：trigger_insert_session / trigger_update_student_baseline 补回 SECURITY DEFINER

**日期**：2026-03-20
**文件**：`fix_stale_cleaned_duration.sql`、`fix60_weekly_update_and_baseline_trigger.sql`

### 问题

触发链诊断发现 `trigger_insert_session` 和 `trigger_update_student_baseline` 均缺少 `SECURITY DEFINER`，安全模式为普通权限。

**根因**：FIX-22（2026-03-16）通过 `ALTER FUNCTION ... SECURITY DEFINER` 为这两个函数添加了权限，但后续的 FIX-72（trigger_insert_session）和 FIX-71（trigger_update_student_baseline）使用 `CREATE OR REPLACE FUNCTION` 重新定义函数时，没有携带 `SECURITY DEFINER` 关键字，导致属性被覆盖清除。

### 影响

不带 SECURITY DEFINER 时，anon 角色触发这两个函数会以 anon 身份执行。若 `practice_sessions` 或 `student_baseline` 表启用了 RLS 限制 anon 写入，整个触发链会因权限不足而中断，导致练琴记录无法写入或分数无法更新。

### 修复内容

两个文件均补充 `SECURITY DEFINER`：

```sql
-- fix_stale_cleaned_duration.sql
CREATE OR REPLACE FUNCTION public.trigger_insert_session()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER   -- FIX-22 补回：绕过 anon 角色 RLS 限制
AS $$ ... $$;

-- fix60_weekly_update_and_baseline_trigger.sql
CREATE OR REPLACE FUNCTION public.trigger_update_student_baseline()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER   -- FIX-22 补回：绕过 anon 角色 RLS 限制
AS $$ ... $$;
```

### 部署步骤

在 Supabase SQL Editor 依次运行：
1. `fix_stale_cleaned_duration.sql`（重新部署 trigger_insert_session）
2. `fix60_weekly_update_and_baseline_trigger.sql`（重新部署 trigger_update_student_baseline）

运行后用 `check_db_versions.sql` 第零部分 B 段验证三个触发函数均为 SECURITY DEFINER。

---

## FIX-74：删除百分位归一化，composite_score 改为纯绝对分

**日期**：2026-03-21
**文件**：`fix74_remove_percentile.sql`（新建），同步修改 `fix60_weekly_update_and_baseline_trigger.sql` 和 `fix53_backfill_update.sql`

### 问题

`composite_score` 曾有两套计算逻辑：
- **实时触发时**（每次练琴后）：`composite_score = raw_score × 100`
- **每周任务时**（`run_weekly_score_update`）：`composite_score = PERCENT_RANK(raw_score) × 100`

两套逻辑并存导致：
1. 分数含义不一致，学生努力练习后分数反而可能因同学提升而下降
2. 排行榜上显示的分数对学生不透明，难以解释
3. 实时触发写入绝对分，每周任务覆盖为相对百分位分，学生困惑

### 修复内容

统一所有情况：**`composite_score = ROUND(raw_score × 100, 1)`**

| 函数 | 修改内容 |
|------|---------|
| `run_weekly_score_update()` | 删除步骤③（history PERCENT_RANK）、步骤④（baseline PERCENT_RANK），合并为一步直接同步 |
| `backfill_score_history()` | 步骤③ 删除 IF student_count>=5 分支，改为直接换算兜底修正 |

### 修改对比

**run_weekly_score_update 修改前（步骤③④）**：
```sql
-- ③ 归一化本周历史快照
IF v_student_count >= 5 THEN
    UPDATE student_score_history SET composite_score = PERCENT_RANK() OVER ...
END IF;

-- ④ 归一化 student_baseline
IF v_student_count >= 5 THEN
    UPDATE student_baseline SET composite_score = PERCENT_RANK() OVER ...
END IF;
```

**修改后（步骤③）**：
```sql
-- ③ 直接同步（无百分位）
UPDATE student_baseline b
SET composite_score = h.composite_score   -- 已是 raw_score×100
FROM student_score_history h ...;
```

### composite_score 含义变化

| | 修改前 | 修改后 |
|--|--------|--------|
| 实时触发 | raw_score × 100 | raw_score × 100 |
| 每周任务后 | PERCENT_RANK × 100（0~100 之间的班级百分位） | raw_score × 100 |
| 分数范围 | 0~100（百分位） | 0~100（理论上限，实际约 30~80） |
| 含义 | 相对排名分 | **绝对成长分** |
| 是否影响排名顺序 | — | **不影响**（仍按 composite_score 降序） |

### 部署步骤

1. 在 Supabase SQL Editor 运行 **`fix74_remove_percentile.sql`**（约 5 秒，更新两个函数定义）
2. 运行历史数据重算（约 1~3 分钟）：
   ```sql
   SELECT public.backfill_score_history();
   ```
3. 验证：随机抽查几个学生，确认 `composite_score ≈ raw_score × 100`：
   ```sql
   SELECT student_name,
          raw_score,
          composite_score,
          ROUND((raw_score * 100)::NUMERIC, 1) AS expected
   FROM public.student_baseline
   WHERE raw_score IS NOT NULL
   LIMIT 10;
   ```

### 更新后版本表

| 函数名 | 状态 | Fix ID | 本地文件 |
|--------|------|--------|---------|
| `run_weekly_score_update` | ✅ 最新 | FIX-75（快照=终点分）+ FIX-74 | `fix60_weekly_update_and_baseline_trigger.sql` |
| `backfill_score_history` | ✅ 最新 | FIX-74 + FIX-62 + FIX-53-F | `fix53_backfill_update.sql` |

---

## FIX-75：修复 run_weekly_score_update 快照逻辑

**日期**：2026-03-21
**文件**：`fix75_weekly_snapshot_fix.sql`（新建），同步修改 `fix60_weekly_update_and_baseline_trigger.sql`

### 问题

FIX-74 遗留了一个设计缺陷：

| | 期望 | 实际（FIX-74 旧版）|
|--|------|-----------------|
| 快照内容 | 周五终点分（含全周练习） | 周一起点分（只含上周数据）|
| 进步榜基准 | 上周周五终点分 | 上周周一起点分（偏低）|
| 结果 | 真实反映进步 | 基准虚低，容易虚假上榜 |

具体后果：
- `compute_student_score_as_of(student, 本周一)` 只看本周一之前的数据，算出"起点分"
- 覆盖掉实时触发器已写入的"终点分"
- 步骤③再把"起点分"写回 `student_baseline`，排行榜分数骤降

### 修复内容

**步骤②改为**：只给本周未练琴的学生补写快照，调用 `compute_student_score()`（实时版），不再调用 `_as_of` 版本

```sql
-- 已练琴学生：实时触发器已维护 student_score_history[本周一] = 终点分 ✅
-- 未练琴学生：触发器未触发，手动补写（体现停练惩罚）
FOR v_student IN
    SELECT student_name FROM student_baseline
    WHERE student_name NOT IN (
        SELECT DISTINCT student_name FROM practice_sessions
        WHERE session_start >= v_monday::TIMESTAMPTZ AND cleaned_duration > 0
    )
LOOP
    PERFORM public.compute_student_score(v_student.student_name);
END LOOP;
```

**删除步骤③**：不再把快照分同步回 `student_baseline`，触发器全权负责实时维护。

### 修复后效果

```
周一~周五 实时触发器
  → student_score_history[本周一] = 累积终点分（72分）  ✅

周五 21:35 run_weekly_score_update
  → 步骤① 全员基线重算
  → 步骤② 未练琴学生补写快照（衰减后的分）
  → 无步骤③，student_baseline 不被覆盖

下周进步榜基准 = 72分（真实上周终点分）✅
排行榜分数不再因周任务运行而骤降 ✅
```

---

## 全系统审查报告（2026-03-21）

本次审查覆盖所有得分、快照、排行榜相关函数，逐一核查 FIX-74、FIX-75 部署后的系统状态。

---

### 一、触发链完整性 ✅

```
practice_logs INSERT
  → trg_insert_session → trigger_insert_session()
      → 写入 practice_sessions（含 cleaned_duration、is_outlier）

practice_sessions INSERT
  → trg_update_baseline → trigger_update_student_baseline()  [SECURITY DEFINER]
      → update_student_baseline() → compute_baseline_as_of(student, 今天+1)
          → 更新 student_baseline.mean_duration / alpha / outlier_rate 等基线统计
          → ⚠️ 不更新 composite_score（confirmed：代码中无此字段赋值）

student_baseline UPDATE
  → trg_compute_score_on_baseline_update → trigger_compute_student_score()  [SECURITY DEFINER]
      → compute_student_score(student)
          → 读取 student_baseline 基线统计（刚被上一步更新的值）
          → 写入 student_score_history[本周一]（ON CONFLICT DO UPDATE）
          → 写入 student_baseline.composite_score / raw_score / last_updated
```

**结论**：三段触发链完整、顺序正确，每次打卡后分数立即刷新。

---

### 二、得分公式正确性 ✅

| 维度 | 数据范围 | 周末过滤 |
|------|---------|---------|
| B 基线 | 本周一之前 8 周 | ✅ DOW NOT IN (0,6) |
| T 趋势 | 本周一之前 20 周（取近4活跃周） | ✅ |
| M 动量 | 本周一之前 12 周 | ✅ |
| A 累积 | 全历史（记录数+质量） | ✅（baseline stats 已过滤） |
| W 本周 | 本周一到现在（当前周实时） | ✅ DOW NOT IN (0,6) |

**FIX-74**：`composite_score = ROUND(raw_score × 100, 1)` 全链路统一，无百分位 ✅

---

### 三、快照逻辑正确性 ✅

| 情况 | 写入方式 | 数据 |
|------|---------|------|
| 当周练琴 | 实时触发器 ON CONFLICT DO UPDATE | 最新累积终点分 |
| 当周未练 | run_weekly_score_update 步骤② | score=0（体现停练） |
| 停练>30天 | compute_student_score 早期返回 ON CONFLICT DO NOTHING | 保留上次有效分，不覆盖 |
| 历史回溯 | backfill 逐周调用 _as_of + compute_baseline_as_of | 含那周完整 W 数据 |

**关键确认**：`compute_baseline_as_of()` 只更新 mean_duration/alpha/outlier_rate 等统计字段，**不触及 composite_score**，FIX-75 删除步骤③正确。

---

### 四、排行榜计算正确性 ✅

**综合榜** `display_score = COALESCE(week_scores.composite_score, student_baseline.composite_score)`
- 优先用 `student_score_history[本周一]`（实时触发器已写入本周累积分）
- 回退到 `student_baseline.composite_score`（同一值，两路互为冗余保护）✅

**进步榜** `涨幅 = display_score - MAX(近2活跃周快照)`
- `last_week_scores` 用 `WHERE snapshot_date < 本周一`，正确排除当周 ✅
- 取近2活跃周 MAX，防节假日低分周当基准（虽然对强势学生较严格，属设计取舍）✅

**稳定榜** 按 alpha 降序，数据来自 `student_baseline.alpha`（触发链实时维护）✅

**守则榜** `week_sessions >= 3`，来自 `week_cnt`（含周末次数，与前端口径一致，属设计取舍）✅

---

### 五、每周定时任务流程 ✅

```
周五 21:30  backup_weekly_leaderboards_job   快照备份当前排行榜
周五 21:32  reward_weekly_coins_job           读实时分发币（student_baseline）
周五 21:35  weekly_score_update_job           ← FIX-74/75 新增

  步骤① compute_baseline_as_of(all, 今天+1)
        更新全员基线统计，含本周未练琴的学生
        ⚠️ 会更新 student_baseline.last_updated = NOW()
           （含未练琴学生，这是基线重算时间戳，非练琴时间）

  步骤② compute_student_score(只针对本周未练琴学生)
        写入 student_score_history[本周一] = 0（停练记录）
        不更新 student_baseline.composite_score（早期返回机制）

  注：已练琴学生 → 步骤①更新基线统计后，next_practice 时触发器会自动
       用新基线重算分数。本周剩余时间内若无新练习，分数保持最后触发时的值。
```

---

### 六、发现的设计取舍（非 Bug）

| 编号 | 描述 | 影响 | 建议 |
|------|------|------|------|
| D-1 | 步骤①更新基线后，本周内已有快照不会立即重算 | 本周剩余无练习则快照不同步新基线 | 可接受，下次练习后自动修正 |
| D-2 | 进步榜基准取近2周 MAX，强势周后较难上进步榜 | 对勤练学生略严格 | 属设计取舍，防节假日虚进步 |
| D-3 | `week_cnt` 含周末次数，影响守则榜出勤门槛 | 周末练琴次数计入 `>= 3` 判断 | 已与前端口径一致，属设计取舍 |
| D-4 | `student_baseline.last_updated` 含基线重算时间，非纯练琴时间 | 若前端显示此字段会有误导 | 建议前端改用 `practice_sessions` 最近记录时间 |

---

### 七、当前函数版本总表（审查后最终版）

| 函数名 | Fix ID | 本地文件 |
|--------|--------|---------|
| `compute_student_score` | FIX-70 + FIX-57 + FIX-56 + FIX-53 | `fix44_46_score_functions.sql` |
| `compute_student_score_as_of` | FIX-70 + FIX-57 | `fix44_46_score_functions.sql` |
| `compute_baseline_as_of` | FIX-55（全周末过滤）| `fix55_baseline_weekday_filter.sql` |
| `run_weekly_score_update` | **FIX-75** + FIX-74 | `fix60_weekly_update_and_baseline_trigger.sql` |
| `backfill_score_history` | FIX-74 + FIX-62 + FIX-53-F | `fix53_backfill_update.sql` |
| `get_weekly_leaderboards` | FIX-69 + FIX-65 | `leaderboard_rpc.sql` |
| `trigger_insert_session` | FIX-73 + FIX-72 + FIX-51B | `fix_stale_cleaned_duration.sql` |
| `trigger_update_student_baseline` | FIX-73 + FIX-71 | `fix60_weekly_update_and_baseline_trigger.sql` |
| `trigger_compute_student_score` | FIX-23/22（SECURITY DEFINER）| 数据库直接管理 |
| `reward_weekly_coins` | FIX-68 | `setup_coin_rewards.sql` |

---

### 八、待部署清单（数据库尚未执行的文件）

按顺序在 Supabase SQL Editor 执行：

1. `fix74_remove_percentile.sql` — 第1段（run_weekly_score_update）
2. `fix74_remove_percentile.sql` — 第2段（backfill_score_history）
3. `fix75_weekly_snapshot_fix.sql` — run_weekly_score_update FIX-75
4. `setup_weekly_score_cron.sql` — 注册周五 21:35 定时任务
5. `SELECT public.backfill_score_history();` — 历史数据全量重算（约1~3分钟）

---

## 第二轮深度排查（2026-03-21）

本轮针对“排行榜每周波动是否准确、周末是否误计入、快照/回溯是否存在时间边界偏差”做了更细的代码级复核，发现以下 **真实风险点**。

### P1：`DATE::TIMESTAMPTZ` 时区边界错误，会把周一凌晨的记录分到上一周

**影响文件**：
- `leaderboard_rpc.sql`
- `fix53_backfill_update.sql`
- `fix60_weekly_update_and_baseline_trigger.sql`

**问题代码模式**：

```sql
WHERE session_start >= monday::TIMESTAMPTZ
WHERE session_start >= v_current_date::TIMESTAMPTZ
WHERE session_start <  v_next_date::TIMESTAMPTZ
```

这些写法把 `DATE` 直接强转成 `TIMESTAMPTZ`，实际会使用数据库 session 的时区（Supabase 通常是 UTC），而不是系统实际使用的 **北京时间**。

### 具体后果

如果学生在 **周一 00:00 ~ 07:59（北京时间）** 练琴：

- `get_weekly_leaderboards()` 的 `week_cnt` 可能把这次记录当成“上一周”
- `run_weekly_score_update()` 识别“本周是否练过”时可能漏掉这类学生
- `backfill_score_history()` 重算历史时，活跃周判断和整周窗口可能整体向后偏 8 小时

### 正确写法

应统一改成：

```sql
(monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai'
(v_current_date::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai'
(v_next_date::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai'
```

**结论**：这是当前排行榜/快照系统里最需要修的真实 Bug。

---

### P1：周末记录仍在影响排行榜资格，与“周末不算分”规则冲突

**影响文件**：`leaderboard_rpc.sql`

#### 1. `week_cnt` 没有过滤周末

```sql
week_cnt AS (
    SELECT student_name, COUNT(*)::INTEGER AS cnt
    FROM public.practice_sessions
    CROSS JOIN week_monday
    WHERE session_start >= monday::TIMESTAMPTZ
    GROUP BY student_name
)
```

这里没有 `EXTRACT(DOW ...) NOT IN (0, 6)`。

#### 2. `recent10` 也没有过滤周末

```sql
FROM public.practice_sessions
WHERE cleaned_duration > 0
  AND session_start >= NOW() - INTERVAL '12 weeks'
```

这会导致：

- **进步榜** 的 `week_sessions >= 2` 可能被周末练琴凑满
- **守则榜** 的 `week_sessions >= 3` 可能把周末次数也算进出勤
- **稳定榜 / 守则榜** 的近10条异常率、近10条均时会被周末数据干扰

### 更严重的一点

`ranked_pool` 用的是：

```sql
COALESCE(ws.composite_score, sb.composite_score) AS display_score
```

如果一个学生 **本周只有周末练琴**：

- `week_cnt` 会把他视为“本周有练”
- 但 `compute_student_score()` 因无工作日练琴，通常不会生成正的 `week_scores`
- 结果榜单会退回去读旧的 `student_baseline.composite_score`

也就是：**学生本周实际上不应参与排行榜，却可能带着旧分重新上榜。**

**结论**：如果业务规则已经确定“周六周日练琴数据都不算”，这里必须改。

---

### P2：如果未执行 `backfill_score_history()`，进步榜和历史趋势会混用“旧百分位分”和“新绝对分”

**影响文件**：
- `leaderboard_rpc.sql`
- `fix44_46_score_functions.sql`
- `fix53_backfill_update.sql`

#### 原因

FIX-74 已把 `composite_score` 改为：

```sql
ROUND(raw_score * 100, 1)
```

但进步榜基准和成长加速度仍然读取历史 `student_score_history.composite_score`：

```sql
-- leaderboard_rpc.sql
MAX(composite_score) AS lw_composite

-- fix44_46_score_functions.sql
SELECT sh.composite_score::FLOAT8 AS sc
FROM public.student_score_history sh
```

如果数据库里旧历史还没通过 `backfill_score_history()` 全量重算，就会出现：

- 当前周：绝对分
- 历史周：旧百分位分

二者混用后：

- 进步榜涨幅失真
- `growth_velocity` 失真
- 排名波动看起来会“怪”

**结论**：FIX-74 部署后，`SELECT public.backfill_score_history();` 不是可选项，而是必须项。

---

### P3：系统架构文档已落后于当前真实代码

**影响文件**：`系统架构文档.md`

当前文档仍存在几处过时描述，例如：

- 未写入 `weekly_score_update_job`
- 仍把部分排行榜口径描述成旧规则
- 对 `alpha`、进步榜展示字段的描述与当前代码不完全一致

**影响**：不会直接导致分数错误，但会误导后续维护、人工核查和前端文案同步。

---

## 本轮最终判断

### 已确认没问题的部分

- 触发链本身：`practice_logs → practice_sessions → student_baseline → compute_student_score`
- FIX-74：去百分位方向正确
- FIX-75：不再把周任务快照写回 `student_baseline`，方向正确
- 历史回溯 `_as_of`：**包含该历史周完整 W 数据**，不是“只算周一起点”

### 仍需处理的真实问题

1. **修复所有 `DATE::TIMESTAMPTZ` 的北京时间边界问题**
2. **把排行榜的 `week_cnt` / `recent10` 统一改成工作日口径**
3. **确认数据库已执行 `backfill_score_history()`，否则进步榜仍可能失真**

---

## FIX-76：北京时间边界修正 + 周末不计榜

**日期**：2026-03-21  
**文件**：`fix76_beijing_boundary_and_weekend_alignment.sql`（新建）  
**同步修改**：`leaderboard_rpc.sql`、`fix55_baseline_weekday_filter.sql`、`fix47_alpha_outlier_penalty.sql`、`fix53_backfill_update.sql`、`fix60_weekly_update_and_baseline_trigger.sql`、`practiceanalyse.html`、`系统架构文档.md`、`README.md`

### 本次修复解决了什么

#### 1. 北京时间周边界偏移

原来多处写法是：

```sql
session_start >= monday::TIMESTAMPTZ
session_start <  p_as_of_date::TIMESTAMPTZ
```

这会依赖数据库 session 时区（通常是 UTC），导致北京时间周一凌晨的数据有机会被算进上一周。

现在统一改为：

```sql
(monday::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai'
(p_as_of_date::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai'
```

修复后：
- 周一 00:00 ~ 07:59（北京时间）的记录不再误分周
- 每周快照、历史回溯、基线截止时间全部统一按北京时间

#### 2. 周末不再影响排行榜资格

`leaderboard_rpc.sql` 中：
- `recent10` 改为只统计**工作日**
- `week_cnt` 改为只统计**工作日**

修复后：
- 进步榜的 `本周工作日 ≥ 2 次` 不再被周末练琴凑数
- 守则榜的 `本周工作日 ≥ 3 次` 不再把周末算进出勤
- 稳定榜 / 守则榜的近10条异常率、近10条均时与评分口径一致

#### 3. `compute_baseline` / `compute_baseline_as_of` 统一北京时间截止点

之前 `compute_baseline_as_of()` 内部所有 `< p_as_of_date::TIMESTAMPTZ` 也存在同样的 8 小时边界风险。

现已统一使用：

```sql
v_asof_bjt := (p_as_of_date::TIMESTAMP) AT TIME ZONE 'Asia/Shanghai';
```

并把 `compute_baseline()` 的“今天+1”改成北京时间：

```sql
((NOW() AT TIME ZONE 'Asia/Shanghai')::DATE + 1)
```

#### 4. 周任务与回溯任务也改成北京时间窗口

- `run_weekly_score_update()`：本周一与“本周是否练过”判断改为北京时间窗口
- `backfill_score_history()`：每一周的起止时间改为北京时间窗口

这样历史回溯与实时榜单终于使用同一套周边界定义。

### FIX-76 后的最终规则

| 项目 | 最终口径 |
|------|---------|
| 综合分 | `composite_score = ROUND(raw_score × 100, 1)` |
| 本周有效练琴 | **仅工作日（周一至周五）** |
| 近10条榜单统计 | **仅工作日记录** |
| 每周时间边界 | **统一北京时间 `Asia/Shanghai`** |
| 周五任务顺序 | `21:30` 备份 → `21:32` 发币 → `21:35` 周快照 |

### 最终部署顺序（以 FIX-76 为准）

1. 运行 `fix76_beijing_boundary_and_weekend_alignment.sql`
2. 运行 `setup_weekly_score_cron.sql`
3. 运行：

```sql
SELECT public.backfill_score_history();
```

### 当前最终推荐

从现在开始，**不要再单独按旧顺序手工拼 `fix74` + `fix75` 了**。  
如果数据库还没部署最新版，直接以：

- `fix76_beijing_boundary_and_weekend_alignment.sql`
- `setup_weekly_score_cron.sql`

作为最终部署入口即可。
