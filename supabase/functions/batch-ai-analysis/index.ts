/**
 * batch-ai-analysis — 工作日批量生成学生 AI 练琴分析
 *
 * 触发方式：pg_cron 定时调用（建议仅工作日）/ 或手动 HTTP POST 触发
 *
 * 分批调用方式（按综合榜从高到低分页，而不是按姓名）：
 *   { offset: 0,   limit: 50 }   → 综合榜前 1～50 名
 *   { offset: 50,  limit: 50 }   → 综合榜第 51～100 名
 *   { offset: 100, limit: 50 }   → 综合榜第 101～150 名
 *   不传 offset/limit → 默认 offset=0, limit=MAX_STUDENTS_PER_CALL
 *
 * 单学生模式（前端点击"重新生成"时使用）：
 *   { student_name: "张三" }
 *
 * 筛选逻辑（只更新真正需要的学生）：
 *   ① 从未生成过 AI 分析                            → 生成
 *   ② 上次分析之后有新练琴记录（practice_sessions）  → 生成
 *   ③ 上次分析之后无新练琴记录                       → 跳过
 *
 * 环境变量（在 Supabase Dashboard > Edge Functions > Secrets 中配置）：
 *   SUPABASE_URL                 — 项目 URL（自动注入，无需手动设置）
 *   SUPABASE_SERVICE_ROLE_KEY    — service_role 密钥（需手动添加）
 *   BATCH_AI_SECRET              — 调用本函数时需携带的密钥（防止外部随意触发）
 *   DEEPSEEK_API_KEY             — DeepSeek 官方 API Key（必填）
 *   DEEPSEEK_MODEL               — 官方模型名；默认 deepseek-v4-flash，可切 deepseek-v4-pro
 *   DEEPSEEK_BASE_URL            — 官方兼容接口根地址；默认 https://api.deepseek.com
 *   DEEPSEEK_THINKING_TYPE       — thinking.type；默认 disabled，可切 enabled
 *   DEEPSEEK_REASONING_EFFORT    — 开启 thinking 后可选：low / medium / high
 */

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BATCH_SECRET_RAW      = Deno.env.get("BATCH_AI_SECRET") ?? "";
const BATCH_SECRET          = BATCH_SECRET_RAW.trim();
const DEEPSEEK_API_BASE_URL = (Deno.env.get("DEEPSEEK_BASE_URL") ?? "https://api.deepseek.com").trim().replace(/\/+$/, "");
const DEEPSEEK_API_KEY      = (Deno.env.get("DEEPSEEK_API_KEY") ?? "").trim();
const DEEPSEEK_MODEL        = (Deno.env.get("DEEPSEEK_MODEL") ?? "deepseek-v4-flash").trim();
const DEEPSEEK_THINKING_TYPE= (Deno.env.get("DEEPSEEK_THINKING_TYPE") ?? "disabled").trim().toLowerCase();
const DEEPSEEK_REASONING_EFFORT = (Deno.env.get("DEEPSEEK_REASONING_EFFORT") ?? "").trim().toLowerCase();
const DELAY_MS              = 200;   // 每个并发批次结束后的等待时间（毫秒）
const CONCURRENCY           = 8;    // 每批并发处理学生数（同时发起 AI 请求）
// 免费套餐超时上限 150s，50人×8并发≈7批×10s=70s，留足余量
const MAX_STUDENTS_PER_CALL = 50;   // 单次调用最多处理学生数（不传 limit 时的默认值）

// 强制刷新时间点：在此时间之前生成的 AI 分析，无论是否有新数据，都强制重新生成
// 用于在代码逻辑更新后清洗旧分析
// 2026-03-20：同步 FIX-56 (M达标线100%) 与最新排行榜规则
const FORCE_REFRESH_BEFORE = "2026-03-20T12:00:00.000Z";

// ─── 课表解析工具（student_schedules.cells）────────────────────────────────

interface ScheduleSlot {
  startMin: number; // 分钟数，如 08:00 = 480
  endMin:   number;
  duration: number;
  label:    string; // text 第一行
  major:    boolean;
}
interface DaySchedule {
  classes:       ScheduleSlot[]; // 上课时间（practice=false, rest=false）
  practiceSlots: ScheduleSlot[]; // 排课练琴时段（practice=true）
  restSlots:     ScheduleSlot[]; // 午休/间点（rest=true）
}

/** 解析 cells JSONB → 按星期分组的课表结构（day 0=周一…4=周五） */
function parseScheduleCells(cells: Record<string, any>): {
  daySchedule: Record<number, DaySchedule>;
  weeklyScheduledMinutes: number;   // 课表安排的每周练琴总分钟
  practiceDaysCount: number;         // 每周有排课练琴的天数
} {
  const daySchedule: Record<number, DaySchedule> = {};
  let weeklyScheduledMinutes = 0;
  const practiceDaySet = new Set<number>();

  for (const cell of Object.values(cells)) {
    const day: number = cell.day;
    if (day < 0 || day > 4) continue;
    if (!daySchedule[day]) daySchedule[day] = { classes: [], practiceSlots: [], restSlots: [] };

    const parts = (cell.time as string).split("-");
    const [sh, sm] = parts[0].split(":").map(Number);
    const [eh, em] = parts[1].split(":").map(Number);
    const startMin = sh * 60 + sm;
    const endMin   = eh * 60 + em;
    const duration = endMin - startMin;
    const label    = (cell.text as string).split("\n")[0].trim();

    if (cell.rest) {
      daySchedule[day].restSlots.push({ startMin, endMin, duration, label, major: false });
    } else if (cell.practice) {
      daySchedule[day].practiceSlots.push({ startMin, endMin, duration, label, major: false });
      weeklyScheduledMinutes += duration;
      practiceDaySet.add(day);
    } else {
      daySchedule[day].classes.push({ startMin, endMin, duration, label, major: !!cell.majorCourse });
    }
  }
  return { daySchedule, weeklyScheduledMinutes, practiceDaysCount: practiceDaySet.size };
}

const DOW_CN = ["周日","周一","周二","周三","周四","周五","周六"];

/**
 * 检测某次练琴是否与课表中的上课时间冲突（返回冲突课程名列表）
 * sessionStartBJT/sessionEndBJT 均为已转换成北京时间的 Date（getUTCHours() = BJT小时）
 */
function findClassConflicts(
  sessionStartBJT: Date,
  sessionEndBJT:   Date,
  daySchedule: Record<number, DaySchedule>
): string[] {
  const dow = sessionStartBJT.getUTCDay(); // 0=Sun…6=Sat
  if (dow === 0 || dow === 6) return [];   // 周末
  const dayIdx = dow - 1;                  // 0=Mon…4=Fri

  const sStart = sessionStartBJT.getUTCHours() * 60 + sessionStartBJT.getUTCMinutes();
  const sEnd   = sessionEndBJT.getUTCHours()   * 60 + sessionEndBJT.getUTCMinutes();

  return (daySchedule[dayIdx]?.classes ?? [])
    .filter(cls => sStart < cls.endMin && sEnd > cls.startMin)
    .map(cls => cls.label);
}

/** 生成课表摘要文本（供 AI 阅读） */
function formatScheduleSummary(daySchedule: Record<number, DaySchedule>, weeklyMinutes: number): string {
  const dayNames = ["周一","周二","周三","周四","周五"];
  const lines: string[] = [`每周课表安排练琴合计约 ${weeklyMinutes} 分钟：`];
  for (let d = 0; d < 5; d++) {
    const ds = daySchedule[d];
    if (!ds) { lines.push(`  ${dayNames[d]}：无排课数据`); continue; }
    const pSlots = ds.practiceSlots.map(s =>
      `${String(Math.floor(s.startMin/60)).padStart(2,"0")}:${String(s.startMin%60).padStart(2,"0")}-` +
      `${String(Math.floor(s.endMin/60)).padStart(2,"0")}:${String(s.endMin%60).padStart(2,"0")}练琴`
    );
    const cSlots = ds.classes
      .filter(c => c.major)
      .map(c => `${String(Math.floor(c.startMin/60)).padStart(2,"0")}:${String(c.startMin%60).padStart(2,"0")} ${c.label}★主修`);
    const all = [...pSlots, ...cSlots].join("、") || "无排课练琴";
    lines.push(`  ${dayNames[d]}：${all}`);
  }
  return lines.join("\n");
}

