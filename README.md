# piano-room-system（琴房 / 练琴数据与排行榜）

## 排行榜文案与规则（学生端）

- **`menuhin-school-system/index.html`**：与后端 `get_weekly_leaderboards()`、`compute_student_score` 同步的**排行榜 Tips + 第二页指南摘要**（弹窗可复制区块）。
- **`排行榜指南.html`**：可打印的完整指南（含第一章音符币表、第二章综合分说明、第三章冲榜提示）。
- **`leaderboard_rpc.sql`**：四榜逻辑源码（综合 / 进步 / 稳定 / 守则）。

若修改规则，请**同时更新**以上三处及 `fix44_46_score_functions.sql`（权重）等对应 SQL。

快捷入口：根目录 **`menuhin-school-system-index.html`** 会跳转到 `menuhin-school-system/index.html`。

---

详细架构见 **`系统架构文档.md`**。
