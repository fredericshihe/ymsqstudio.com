const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TOKEN = "cc9dc2128fb50edfdcb12e038548d67b16b23bef3d8e24d4";

const FROM = "尤紫悦（试读）";
const TO = "尤紫悦";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

async function rest(path: string, init: RequestInit = {}) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "content-type": "application/json",
      Prefer: "return=representation",
      ...(init.headers || {}),
    },
  });
  const text = await res.text();
  let data: unknown = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }
  if (!res.ok) {
    throw new Error(`${init.method || "GET"} ${path} -> ${res.status}: ${text}`);
  }
  return data;
}

async function countRows(table: string, column: string, value: string) {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/${table}?${column}=eq.${encodeURIComponent(value)}&select=*`,
    {
      method: "HEAD",
      headers: {
        apikey: SERVICE_KEY,
        Authorization: `Bearer ${SERVICE_KEY}`,
        Prefer: "count=exact",
      },
    },
  );
  if (!res.ok) {
    return { table, column, value, error: `${res.status} ${await res.text()}` };
  }
  const range = res.headers.get("content-range") || "";
  const count = Number(range.split("/").pop());
  return { table, column, value, count: Number.isFinite(count) ? count : null };
}

async function updateName(table: string, column: string, from = FROM, to = TO) {
  const data = await rest(
    `${table}?${column}=eq.${encodeURIComponent(from)}`,
    {
      method: "PATCH",
      body: JSON.stringify({ [column]: to }),
    },
  );
  return { table, column, updated: Array.isArray(data) ? data.length : null };
}

async function deleteByName(table: string, column: string, value: string) {
  const data = await rest(
    `${table}?${column}=eq.${encodeURIComponent(value)}`,
    { method: "DELETE" },
  );
  return { table, column, deleted: Array.isArray(data) ? data.length : null };
}

async function readBaseline() {
  const inFilter = encodeURIComponent(`("${TO}","${FROM}")`);
  return await rest(
    `student_baseline?student_name=in.${inFilter}&select=student_name,composite_score,record_count,last_updated`,
  );
}

Deno.serve(async (req) => {
  try {
    const auth = req.headers.get("x-oneoff-token") || "";
    if (auth !== TOKEN) return json({ error: "unauthorized" }, 401);

    const url = new URL(req.url);
    const dryRun = url.searchParams.get("dry_run") === "1";

    const before = {
      baseline: await readBaseline(),
      counts: await Promise.all([
        countRows("student_database", "name", TO),
        countRows("student_database", "name", FROM),
        countRows("rooms", "occupant_student_name", FROM),
        countRows("practice_sessions", "student_name", TO),
        countRows("practice_sessions", "student_name", FROM),
        countRows("student_score_history", "student_name", TO),
        countRows("student_score_history", "student_name", FROM),
        countRows("student_ai_analysis", "student_name", TO),
        countRows("student_ai_analysis", "student_name", FROM),
        countRows("student_time_slots", "student_name", FROM),
        countRows("student_coins", "student_name", FROM),
        countRows("coin_transactions", "student_name", FROM),
        countRows("weekly_coin_reward_log", "student_name", FROM),
      ]),
    };

    if (dryRun) return json({ dryRun, from: FROM, to: TO, before });

    const baselineRows = before.baseline as Array<any>;
    const oldBaseline = baselineRows.find((r) => r.student_name === TO);
    const trialBaseline = baselineRows.find((r) => r.student_name === FROM);
    if (!oldBaseline || !trialBaseline) {
      return json({ error: "expected both baseline rows before merge", before }, 409);
    }

    const oldScore = Number(oldBaseline.composite_score);
    const oldCount = Number(oldBaseline.record_count);
    const trialScore = Number(trialBaseline.composite_score);
    const trialCount = Number(trialBaseline.record_count);
    if (Math.round(oldScore * 10) !== 596 || oldCount !== 6 || Math.round(trialScore * 10) !== 873 || trialCount !== 30) {
      return json({
        error: "baseline rows do not match expected 59.6/6 and 87.3/30; aborting",
        before,
      }, 409);
    }

    const operations: unknown[] = [];

    // Avoid unique conflicts, then keep the stronger trial baseline under the canonical name.
    operations.push(await deleteByName("student_baseline", "student_name", TO));
    operations.push(await updateName("student_baseline", "student_name"));

    // Current UI state and derived/cached data.
    operations.push(await updateName("rooms", "occupant_student_name"));
    operations.push(await updateName("practice_sessions", "student_name"));

    // Replace stale/colliding cached analysis/history with the trial-name versions.
    operations.push(await deleteByName("student_ai_analysis", "student_name", TO));
    operations.push(await updateName("student_ai_analysis", "student_name"));
    operations.push(await deleteByName("student_score_history", "student_name", TO));
    operations.push(await updateName("student_score_history", "student_name"));

    // Optional related tables if rows exist.
    for (const [table, column] of [
      ["student_time_slots", "student_name"],
      ["student_coins", "student_name"],
      ["coin_transactions", "student_name"],
      ["weekly_coin_reward_log", "student_name"],
      ["student_schedules", "name"],
    ]) {
      try {
        operations.push(await updateName(table, column));
      } catch (e) {
        operations.push({ table, column, warning: String(e) });
      }
    }

    const after = {
      baseline: await readBaseline(),
      counts: await Promise.all([
        countRows("student_database", "name", TO),
        countRows("student_database", "name", FROM),
        countRows("rooms", "occupant_student_name", FROM),
        countRows("rooms", "occupant_student_name", TO),
        countRows("practice_sessions", "student_name", TO),
        countRows("practice_sessions", "student_name", FROM),
        countRows("student_score_history", "student_name", TO),
        countRows("student_score_history", "student_name", FROM),
        countRows("student_ai_analysis", "student_name", TO),
        countRows("student_ai_analysis", "student_name", FROM),
      ]),
    };

    return json({ ok: true, from: FROM, to: TO, before, operations, after });
  } catch (e) {
    return json({ error: String(e?.message || e) }, 500);
  }
});