// ─── 工具函数 ───────────────────────────────────────────────────────────────

/** 带 service_role 权限的 Supabase REST 查询 */
async function dbGet(path: string): Promise<any[]> {
  // 使用 Cache-Control 头禁用缓存，而不是修改 URL
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
      "Cache-Control": "no-cache, no-store, must-revalidate",
      "Pragma": "no-cache",
      "Expires": "0"
    },
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`DB GET ${path} → ${res.status}: ${text.slice(0, 200)}`);
  }
  return res.json();
}

/** 调用 Supabase RPC 函数 */
async function dbRpc(fnName: string, params: object = {}): Promise<any[]> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fnName}`, {
    method: "POST",
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(params),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`DB RPC ${fnName} → ${res.status}: ${text.slice(0, 200)}`);
  }
  return res.json();
}

/** 带 service_role 权限的 Supabase REST upsert */
async function dbUpsert(table: string, body: object): Promise<void> {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/${table}?on_conflict=student_name`,
    {
      method: "POST",
      headers: {
        apikey: SERVICE_KEY,
        Authorization: `Bearer ${SERVICE_KEY}`,
        "Content-Type": "application/json",
        Prefer: "resolution=merge-duplicates",
      },
      body: JSON.stringify(body),
    }
  );
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`DB UPSERT ${table} → ${res.status}: ${text.slice(0, 200)}`);
  }
}

/** 调用 DeepSeek 官方 OpenAI 兼容接口 */
async function callAI(systemPrompt: string, userPrompt: string): Promise<{ text: string; source: string }> {
  if (!DEEPSEEK_API_KEY) {
    throw new Error("缺少 DEEPSEEK_API_KEY，无法调用 DeepSeek 官方接口");
  }

  const thinkingEnabled = DEEPSEEK_THINKING_TYPE === "enabled";
  const body: Record<string, unknown> = {
    model: DEEPSEEK_MODEL,
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user", content: userPrompt },
    ],
    temperature: 0.70,
    max_tokens: 520,
    stream: false,
    thinking: { type: thinkingEnabled ? "enabled" : "disabled" },
  };

  if (thinkingEnabled && DEEPSEEK_REASONING_EFFORT) {
    body.reasoning_effort = DEEPSEEK_REASONING_EFFORT;
  }

  const res = await fetch(`${DEEPSEEK_API_BASE_URL}/chat/completions`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${DEEPSEEK_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const t = await res.text();
    throw new Error(`AI调用失败 (${res.status}): ${t.slice(0, 120)}`);
  }
  const data = await res.json();
  if (data.error) throw new Error(data.error);
  const text = (data.choices?.[0]?.message?.content ?? "").trim();
  return { text: text || "生成失败", source: "deepseek" };
}

/** 休眠 ms 毫秒 */
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ─── 练琴会话结构（直接来自 practice_sessions 表）────────────────────────────

interface Session {
  session_start: string;
  session_end: string;
  raw_duration: number;
  cleaned_duration: number;
  room_name?: string;
  is_outlier: boolean;
  outlier_reason?: string;  // FIX-30: too_long / meal_break / personal_outlier / too_short / capped_120 / null
}


// ─── Prompt 构建（对应 dashboard.html 的 buildAnalysisPrompt）────────────────

const WD_CN = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

const CN_HOLIDAYS = [
  { name: "元旦假期",    range: "12月31日 ~ 1月3日前后" },
  { name: "寒假+春节",   range: "1月中旬 ~ 2月下旬（通常4~6周）" },
  { name: "清明节",      range: "4月4日前后3天" },
  { name: "劳动节",      range: "5月1日前后5天" },
  { name: "端午节",      range: "5月底/6月初前后3天" },
  { name: "暑假",        range: "7月初 ~ 8月底（通常6~8周）" },
  { name: "中秋节",      range: "9月中旬前后3天" },
  { name: "国庆节",      range: "10月1日~7日" },
];

// ─── 北京时间工具（UTC+8）───────────────────────────────────────────────────
const BJT_OFFSET_MS = 8 * 60 * 60 * 1000;

/** 将任意时间戳/ISO 字符串转为北京时间 Date 对象 */
function toBJT(input: Date | string | number): Date {
  const ms = input instanceof Date ? input.getTime()
    : typeof input === "string" ? new Date(input).getTime()
    : input;
  return new Date(ms + BJT_OFFSET_MS);
}

