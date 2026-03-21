# piano-room-system（琴房 / 练琴数据与排行榜）

## 排行榜文案与规则（学生端）

- **`menuhin-school-system/index.html`**：与后端 `get_weekly_leaderboards()`、`compute_student_score` 同步的**排行榜 Tips + 第二页指南摘要**（弹窗可复制区块）。
- **`排行榜指南.html`**：可打印的完整指南（含第一章音符币表、第二章综合分说明、第三章冲榜提示）。
- **`leaderboard_rpc.sql`**：四榜逻辑源码（综合 / 进步 / 稳定 / 守则）。

若修改规则，请**同时更新**以上三处及 `fix44_46_score_functions.sql`（权重）等对应 SQL。

快捷入口：根目录 **`menuhin-school-system-index.html`** 会跳转到 `menuhin-school-system/index.html`。

---

## 当前排行榜核心口径（2026-03-21）

- **综合分**：`composite_score = ROUND(raw_score × 100, 1)`，已取消百分位归一化。
- **周末不计榜**：周六、周日练琴不计入当前周排行榜资格与近10条榜单统计。
- **北京时间边界**：所有周切换、快照、回溯统一按 `Asia/Shanghai` 处理。
- **周五任务顺序**：
  - `21:30` 备份排行榜
  - `21:32` 结算音符币
  - `21:35` 刷新周快照

## 最新部署文件

- **`fix74_remove_percentile.sql`**：删除百分位归一化，分数改为纯绝对分。
- **`fix75_weekly_snapshot_fix.sql`**：修复周快照逻辑，不再覆盖实时榜单分数。
- **`fix76_beijing_boundary_and_weekend_alignment.sql`**：修复北京时间边界，并统一“周末不计榜”。
- **`setup_weekly_score_cron.sql`**：注册 `weekly_score_update_job`（周五 21:35）。

## 推荐部署顺序

1. 运行 `fix76_beijing_boundary_and_weekend_alignment.sql`
2. 运行 `setup_weekly_score_cron.sql`
3. 运行 `SELECT public.backfill_score_history();`

详细架构见 **`系统架构文档.md`** 和 **`baseline_monitoring_backup.md`**。
