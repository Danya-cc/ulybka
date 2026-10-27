#!/usr/bin/env node
// Прогон тестов Зои: node evals/run.mjs  (подробности — evals/README.md)
//
// Каждый сценарий — новый диалог с настоящей Зоей. Ключ автотестов (EVAL_KEY) нужен, чтобы
// Зоя вернула список вызванных инструментов и стоимость, а в журнале диалог пометился как тест.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import YAML from "yaml";

const dir = path.dirname(fileURLToPath(import.meta.url));
const ZOYA_URL = process.env.ZOYA_URL ?? "https://jeaqmrzudzaazhzrnnzh.supabase.co/functions/v1/zoya";
const SUPABASE_KEY = process.env.SUPABASE_KEY ?? "sb_publishable_UVXT546-AEnPp61vgYmYLg_ocuKUOym";
const EVAL_KEY = process.env.EVAL_KEY;
const JUDGE_KEY = process.env.ANTHROPIC_API_KEY; // необязательно: без него критерии judge пропускаются
const ONLY = process.env.ONLY?.split(",").map((s) => s.trim());

if (!EVAL_KEY) {
  console.error("Нужна переменная EVAL_KEY (ключ автотестов). См. evals/README.md");
  process.exit(2);
}

const { cases } = YAML.parse(fs.readFileSync(path.join(dir, "zoya.yaml"), "utf8"));
const selected = ONLY ? cases.filter((c) => ONLY.includes(c.id)) : cases;

async function say(sessionId, message) {
  const res = await fetch(ZOYA_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: SUPABASE_KEY, "x-eval-key": EVAL_KEY },
    body: JSON.stringify({ session_id: sessionId, message }),
  });
  if (!res.ok) throw new Error(`Зоя ответила ${res.status}: ${await res.text()}`);
  const data = await res.json();
  if (!data.debug) throw new Error("Нет debug в ответе — ключ автотестов не принят");
  return data;
}

async function judge(transcript, criterion) {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": JUDGE_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({
      model: "claude-sonnet-5-5",
      max_tokens: 300,
      messages: [{
        role: "user",
        content: `Ты проверяешь работу ИИ-администратора стоматологии. Вот диалог:\n\n${transcript}\n\n` +
          `Критерий: ${criterion}\n\nОтветь строго JSON без пояснений вокруг: {"pass": true|false, "reason": "одно предложение по-русски"}`,
      }],
    }),
  });
  const data = await res.json();
  const text = data.content?.[0]?.text ?? "{}";
  return JSON.parse(text.slice(text.indexOf("{"), text.lastIndexOf("}") + 1));
}

const results = [];
let totalCost = 0;

for (const c of selected) {
  const started = Date.now();
  const fails = [];
  const notes = [];
  let sessionId = null;
  const replies = [];
  const tools = [];
  let cost = 0;
  try {
    for (const turn of c.turns) {
      const r = await say(sessionId, turn);
      sessionId = r.session_id;
      replies.push(r.reply);
      tools.push(...r.debug.tools);
      cost += r.debug.cost_usd;
    }
  } catch (e) {
    fails.push(`ошибка выполнения: ${e.message}`);
  }
  totalCost += cost;

  const ex = c.expect ?? {};
  const last = replies.at(-1) ?? "";
  for (const t of ex.tools_called ?? []) if (!tools.includes(t)) fails.push(`не вызван ${t}`);
  for (const t of ex.tools_not_called ?? []) if (tools.includes(t)) fails.push(`вызван запрещённый ${t}`);
  for (const re of ex.final_matches ?? []) if (!new RegExp(re, "i").test(last)) fails.push(`последний ответ не содержит /${re}/`);
  for (const re of ex.never_matches ?? []) {
    const hit = replies.find((r) => new RegExp(re, "im").test(r));
    if (hit) fails.push(`найдено запрещённое /${re}/`);
  }
  if (ex.max_cost_usd && cost > ex.max_cost_usd) fails.push(`дорого: $${cost.toFixed(4)} > $${ex.max_cost_usd}`);

  if (c.judge) {
    if (!JUDGE_KEY) notes.push("judge пропущен (нет ANTHROPIC_API_KEY)");
    else {
      const transcript = c.turns.map((t, i) => `Пациент: ${t}\nЗоя: ${replies[i] ?? "—"}`).join("\n\n");
      try {
        const v = await judge(transcript, c.judge);
        if (!v.pass) fails.push(`judge: ${v.reason}`); else notes.push(`judge: ${v.reason}`);
      } catch (e) { notes.push(`judge не сработал: ${e.message}`); }
    }
  }

  const ok = fails.length === 0;
  results.push({ id: c.id, area: c.area, critical: !!c.critical, ok, fails, notes, tools, cost, replies, session_id: sessionId, ms: Date.now() - started });
  console.log(`${ok ? "✅" : c.critical ? "❌" : "⚠️ "} ${c.id.padEnd(32)} ${("$" + cost.toFixed(4)).padStart(9)}  ${[...new Set(tools)].join(", ")}`);
  for (const f of fails) console.log(`     ↳ ${f}`);
  if (!ok) console.log(`     ↳ последний ответ: ${last.replace(/\s+/g, " ").slice(0, 220)}`);
}

// Уборка: тестовые записи снимаются (время врача освобождается), тестовые заявки и пациенты удаляются
try {
  const res = await fetch(ZOYA_URL.replace(/\/zoya$/, "/evals"), {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: SUPABASE_KEY, "x-eval-key": EVAL_KEY },
    body: JSON.stringify({ action: "cleanup" }),
  });
  const data = await res.json();
  console.log(res.ok ? `\nУборка: снято записей ${data.removed.appointments}, заявок ${data.removed.leads}, пациентов ${data.removed.patients}` : `\nУборка не удалась: ${JSON.stringify(data)}`);
} catch (e) { console.log(`\nУборка не удалась: ${e.message}`); }

const passed = results.filter((r) => r.ok).length;
const criticalFailed = results.filter((r) => !r.ok && r.critical);
console.log(`\nИтого: ${passed}/${results.length} пройдено, критических провалов: ${criticalFailed.length}, стоимость прогона: $${totalCost.toFixed(4)}`);

fs.mkdirSync(path.join(dir, "results"), { recursive: true });
const file = path.join(dir, "results", `${new Date().toISOString().replace(/[:.]/g, "-")}.json`);
fs.writeFileSync(file, JSON.stringify({ at: new Date().toISOString(), totalCost, results }, null, 2));
console.log(`Подробности: ${path.relative(process.cwd(), file)}`);
process.exit(criticalFailed.length ? 1 : 0);