/** 返回北京时间本周一日期字符串，格式 YYYY-MM-DD */
function getWeekMonday(): string {
  const d = toBJT(Date.now());
  const day = d.getUTCDay();               // 用 UTC 方法读北京时间对象的字段
  const diff = day === 0 ? -6 : 1 - day;
  d.setUTCDate(d.getUTCDate() + diff);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-${String(d.getUTCDate()).padStart(2, "0")}`;
}


/** 将分钟数格式化为易读时长字符串：≥60分钟显示 X小时XX分钟，否则直接显示X分钟 */
function fmtMin(min: number): string {
  const m = Math.round(min);
  if (m < 60) return `${m}分钟`;
  const h = Math.floor(m / 60);
  const r = m % 60;
  return r > 0 ? `${h}小时${r}分钟` : `${h}小时`;
}

function buildPrompt(student: any, hist: any[], sessions: Session[]): string {
  // ── 基础变量 ────────────────────────────────────────────────────────────────
  const noPracticeNow  = !!student.has_week_snapshot; // true = 本周无练琴
  const todayDOW       = toBJT(Date.now()).getUTCDay();
  const isMondayNoData = noPracticeNow && todayDOW === 1;
  const weekMondayStr  = getWeekMonday();

  const composite  = student.composite_score ?? 0;
  const bScore     = Number(student.baseline_score || 0);
  const tScore     = Number(student.trend_score    || 0);
  const mScore     = Number(student.momentum_score || 0);
  const aScore     = Number(student.accum_score    || 0);
  const outlierRate= Number(student.outlier_rate   || 0);
  const meanDur    = Number(student.mean_duration  || 0);
  const isCold     = !!student.is_cold_start;
  const recCnt     = student.record_count ?? 0;

  // ── 维度贡献拆解（按当前公式权重，帮助 AI 解释“为什么是这个分”）──────────────
  // 当前口径：raw = B*22% + T*22% + M*15% + A*11% + W*30%
  const DIM_WEIGHTS = {
    B: 0.22,
    T: 0.22,
    M: 0.15,
    A: 0.11,
    W: 0.30,
  };

  // ── 分数水平文字 ─────────────────────────────────────────────────────────────
  const scoreLevel =
    composite >= 80 ? "非常优秀，处于全校前列"
    : composite >= 65 ? "中等偏上，在全校处于较好位置"
    : composite >= 50 ? "中等水平"
    : composite >= 35 ? "中等偏下，有比较大的提升空间"
    : composite > 0   ? "目前偏低，需要关注"
    : "本周暂无练琴，未参与本周排名";

  // ── 本周实际练琴汇总 ──────────────────────────────────────────────────────────
  const weekMondayMs = new Date(weekMondayStr + "T00:00:00+08:00").getTime();
  const thisWeekSess = sessions.filter((s) => {
    const t   = new Date(s.session_start).getTime();
    const dow = toBJT(s.session_start).getUTCDay();
    return t >= weekMondayMs && dow !== 0 && dow !== 6;
  });
  const thisWeekValidMin = thisWeekSess
    .filter((s) => !s.is_outlier)
    .reduce((sum, s) => sum + (s.cleaned_duration || 0), 0);
  const thisWeekAbnormal = thisWeekSess.filter((s) => s.is_outlier).length;

  const thisWeekSummary = thisWeekSess.length === 0
    ? isMondayNoData
      ? "今天是本周一，本周还没有练琴记录（完全正常）"
      : "本周目前没有练琴记录"
    : `本周已练 ${thisWeekSess.length} 次，有效计分时间约 ${fmtMin(thisWeekValidMin)}` +
      (thisWeekAbnormal > 0 ? `（其中 ${thisWeekAbnormal} 次有异常标记）` : "");

  // ── 各维度白话解释 ────────────────────────────────────────────────────────────
  // W：本周练琴量与个人日均水平对比（通过实际 session 数据计算，无需 w_score 字段）
  // 个人周目标 = 日均 × 5个工作日；wRatio = 本周有效分钟 / 周目标
  const weeklyTarget = meanDur * 5;
  const wRatio = (weeklyTarget > 0 && !noPracticeNow)
    ? thisWeekValidMin / weeklyTarget
    : -1; // -1 = 本周无练琴或无历史基准

  const wText = wRatio < 0
    ? (noPracticeNow ? "本周没有练琴记录" : "暂无历史日均数据，无法对比本周练琴量")
    : wRatio > 1.2
      ? `本周有效练琴时间约 ${fmtMin(thisWeekValidMin)}，明显超出了你的日常水平（日均约 ${fmtMin(meanDur)}），是这次得分的最大加分项`
    : wRatio > 0.85
      ? `本周有效练琴时间约 ${fmtMin(thisWeekValidMin)}，与你平时的日常水平差不多（日均约 ${fmtMin(meanDur)}）`
    : wRatio > 0.55
      ? `本周有效练琴时间约 ${fmtMin(thisWeekValidMin)}，比你平时少一些（日均约 ${fmtMin(meanDur)}），小幅拖低了分数`
    : `本周有效练琴时间约 ${fmtMin(thisWeekValidMin)}，明显少于你平时的水平（日均约 ${fmtMin(meanDur)}），是分数偏低的主要原因之一`;

  const wScoreForExplain = wRatio < 0
    ? 0
    : wRatio >= 1
      ? 1
      : 1 / (1 + Math.exp(-3 * (wRatio - 0.5))); // 与评分口径一致的 W 近似解释值

  const dimRows = [
    { key: "B", name: "短期进步(B)", score: bScore, weight: DIM_WEIGHTS.B },
    { key: "T", name: "近期趋势(T)", score: tScore, weight: DIM_WEIGHTS.T },
    { key: "M", name: "稳定达标(M)", score: mScore, weight: DIM_WEIGHTS.M },
    { key: "A", name: "长期积累(A)", score: aScore, weight: DIM_WEIGHTS.A },
    { key: "W", name: "本周练琴量(W)", score: wScoreForExplain, weight: DIM_WEIGHTS.W },
  ].map((d) => ({
    ...d,
    contribution: d.score * d.weight,          // 对 raw_score 的贡献
    missing: (1 - d.score) * d.weight,         // 距离该维度满分的缺口
  }));

  const strongestDims = [...dimRows]
    .sort((x, y) => y.contribution - x.contribution)
    .slice(0, 2);
  const weakestDims = [...dimRows]
    .sort((x, y) => y.missing - x.missing)
    .slice(0, 2);

  // B：短期进步（上周 vs 前一周）
  const bText =
    isCold         ? "历史数据还不够，暂时无法比较你最近两周之间的进步情况"
    : bScore > 0.60 ? "和上上周相比，上周你练琴的总时长有进步"
    : bScore < 0.40 ? "和上上周相比，上周你练琴的总时长有所减少"
    :                 "和上上周相比，上周练琴总时长基本持平";

  // T：中期趋势（近2周均值 vs 前2周均值）
  const tText =
    isCold         ? "历史周数还不够（需要至少 3 个有练琴的周），练琴趋势暂时无法评估"
    : tScore > 0.62 ? "近两周练琴量明显比之前更多，整体趋势在上升"
    : tScore < 0.38 ? "近两周练琴量比之前少了，整体趋势在下滑"
    :                 "近期练琴量与之前基本持平，趋势稳定";

  // M：稳定性（最近4周加权达标率，达标线 = 日均 × 5天 × 100%）
  const mText =
    isCold         ? "数据还太少，练琴稳定性暂时无法判断"
    : mScore > 0.62 ? "最近几周练琴很规律，大多数周都完成了目标练琴量"
    : mScore < 0.38 ? "最近几周练琴不太稳定，有几周完成目标的情况偏少"
    :                 "最近几周练琴稳定性一般，时多时少";

  // A：同专业横向积累
  const aText =
    isCold         ? "数据不足，同专业横向积累暂时无法评估"
    : aScore > 0.50 ? "与同专业同学相比，你的长期练琴积累在中等以上"
    : aScore > 0.20 ? "与同专业同学相比，长期积累处于中等水平"
    :                 "与同专业同学相比，长期积累偏弱，需要更持续地练琴来追赶";

  // ── 分数主要驱动因素（帮 AI 聚焦写作重点）────────────────────────────────────
  const topHelpers: string[] = [];
  const topHurters: string[] = [];

  if (wRatio > 1.2)  topHelpers.push(`本周练琴量超出日常水平（${fmtMin(thisWeekValidMin)} vs 日均约 ${fmtMin(meanDur)}/天，最强加分项）`);
  if (bScore > 0.60) topHelpers.push("最近比上上周有进步");
  if (tScore > 0.62) topHelpers.push("近期练琴量呈上升趋势");
  if (mScore > 0.62) topHelpers.push("最近练琴节奏规律稳定");
  if (aScore > 0.55 && !isCold) topHelpers.push("同专业长期积累良好");

  if (outlierRate > 0.25) topHurters.push(`异常记录偏多（${(outlierRate * 100).toFixed(0)}%），这些记录在拖低分数`);
  if (isCold)             topHurters.push(`练琴记录还少（仅 ${recCnt} 条），进步/趋势/稳定性等对比指标还不准确`);
  if (wRatio > 0 && wRatio < 0.55 && !noPracticeNow) topHurters.push(`本周练琴时间（${fmtMin(thisWeekValidMin)}）明显少于日常水平`);
  if (tScore < 0.38)      topHurters.push("近期练琴量比之前有所下滑");
  if (mScore < 0.38)      topHurters.push("最近练琴不够规律，有几周没有按时完成目标");
  if (aScore < 0.20 && !isCold) topHurters.push("同专业长期积累偏弱");

  // ── 针对短板维度的“立刻可执行”建议（避免只盯异常）────────────────────────────
  const actions: string[] = [];
  if (!noPracticeNow && wRatio >= 0 && wRatio < 0.85 && weeklyTarget > 0) {
    actions.push(`W维度（本周量）优先：本周还差约 ${fmtMin(Math.max(weeklyTarget - thisWeekValidMin, 0))} 才到个人周目标，建议把缺口分摊到接下来工作日每天补 ${fmtMin(Math.max((weeklyTarget - thisWeekValidMin) / 3, 20))}`);
  }
  if (!isCold && mScore < 0.45) {
    actions.push("M维度（稳定达标）优先：连续 2 周做到“工作日至少 4 天有练琴、每次不少于 45 分钟”，先把不规律问题拉回稳定区");
  }
  if (!isCold && tScore < 0.45) {
    actions.push("T维度（趋势）优先：未来 2 周的周总时长要比前 2 周至少提高约 15%，哪怕每天多 20~30 分钟也能明显改善趋势分");
  }
  if (!isCold && bScore < 0.45) {
    actions.push("B维度（短期进步）优先：下一周总时长至少比本周多 1~2 次完整练琴（约 +90~120 分钟），让“本周对比上周”出现明确上升");
  }
  if (!isCold && aScore < 0.30) {
    actions.push("A维度（长期积累）优先：用 4 周为周期稳步加量，目标是每周都达成个人周目标的 100%，长期分才会持续爬升");
  }
  if (outlierRate > 0.20) {
    actions.push("异常管理：每次结束后 1 分钟内还卡，优先消除超长未还卡/饭点占用，先止住异常扣分再谈冲榜效率");
  }
  if (actions.length === 0) {
    actions.push("当前维度结构较均衡：保持工作日稳定练琴频率，优先把最强维度继续放大，同时避免异常记录反弹");
  }

  // ── 异常练琴白话说明 ──────────────────────────────────────────────────────────
  const recent30      = sessions.slice(0, 30);
  const tooLongSess   = recent30.filter((s) => s.outlier_reason === "too_long");
  const mealBreakSess = recent30.filter((s) => s.outlier_reason === "meal_break");
  const otherOutliers = recent30.filter(
    (s) => s.is_outlier && s.outlier_reason !== "too_long" && s.outlier_reason !== "meal_break"
  );
  const totalAbnormal = recent30.filter((s) => s.is_outlier).length;

  // FIX-40 惩罚系数
  const penalty = outlierRate <= 0.60
    ? 1.0 - 0.4 * outlierRate
    : 0.76 * Math.exp(-3.0 * (outlierRate - 0.60));
  const penaltyPct = Math.round(penalty * 100);

  let outlierSection = "";
  if (totalAbnormal === 0) {
    outlierSection = `最近 ${recent30.length} 次练琴记录全部正常，没有异常扣分。`;
  } else {
    const parts: string[] = [];
    if (tooLongSess.length > 0)
      parts.push(`${tooLongSess.length} 次练琴时间超过 3 小时——系统判断很可能是练完了没及时还卡`);
    if (mealBreakSess.length > 0)
      parts.push(`${mealBreakSess.length} 次在午饭时间（约 12:10）或晚饭时间（约 18:10）仍在使用琴房`);
    if (otherOutliers.length > 0)
      parts.push(`${otherOutliers.length} 次其他异常`);
    outlierSection =
      `最近 ${recent30.length} 次记录中有 ${totalAbnormal} 次被标记为异常（异常率 ${(outlierRate * 100).toFixed(0)}%）。` +
      `这些异常让分数打了约 ${penaltyPct}% 的折扣。具体情况：${parts.join("；")}。`;
  }

  // ── 超长练琴明细（FIX-50 峰值时刻检测）────────────────────────────────────────
  const longSess = recent30.filter((r) => (r.raw_duration || 0) > 120);
  const longSessDetails = longSess.length > 0
    ? longSess.map((r) => {
        const d   = toBJT(r.session_start);
        const e   = toBJT(r.session_end);
        const date = `${d.getUTCMonth() + 1}月${d.getUTCDate()}日`;
        const wd   = WD_CN[d.getUTCDay()];
        const sh  = `${String(d.getUTCHours()).padStart(2, "0")}:${String(d.getUTCMinutes()).padStart(2, "0")}`;
        const eh  = `${String(e.getUTCHours()).padStart(2, "0")}:${String(e.getUTCMinutes()).padStart(2, "0")}`;
        const rawDur  = Math.round(r.raw_duration || 0);
        const h = Math.floor(rawDur / 60), m = rawDur % 60;
        const durStr  = h > 0 ? `${h}小时${m}分钟` : `${rawDur}分钟`;

        // FIX-50：峰值时刻检测（12:10 午饭 / 18:10 晚饭，周三不判晚饭）
        const startMin = d.getUTCHours() * 60 + d.getUTCMinutes();
        const endMin   = startMin + rawDur;
        const dowV     = d.getUTCDay();
        const lunchCross  = startMin < 730  && endMin > 730;            // 12:10
        const dinnerCross = dowV !== 3 && startMin < 1090 && endMin > 1090; // 18:10，周三除外
        const crossNote = lunchCross  ? "（午饭时间仍在占用琴房，可能是忘了还卡）"
                        : dinnerCross ? "（晚饭时间仍在占用琴房，可能是忘了还卡）"
                        : "";
        return `  ${date}(${wd}) ${sh}-${eh} 实际${durStr}${crossNote}`;
      }).join("\n")
    : "  无";

  const longTimeNote = longSess.length > 0
    ? `\n【超长练琴明细（共 ${longSess.length} 次，请在分析中引用具体日期和时长）】\n${longSessDetails}`
    : "";

  // ── 历史周快照（从旧到新）────────────────────────────────────────────────────
  const recent = [...hist].filter((h) => h.composite_score != null).reverse().slice(0, 10);
  const absentWeeks = recent.filter((h) => h.composite_score === 0).length;
  const activeWeeks = recent.filter((h) => h.composite_score > 0).length;

  const histRows = recent.length
    ? recent.map((h) => {
        const snap = String(h.snapshot_date).slice(0, 10);
        if (snap === weekMondayStr && !noPracticeNow && h.composite_score === 0)
          return `  ${snap}  ▸ 本周已有练琴记录，分数下周一结算（当前零分请忽略）`;
        if (h.composite_score === 0)
          return `  ${snap}  ▸ 本周未练琴`;
        const prog =
          (h.baseline_score ?? 0.5) > 0.58 ? "比上上周进步"
          : (h.baseline_score ?? 0.5) < 0.42 ? "比上上周回落"
          : "与上上周持平";
        return `  ${snap}  综合分=${h.composite_score}  均练时长=${Number(h.mean_duration || 0).toFixed(0)}分钟  异常率=${h.outlier_rate != null ? (Number(h.outlier_rate) * 100).toFixed(0) + "%" : "-"}  ${prog}`;
      }).join("\n")
    : "  暂无历史快照";

  // ── 近30次练琴记录列表 ────────────────────────────────────────────────────────
  const sessRows = sessions
    .map((r) => {
      const d   = toBJT(r.session_start);
      const e   = toBJT(r.session_end);
      const date = `${String(d.getUTCMonth() + 1).padStart(2, "0")}/${String(d.getUTCDate()).padStart(2, "0")}`;
      const wd   = WD_CN[d.getUTCDay()];
      const sh  = `${String(d.getUTCHours()).padStart(2, "0")}:${String(d.getUTCMinutes()).padStart(2, "0")}`;
      const eh  = `${String(e.getUTCHours()).padStart(2, "0")}:${String(e.getUTCMinutes()).padStart(2, "0")}`;
      const rawDur   = Math.round(r.raw_duration || 0);
      const cleanDur = Math.round(r.cleaned_duration || 0);
      const capNote  = rawDur !== cleanDur ? `（计分${cleanDur}分钟）` : "";
      const hh = Math.floor(rawDur / 60), mm = rawDur % 60;
      const durStr = hh > 0 ? `${hh}小时${mm}分钟` : `${rawDur}分钟`;
      let flag = "";
      if (r.is_outlier) {
        if      (r.outlier_reason === "meal_break")        flag = "  ⚠ 饭点时间占用";
        else if (r.outlier_reason === "too_long")          flag = "  ⚠ 超长/可能忘还卡";
        else if (r.outlier_reason === "personal_outlier")  flag = "  ⚠ 个人离群值";
        else                                               flag = "  ⚠ 异常";
      }
      const room = r.room_name ? `  ${r.room_name}` : "";
      return `  ${date} ${wd}  ${sh}-${eh}  ${durStr}${capNote}${room}${flag}`;
    })
    .join("\n") || "  暂无记录";

  // ── 星期分布 ─────────────────────────────────────────────────────────────────
  const wdCount = [0, 0, 0, 0, 0, 0, 0];
  sessions.forEach((r) => wdCount[toBJT(r.session_start).getUTCDay()]++);
  const wdSummary = WD_CN.map((w, i) => `${w}:${wdCount[i]}次`).join("  ");

  // ── 短时练琴统计 ──────────────────────────────────────────────────────────────
  const totalSess  = sessions.length;
  const shortCnt   = sessions.filter((r) => (r.raw_duration || 0) < 30).length;
  const shortPct   = totalSess ? Math.round((shortCnt / totalSess) * 100) : 0;

  // ── 冷启动说明 ────────────────────────────────────────────────────────────────
  const coldText = isCold
    ? `⚠ 你目前只有 ${recCnt} 次有效练琴记录，数据还比较少。进步/趋势/稳定性等依赖历史对比的指标暂时无法准确评估，会显示为中间默认值。随着你练琴次数增加，分数会越来越准确地反映你的真实水平。`
    : `数据充足（${recCnt} 条有效记录），以下分析结论可信。`;

  // ── 今天日期 ──────────────────────────────────────────────────────────────────
  const todayBJT    = toBJT(Date.now());
  const wdNames     = ["星期日","星期一","星期二","星期三","星期四","星期五","星期六"];
  const today       = `${todayBJT.getUTCFullYear()}年${todayBJT.getUTCMonth()+1}月${todayBJT.getUTCDate()}日 ${wdNames[todayBJT.getUTCDay()]}`;

  // ── 最近一次练琴 ──────────────────────────────────────────────────────────────
  const lastSess = sessions[0];
  const lastSessDate = lastSess
    ? (() => {
        const d = toBJT(lastSess.session_start);
        return `${d.getUTCFullYear()}-${String(d.getUTCMonth()+1).padStart(2,"0")}-${String(d.getUTCDate()).padStart(2,"0")} ${WD_CN[d.getUTCDay()]}`;
      })()
    : "无记录";

  // 输出给 AI 的内容尽量短，但必须把五个维度的“原因+改法”喂清楚
  const topHelpTxt = topHelpers.length ? topHelpers.slice(0, 2).join("；") : "暂无明显加分项";
  const topHurtTxt = topHurters.length ? topHurters.slice(0, 2).join("；") : "暂无明显拖分项";
  const actionTxt  = actions.slice(0, 3).join("；");

  const strongestTxt = strongestDims.map(d => d.name).join("、") || "—";
  const weakestTxt   = weakestDims.map(d => d.name).join("、") || "—";

  const weaknessRankMap = new Map(
    [...dimRows]
      .sort((x, y) => y.missing - x.missing)
      .map((d, idx) => [d.key, idx + 1] as const)
  );
  const priorityLabel = (key: string) => {
    const rank = weaknessRankMap.get(key) ?? 5;
    if (rank <= 2) return "高";
    if (rank === 3) return "中";
    return "低";
  };

  const weekGapMin = Math.max(weeklyTarget - thisWeekValidMin, 0);
  const weekCatchupMin = Math.max(Math.round(weekGapMin / 3), 20);

  const dimensionFocusRows = [
    {
      key: "W",
      name: "本周练琴量",
      status: isMondayNoData
        ? "本周刚开始"
        : wRatio < 0
          ? "暂不评价"
          : wRatio < 0.55
            ? "偏低"
            : wRatio < 0.85
              ? "略低"
              : "正常或偏强",
      reason: isMondayNoData
        ? "今天是周一，本周还没开始，这项不要当成拖分原因。"
        : noPracticeNow
          ? "本周还没有工作日练琴记录，这项会直接偏低。"
          : weeklyTarget <= 0
            ? "历史日均样本不足，只能粗看这周总量。"
            : wRatio < 0.85
              ? `本周只完成个人周目标约 ${Math.round(wRatio * 100)}%（${fmtMin(thisWeekValidMin)} / ${fmtMin(weeklyTarget)}）。`
              : `本周已完成个人周目标约 ${Math.round(wRatio * 100)}%，当前不是主要拖分项。`,
      action: isMondayNoData
        ? (weeklyTarget > 0
            ? `本周先按平时节奏推进，目标至少 ${fmtMin(weeklyTarget)}。`
            : "本周先保持正常练琴节奏。")
        : noPracticeNow
          ? (weeklyTarget > 0
              ? `接下来工作日尽快补到 ${fmtMin(weeklyTarget)} 左右。`
              : "先补上 2 到 3 次完整练琴，把本周记录建立起来。")
          : weeklyTarget > 0 && wRatio < 0.85
            ? `剩余工作日优先补足约 ${fmtMin(weekGapMin)}，每天加练约 ${fmtMin(weekCatchupMin)}。`
            : "保持当前周量，同时避免异常记录吃掉有效时长。",
    },
    {
      key: "B",
      name: "短期进步",
      status: isCold ? "样本不足" : bScore < 0.45 ? "偏低" : bScore < 0.62 ? "一般" : "较好",
      reason: isCold
        ? "练琴记录还少，最近两周和前一周的对比暂时不稳定。"
        : bScore < 0.45
          ? "上周总时长比上上周少，最近一周没有形成明显进步。"
          : bScore < 0.62
            ? "上周和上上周差不多，进步幅度还不够清楚。"
            : "上周比上上周更好，这项当前不是主要短板。",
      action: isCold
        ? "先连续两周稳定练琴，再看这项变化。"
        : bScore < 0.62
          ? "下周比本周多安排 1 到 2 次完整练琴，周总时长至少多 90 到 120 分钟。"
          : "下周维持当前节奏，别让周总时长回落。",
    },
    {
      key: "T",
      name: "近期趋势",
      status: isCold ? "样本不足" : tScore < 0.45 ? "偏低" : tScore < 0.62 ? "一般" : "较好",
      reason: isCold
        ? "可比较的历史周数还不够，这项暂时看不准。"
        : tScore < 0.45
          ? "最近两周整体少于更早两周，练琴趋势在走弱。"
          : tScore < 0.62
            ? "最近两周和之前接近，趋势还没有明显抬头。"
            : "最近两周整体高于之前，这项当前不是主要拖分项。",
      action: isCold
        ? "先把每周练琴保持住，等连续几周后再看趋势。"
        : tScore < 0.62
          ? "未来 2 周每周总时长至少比前 2 周提高约 15%，哪怕每天多 20 到 30 分钟也有效。"
          : "继续把近两周的节奏延续下去，别只好一周。",
    },
    {
      key: "M",
      name: "稳定达标",
      status: isCold ? "样本不足" : mScore < 0.45 ? "偏低" : mScore < 0.62 ? "一般" : "较好",
      reason: isCold
        ? "数据还少，暂时不能稳定判断你是不是周周达标。"
        : mScore < 0.45
          ? "近几周忽高忽低，没有稳定完成个人周目标。"
          : mScore < 0.62
            ? "有些周能完成目标，有些周掉下来，规律性还不够。"
            : "最近几周达标比较稳定，这项当前不是主要拖分项。",
      action: isCold
        ? "先固定每周练琴节奏，让样本稳定下来。"
        : mScore < 0.62
          ? "连续 2 周做到工作日至少 4 天练琴、每次不少于 45 分钟。"
          : "继续守住固定练琴日，避免突然断档。",
    },
    {
      key: "A",
      name: "长期积累",
      status: isCold ? "样本不足" : aScore < 0.30 ? "偏低" : aScore < 0.50 ? "一般" : "较好",
      reason: isCold
        ? "有效记录还少，长期积累暂时看不准。"
        : aScore < 0.30
          ? "和同专业同学相比，累计练琴量还偏少，底子还没拉起来。"
          : aScore < 0.50
            ? "长期积累在中间位置，但还不够稳固。"
            : "长期积累已经不差，这项当前不是主要拖分项。",
      action: isCold
        ? "先把记录累起来，别急着看长期项。"
        : aScore < 0.50
          ? "用 4 周做一个周期，尽量每周都完成个人周目标的 100%，把总量慢慢垫高。"
          : "保持周周不断档，让长期积累继续往上长。",
    },
  ];

  const dimensionFocusTxt = dimensionFocusRows
    .map((row) =>
      `${row.name}｜优先级${priorityLabel(row.key)}｜状态${row.status}｜原因：${row.reason}｜改法：${row.action}`
    )
    .join("\n");

  // 异常明细（最多列出 4 条，避免超长）
  const longDetails = longSess.length
    ? longSessDetails.split("\n").slice(0, 4).join("\n")
    : "";

  return `
学生：${student.student_name}（${student.student_major || "专业未知"} ${student.student_grade || ""}）
今天：${today}

综合分：${composite > 0 ? composite + "/100" : "本周无练琴"}
结论：${scoreLevel}
数据：${isCold ? `偏少（${recCnt}条）` : `充足（${recCnt}条）`}

本周（${weekMondayStr}起）：${isMondayNoData ? "周一正常空窗（不要评价本周）" : (noPracticeNow ? "暂无练琴记录" : thisWeekSummary)}
最近一次练琴：${lastSessDate}

主要加分：${topHelpTxt}
主要拖分：${topHurtTxt}
最强项：${strongestTxt}
最短板：${weakestTxt}

五维拆解（请逐项回应，不要漏项）：
${dimensionFocusTxt}

异常摘要：${outlierSection}
${longDetails ? `异常明细（引用具体日期/时长）：\n${longDetails}` : ""}

补充建议候选：${actionTxt}
`.trim();
}

// ─── System Prompt ───────────────────────────────────────────────────────────

const SYSTEM_PROMPT = `你是一位亲切、诚实的练琴学习助理，帮助学生一眼看懂自己五个方面为什么高或低、接下来该怎么改。

【核心任务】
严格根据提供的“五维拆解”逐项输出，尤其要把偏低项目的原因和改法说准、说短，不要只挑 1 到 2 项来讲。

【语言风格】
- 直接对学生说话，用"你"
- 用真实数字（分钟/次数/比例）说话，不要空话
- 不要出现任何统计术语：α、β、σ、outlier、baseline、score、momentum、accum、维度、可信度
- 不要编造数据；没有数据就直接说“暂时看不准”
- 不要使用Markdown格式（不能有 *、#、**、- 开头的列表）

【输出格式】
严格输出 6 行纯文本，保留换行，不要写成一整段：
总评：一句话说清当前总分最核心的拖分点 + 一个真实亮点。
本周练琴量：现状；原因；改法。
短期进步：现状；原因；改法。
近期趋势：现状；原因；改法。
稳定达标：现状；原因；改法。
长期积累：现状；原因；改法。

【写作要求】
- 每一行尽量短，优先写“偏低/一般/较好”等结论，再写原因和改法
- 如果某项当前不是主要拖分项，也要交代一句“不是主要问题，继续保持什么”
- 重点更详细地写优先级高、状态偏低的项
- 总字数控制在 220～360 字

【周一规则】
若提示“今天是本周一，本周还没开始练琴”，不要评价本周，只基于历史数据说。

【异常说明】
如果给了“异常明细（引用具体日期/时长）”，只在相关那一行点出最关键的 1 条即可，不要单独展开成长列表。`;

// ─── 主处理逻辑 ──────────────────────────────────────────────────────────────

// 所有响应都必须带 CORS 头，否则从 file:// 打开的 HTML 会被浏览器拦截
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-batch-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

Deno.serve(async (req: Request) => {
  // OPTIONS 预检
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS_HEADERS });
  }

  // 解析请求体（需在鉴权之前，body 只能读一次）
  let body: Record<string, any> = {};
  try { body = await req.json(); } catch { /* 空 body 或非 JSON 均视为 {} */ }

  // 强制要求部署时配置口令，避免函数在漏配时处于裸奔状态
  if (!BATCH_SECRET) {
    return json({
      error: "Server misconfigured: BATCH_AI_SECRET is not set",
    }, 500);
  }

  // 密钥校验（防止外部随意触发）
  const incoming = (req.headers.get("x-batch-secret") ?? "").trim();
  if (incoming !== BATCH_SECRET) {
    return json({ error: "Unauthorized" }, 401);
  }

  // 周末自动批处理保护：
  // - 自动批量模式（无 student_name/diagnostic）在周六周日直接跳过
  // - 手动单学生/深度诊断不受限制
  // - 允许传入 force_run=true 显式覆盖（仅内部运维使用）
  const isWeekendBJT = (() => {
    const dow = toBJT(Date.now()).getUTCDay(); // BJT: 0=Sun ... 6=Sat
    return dow === 0 || dow === 6;
  })();
  const isManualMode = !!body.student_name || !!body.diagnostic;
  const forceRun = body.force_run === true;
  if (isWeekendBJT && !isManualMode && !forceRun) {
    return json({
      skipped: true,
      reason: "Weekend auto batch is disabled",
      bjt_day: DOW_CN[toBJT(Date.now()).getUTCDay()],
    });
  }

  const log: string[] = [];
  const errors: string[] = [];
  const startTime = Date.now();

  // ── 深度诊断模式（前端"深度诊断"按钮触发，不走缓存，拉60条session）──────
  const diagName: string | undefined = body.diagnostic ? body.student_name : undefined;
  if (diagName) {
    try {
      log.push(`深度诊断模式：${diagName}`);

      const [students, rawSessions, histRows, scheduleRows] = await Promise.all([
        dbGet(`student_baseline?student_name=eq.${encodeURIComponent(diagName)}&select=student_name,composite_score,raw_score,mean_duration,std_duration,alpha,outlier_rate,short_session_rate,record_count,is_cold_start,student_major,student_grade&limit=1`),
        dbGet(`practice_sessions?student_name=eq.${encodeURIComponent(diagName)}&select=session_start,session_end,raw_duration,cleaned_duration,is_outlier,outlier_reason,room_name&order=session_start.desc&limit=60`),
        dbGet(`student_score_history?student_name=eq.${encodeURIComponent(diagName)}&select=snapshot_date,composite_score,outlier_rate&order=snapshot_date.desc&limit=12`),
        dbGet(`student_schedules?name=eq.${encodeURIComponent(diagName)}&select=name,grade,cells&limit=1`).catch(() => []),
      ]);
      if (!students.length) return json({ error: `未找到学生：${diagName}`, log }, 404);
      const st = students[0];

      // ── 解析课表 ────────────────────────────────────────────────────
      const scheduleRow = scheduleRows[0] ?? null;
      const { daySchedule, weeklyScheduledMinutes, practiceDaysCount } = scheduleRow?.cells
        ? parseScheduleCells(scheduleRow.cells)
        : { daySchedule: {}, weeklyScheduledMinutes: 0, practiceDaysCount: 0 };
      const hasSchedule = !!scheduleRow;
      const scheduleSummary = hasSchedule
        ? formatScheduleSummary(daySchedule, weeklyScheduledMinutes)
        : "（该学生暂无课表数据）";

      // 检测练琴记录与上课时间的冲突（最近60条）
      interface ConflictRecord { date: string; dow: string; sessionTime: string; duration: number; conflicts: string[] }
      const conflictRecords: ConflictRecord[] = [];
      for (const r of rawSessions) {
        const sBJT = toBJT(r.session_start);
        const eBJT = r.session_end ? toBJT(r.session_end) : sBJT;
        const conflicts = findClassConflicts(sBJT, eBJT, daySchedule);
        if (conflicts.length) {
          const mm = String(sBJT.getUTCMonth()+1).padStart(2,"0");
          const dd = String(sBJT.getUTCDate()).padStart(2,"0");
          const sh = String(sBJT.getUTCHours()).padStart(2,"0");
          const sm = String(sBJT.getUTCMinutes()).padStart(2,"0");
          const eh = String(eBJT.getUTCHours()).padStart(2,"0");
          const em = String(eBJT.getUTCMinutes()).padStart(2,"0");
          conflictRecords.push({
            date: `${mm}/${dd}`,
            dow: DOW_CN[sBJT.getUTCDay()],
            sessionTime: `${sh}:${sm}-${eh}:${em}`,
            duration: r.raw_duration ?? 0,
            conflicts,
          });
        }
      }

      // 课表覆盖率：实际练琴时间中有多少分钟落在课表排课时段内（时间重叠法）
      let scheduledOverlapMin = 0;
      let totalActualMin = 0;
      for (const r of rawSessions.slice(0, 30)) {
        if (r.is_outlier) continue; // 异常记录不纳入
        const sBJT = toBJT(r.session_start);
        const eBJT = r.session_end ? toBJT(r.session_end) : sBJT;
        const dow = sBJT.getUTCDay();
        if (dow === 0 || dow === 6) continue;
        const dayIdx = dow - 1;
        const sMin = sBJT.getUTCHours() * 60 + sBJT.getUTCMinutes();
        const eMin = eBJT.getUTCHours() * 60 + eBJT.getUTCMinutes();
        const dur = eMin - sMin;
        if (dur <= 0) continue;
        totalActualMin += dur;
        const ds = daySchedule[dayIdx];
        if (!ds) continue;
        // 计算与当天所有排课练琴时段的重叠分钟
        for (const p of ds.practiceSlots) {
          const overlapStart = Math.max(sMin, p.startMin);
          const overlapEnd   = Math.min(eMin, p.endMin);
          if (overlapEnd > overlapStart) scheduledOverlapMin += overlapEnd - overlapStart;
        }
      }
      const slotHitRate = totalActualMin > 0
        ? `${Math.round(scheduledOverlapMin / totalActualMin * 100)}%（实际练琴${totalActualMin}分钟中有${scheduledOverlapMin}分钟落在课表排课时段内）`
        : "数据不足";

      // ── 计算诊断统计量 ──────────────────────────────────────────────
      const recent30 = rawSessions.slice(0, 30);
      const tooLong  = recent30.filter((r: any) => r.outlier_reason === "too_long");
      const mealBrk  = recent30.filter((r: any) => r.outlier_reason === "meal_break");
      const persOut  = recent30.filter((r: any) => r.outlier_reason === "personal_outlier");
      const normal   = recent30.filter((r: any) => !r.is_outlier);
      const outlierRate: number = st.outlier_rate ?? (recent30.filter((r: any) => r.is_outlier).length / Math.max(recent30.length, 1));

      // FIX-40 惩罚系数（折点60%，超过后指数衰减）
      const penalty = outlierRate <= 0.60
        ? 1.0 - 0.4 * outlierRate
        : 0.76 * Math.exp(-3.0 * (outlierRate - 0.60));
      const penaltyPct = Math.round(penalty * 100);

      // 时段分布（北京时间小时）
      const slotOf = (s: any) => {
        const h = new Date(s.session_start).getHours() + 8; // rough BJT
        const hh = h >= 24 ? h - 24 : h;
        if (hh < 8)  return "8点前";
        if (hh < 12) return "上午(8-12点)";
        if (hh < 14) return "午饭时间(12-14点)";
        if (hh < 18) return "下午(14-18点)";
        return "晚上(18点后)";
      };
      const slotMap: Record<string, { total: number; outlier: number }> = {};
      recent30.forEach((r: any) => {
        const slot = slotOf(r);
        if (!slotMap[slot]) slotMap[slot] = { total: 0, outlier: 0 };
        slotMap[slot].total++;
        if (r.is_outlier) slotMap[slot].outlier++;
      });
      const slotLines = Object.entries(slotMap)
        .sort((a, b) => b[1].total - a[1].total)
        .map(([k, v]) => `  ${k}：${v.total}次（其中${v.outlier}次异常，异常率${Math.round(v.outlier / v.total * 100)}%）`);

      // 周次异常率趋势（最近12周快照）
      const weekTrend = histRows.slice(0, 8).reverse()
        .map((h: any) => `  ${String(h.snapshot_date).slice(5, 10)}  outlier=${h.outlier_rate != null ? (Number(h.outlier_rate) * 100).toFixed(0) + "%" : "—"}  排名分=${h.composite_score ?? 0}`)
        .join("\n");

      // ── 诊断 Prompt ────────────────────────────────────────────────
      const diagPrompt = `
你是一位专业的练琴习惯数据分析师，正在为一位老师做单学生深度诊断报告。
请用专业但易懂的中文，直接给出结论和改进建议，不要废话。

【学生基本信息】
姓名：${st.student_name}（${st.student_major || "专业未知"} ${st.student_grade || ""}）
工作日有效记录：${st.record_count ?? 0}条  是否冷启动：${st.is_cold_start ? "是（数据不足）" : "否"}

【基线数据】
个人日均练琴时长：${(st.mean_duration || 0).toFixed(1)}分钟（标准差 ${(st.std_duration || 0).toFixed(1)}分钟）
当前基线可信度 α：${(st.alpha || 0).toFixed(4)}
当前全校排名分：${st.composite_score ?? "—"}/100

【异常率与评分惩罚（核心问题区）】
最近30条记录异常率：${(outlierRate * 100).toFixed(1)}%（超过60%进入指数惩罚区）
当前评分惩罚系数：${penalty.toFixed(3)}（总分约打 ${penaltyPct}% 折扣）
异常明细（最近30条）：
  - 超长未还卡 (too_long > 180分钟)：${tooLong.length}次
  - 跨饭点未还卡 (meal_break)：${mealBrk.length}次
  - 个人离群值 (personal_outlier)：${persOut.length}次
  - 正常记录：${normal.length}条

【时段异常分布（最近30条）】
${slotLines.join("\n") || "  数据不足"}

【近8周异常率与排名分走势】
${weekTrend || "  暂无历史快照"}

【课表信息】
${scheduleSummary}

${hasSchedule ? `【课表 vs 实际练琴对比】
课表安排每周练琴约 ${weeklyScheduledMinutes} 分钟（${practiceDaysCount} 天有排课练琴）
课表时段覆盖率（实际练琴时间与排课时段的重叠比例）：${slotHitRate}
${conflictRecords.length > 0
  ? `⚠ 发现 ${conflictRecords.length} 次练琴记录与上课时间冲突（疑似上课期间未还卡）：\n${
      conflictRecords.slice(0, 8).map(c =>
        `  ${c.date} ${c.dow} ${c.sessionTime}（${c.duration}分钟） ↔ 冲突课程：${c.conflicts.join("、")}`
      ).join("\n")
    }${conflictRecords.length > 8 ? `\n  … 共${conflictRecords.length}次` : ""}`
  : "✓ 未发现与上课时间明显冲突的记录"
}` : ""}

【部分原始记录（最近15条，供参考）】
${rawSessions.slice(0, 15).map((r: any) => {
  const sBJT = toBJT(r.session_start);
  const hm = `${String(sBJT.getUTCHours()).padStart(2,"0")}:${String(sBJT.getUTCMinutes()).padStart(2,"0")}`;
  const dow = DOW_CN[sBJT.getUTCDay()];
  const flag = r.outlier_reason ? ` ⚠${r.outlier_reason}` : "";
  const mm = String(sBJT.getUTCMonth()+1).padStart(2,"0");
  const dd = String(sBJT.getUTCDate()).padStart(2,"0");
  return `  ${mm}/${dd} ${dow} ${hm}  原始${r.raw_duration}分钟 计分${r.cleaned_duration}分钟${flag}`;
}).join("\n")}

【请输出以下四个部分（每部分2-4句话）】
1. 核心问题诊断：这位学生评分被拖低的根本原因是什么？
2. 行为模式分析：从时段/星期分布能看出什么规律？和管理/习惯有什么关联？
3. 课表利用分析：${hasSchedule ? "结合课表，分析该学生是否充分利用了排课的练琴时段？有无课表冲突问题？" : "（无课表数据，跳过此部分）"}
4. 具体改进建议：给出2-3条能立刻执行的具体操作，直接针对主要问题。
`;

      const { text, source } = await callAI(
        "你是一位专业的练琴习惯数据分析师，擅长从数据中发现问题并给出有针对性的改进建议。保持专业、简洁、具体。",
        diagPrompt
      );
      log.push(`✅ ${diagName} 深度诊断完成 (${source})`);
      return json({ text, source, student_name: diagName, diagnostic: true, log });
    } catch (e: any) {
      return json({ error: e.message ?? String(e), log }, 500);
    }
  }

  // ── 单学生模式（前端手动/自动触发单人 AI 分析时使用）─────────────────────
  const singleName: string | undefined = body.student_name;
  if (singleName) {
    try {
      log.push(`单学生模式：${singleName}`);

      const students = await dbGet(
        `student_baseline?student_name=eq.${encodeURIComponent(singleName)}&select=student_name,composite_score,raw_score,baseline_score,trend_score,momentum_score,accum_score,mean_duration,record_count,is_cold_start,weeks_improving,personal_best,short_session_rate,student_major,student_grade&limit=1`
      );
      if (!students.length) {
        return json({ error: `未找到学生：${singleName}`, log }, 404);
      }
      const student = students[0];

      const hist = await dbGet(
        `student_score_history?student_name=eq.${encodeURIComponent(singleName)}&select=snapshot_date,composite_score,raw_score,baseline_score,trend_score,momentum_score,accum_score,outlier_rate,short_session_rate,mean_duration,record_count&order=snapshot_date.asc&limit=52`
      );

      const rawSessionsArr = await dbGet(
        `practice_sessions?student_name=eq.${encodeURIComponent(singleName)}&select=session_start,session_end,cleaned_duration,room_name,is_outlier,outlier_reason&order=session_start.desc&limit=30`
      );

      const sessions: Session[] = rawSessionsArr.map((r: any) => {
        const startMs = new Date(r.session_start).getTime();
        const endMs   = r.session_end ? new Date(r.session_end).getTime() : startMs;
        const rawMin  = Math.round((endMs - startMs) / 60000);
        return {
          session_start:    r.session_start,
          session_end:      r.session_end ?? r.session_start,
          raw_duration:     rawMin,
          cleaned_duration: r.cleaned_duration ?? Math.min(rawMin, 120),
          room_name:        r.room_name,
          is_outlier:       !!r.is_outlier,
          outlier_reason:   r.outlier_reason ?? undefined,
        };
      });


      // 调试日志：打印最新一条记录的时间，确认是否查到了今天的数据
      if (sessions.length > 0) {
        const latest = sessions[0];
        const latestBJT = toBJT(latest.session_start);
        log.push(`🔍 最新记录: ${latest.session_start} (UTC) -> ${latestBJT.toISOString()} (BJT)`);
        
        // 检查是否是今天
        const todayBJT = toBJT(Date.now());
        const isToday = latestBJT.getUTCDate() === todayBJT.getUTCDate() &&
                        latestBJT.getUTCMonth() === todayBJT.getUTCMonth();
        if (isToday) {
            log.push(`✅ 确认包含今日(${todayBJT.getUTCMonth()+1}/${todayBJT.getUTCDate()})记录`);
        } else {
            log.push(`⚠️ 最新记录非今日，最后一次是 ${latestBJT.getUTCMonth()+1}/${latestBJT.getUTCDate()}`);
        }
      } else {
        log.push(`⚠️ 未查到任何练琴记录`);
      }

      const weekMonday = getWeekMonday();
      // 北京时间周一 00:00 对应的 UTC 毫秒数
      const weekMondayMs = new Date(weekMonday + "T00:00:00+08:00").getTime();
      // [FIX-19] 与评分系统一致：只有工作日（周一~周五）练琴才算"本周有练琴"
      student.has_week_snapshot = !sessions.some((s) => {
        if (new Date(s.session_start).getTime() < weekMondayMs) return false;
        const dow = toBJT(s.session_start).getUTCDay(); // 北京时间星期几
        return dow !== 0 && dow !== 6; // 排除周日(0)和周六(6)
      });

      const userPrompt = buildPrompt(student, hist, sessions);
      const { text, source } = await callAI(SYSTEM_PROMPT, userPrompt);

      await dbUpsert("student_ai_analysis", {
        student_name:  singleName,
        analysis_text: text,
        model_source:  source,
        generated_at:  new Date().toISOString(),
      });

      log.push(`✅ ${singleName} — 生成成功 (${source})`);
      return json({ text, source, student_name: singleName, log });
    } catch (e: any) {
      return json({ error: e.message ?? String(e), log }, 500);
    }
  }

  // 分页参数（按综合榜从高到低分页）
  const pageLimit  = typeof body.limit  === "number" ? body.limit  : MAX_STUDENTS_PER_CALL;
  const pageOffset = typeof body.offset === "number" ? body.offset : 0;

  try {
    // 1. 按综合榜分页获取学生：
    //    - 先按 composite_score 倒序
    //    - 再按 student_name 升序作为稳定次排序键
    //    这样自动触发与手动补跑都只会沿“综合榜”翻页，而不是按姓名扫全量。
    const students = await dbGet(
      `student_baseline?select=student_name,composite_score,raw_score,baseline_score,trend_score,momentum_score,accum_score,mean_duration,record_count,is_cold_start,weeks_improving,personal_best,short_session_rate,student_major,student_grade&order=composite_score.desc.nullslast,student_name.asc&limit=${pageLimit}&offset=${pageOffset}`
    );
    log.push(`综合榜分页 offset=${pageOffset} limit=${pageLimit}，获取到 ${students.length} 名学生`);

    // 2. 一次性获取所有学生的 AI 缓存时间
    const cacheRows = await dbGet(
      "student_ai_analysis?select=student_name,generated_at&limit=5000"
    );
    // generated_at → ISO 字符串，方便后面直接与 practice_sessions 时间比较
    const cacheMap = new Map<string, string>(
      cacheRows.map((r: any) => [r.student_name, r.generated_at as string])
    );

    // 3. 通过 RPC 一次性获取每位学生的最新练琴时间（MAX GROUP BY，完整覆盖所有学生）
    //    对应 SQL：SELECT student_name, MAX(session_start) FROM practice_sessions GROUP BY student_name
    const latestSessionRows = await dbRpc("get_latest_session_per_student");
    const latestSessionMap = new Map<string, string>(
      (latestSessionRows as any[]).map((r) => [r.student_name, r.latest_session as string])
    );

    // 4. 过滤出真正需要更新的学生
    //    条件：① 从未生成过  或  ② 上次生成后有新练琴记录
    const needUpdate: any[] = [];
    const skipReasons: string[] = [];

    for (const s of students) {
      const name         = s.student_name;
      const cachedAt     = cacheMap.get(name);         // 上次 AI 生成时间（ISO）
      const latestSession = latestSessionMap.get(name); // 最新练琴时间（ISO）

      if (!cachedAt) {
        // 从未生成过
        needUpdate.push(s);
        continue;
      }

      // 强制刷新逻辑：如果缓存时间早于 FORCE_REFRESH_BEFORE，说明是旧逻辑生成的，必须重跑
      if (cachedAt < FORCE_REFRESH_BEFORE) {
        needUpdate.push(s);
        continue;
      }

      if (!latestSession) {
        // 没有任何练琴记录，无需生成
        skipReasons.push(`${name}（无练琴记录）`);
        continue;
      }

      // [FIX] 必须用 Date 对象比较，不能用字符串比较：
      // PostgreSQL 可能返回 "2026-03-13 10:00:00+00"（空格分隔），
      // JS toISOString() 返回 "2026-03-13T10:00:00.000Z"（T 分隔）。
      // 字符串比较时空格(ASCII 32) < T(ASCII 84)，导致所有带空格格式的 latestSession
      // 都被判定为"早于" cachedAt，学生被错误跳过。
      if (new Date(latestSession).getTime() > new Date(cachedAt).getTime()) {
        // 上次分析之后有新练琴数据 → 需要更新
        needUpdate.push(s);
      } else {
        // 无新数据 → 跳过
        skipReasons.push(`${name}（上次分析后无新练琴）`);
      }
    }

    log.push(`共 ${students.length} 名学生：需更新 ${needUpdate.length} 名，跳过 ${skipReasons.length} 名`);
    if (skipReasons.length > 0 && skipReasons.length <= 20) {
      log.push(`跳过：${skipReasons.join("、")}`);
    }

    let successCount = 0;
    let failCount    = 0;

    // 处理单个学生的函数（供并发调用）
    async function processOne(student: any): Promise<void> {
      const name = student.student_name;
      try {
        const hist = await dbGet(
          `student_score_history?student_name=eq.${encodeURIComponent(name)}&select=snapshot_date,composite_score,raw_score,baseline_score,trend_score,momentum_score,accum_score,outlier_rate,short_session_rate,mean_duration,record_count&order=snapshot_date.asc&limit=52`
        );
        const rawSessions = await dbGet(
          `practice_sessions?student_name=eq.${encodeURIComponent(name)}&select=session_start,session_end,cleaned_duration,room_name,is_outlier,outlier_reason&order=session_start.desc&limit=30`
        );
        const sessions: Session[] = rawSessions.map((r: any) => {
          const startMs = new Date(r.session_start).getTime();
          const endMs   = r.session_end ? new Date(r.session_end).getTime() : startMs;
          const rawMin  = Math.round((endMs - startMs) / 60000);
          return {
            session_start:    r.session_start,
            session_end:      r.session_end ?? r.session_start,
            raw_duration:     rawMin,
            cleaned_duration: r.cleaned_duration ?? Math.min(rawMin, 120),
            room_name:        r.room_name,
            is_outlier:       !!r.is_outlier,
            outlier_reason:   r.outlier_reason ?? undefined,
          };
        });

        const weekMonday = getWeekMonday();
        const weekMondayMs = new Date(weekMonday + "T00:00:00+08:00").getTime();
        // [FIX-19] 与评分系统一致：只有工作日（周一~周五）练琴才算"本周有练琴"
        student.has_week_snapshot = !sessions.some((s) => {
          if (new Date(s.session_start).getTime() < weekMondayMs) return false;
          const dow = toBJT(s.session_start).getUTCDay();
          return dow !== 0 && dow !== 6;
        });

        const userPrompt = buildPrompt(student, hist, sessions);
        const { text, source } = await callAI(SYSTEM_PROMPT, userPrompt);

        await dbUpsert("student_ai_analysis", {
          student_name:  name,
          analysis_text: text,
          model_source:  source,
          generated_at:  new Date().toISOString(),
        });

        successCount++;
        log.push(`✅ ${name} — 生成成功 (${source})`);
      } catch (e: any) {
        failCount++;
        const msg = `❌ ${name} — ${e.message ?? String(e)}`;
        errors.push(msg);
        log.push(msg);
      }
    }

    // 4. 分批并发处理（每批 CONCURRENCY 个，批次间短暂等待）
    for (let i = 0; i < needUpdate.length; i += CONCURRENCY) {
      const batch = needUpdate.slice(i, i + CONCURRENCY);
      await Promise.all(batch.map(processOne));
      if (i + CONCURRENCY < needUpdate.length) {
        await sleep(DELAY_MS);
      }
    }

    const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
    const summary = {
      total:     students.length,
      updated:   successCount,
      skipped:   skipReasons.length,
      failed:    failCount,
      elapsed_s: elapsed,
      errors,
      log,
    };

    return json(summary);
  } catch (e: any) {
    return json({ error: e.message ?? String(e), log }, 500);
  }
});
