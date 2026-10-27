// Уведомления администратору клиники в Telegram.
// Кто вызывает: триггеры базы (новая запись, отмена, новая заявка) через pg_net.
// Что приходит в запросе: только тип события и id строки. Текст сообщения функция собирает сама
// из базы, поэтому подделать содержимое уведомления снаружи нельзя.

import { createClient } from "npm:@supabase/supabase-js@2";

const TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN");
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}").default;
const db = createClient(Deno.env.get("SUPABASE_URL")!, SERVICE_KEY, { auth: { persistSession: false } });

const FRESH_MINUTES = 10; // уведомляем только о свежих событиях — защита от повторных вызовов снаружи

const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

async function tg(method: string, payload: unknown) {
  const res = await fetch(`https://api.telegram.org/bot${TOKEN}/${method}`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload),
  });
  const data = await res.json();
  if (!data.ok) throw new Error(`Telegram ${method}: ${data.description}`);
  return data.result;
}

async function getChatId(): Promise<string | null> {
  const { data } = await db.from("app_settings").select("value").eq("key", "admin_chat_id").maybeSingle();
  return data?.value ?? null;
}

// 79092255511 -> +7 909 225-55-11
const phone = (p: string) => /^7\d{10}$/.test(p) ? `+7 ${p.slice(1, 4)} ${p.slice(4, 7)}-${p.slice(7, 9)}-${p.slice(9)}` : p;
const when = (iso: string) => new Intl.DateTimeFormat("ru-RU", {
  timeZone: "Europe/Moscow", weekday: "short", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit",
}).format(new Date(iso));
const SOURCE: Record<string, string> = { chat: "из чата на сайте", form: "из формы на сайте", admin: "администратор", phone: "по телефону" };
// Записи и заявки из диалогов автотестов владельцу не показываем
async function isEval(sessionId: string | null) {
  if (!sessionId) return false;
  const { data } = await db.rpc("is_eval_session", { p_session_id: sessionId });
  return data === true;
}
const isFresh = (iso: string) => Date.now() - new Date(iso).getTime() < FRESH_MINUTES * 60_000;

async function loadAppointment(id: number) {
  const { data } = await db.from("appointments")
    .select("id, status, comment, source, session_id, created_at, updated_at, notified_at, cancel_notified_at, patients(full_name, phone), services(name), doctors(full_name), slots(starts_at)")
    .eq("id", id).maybeSingle();
  return data as any;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  if (!TOKEN) return json({ error: "TELEGRAM_BOT_TOKEN не задан в секретах" }, 500);
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "Bad JSON" }, 400); }

  // ---- Первичная настройка: узнаём, кто написал боту, и запоминаем этот чат ----
  if (body.action === "setup") {
    if (await getChatId()) return json({ ok: true, message: "Чат администратора уже привязан" });
    const updates = await tg("getUpdates", { allowed_updates: ["message"] });
    const msg = [...updates].reverse().find((u: any) => u.message?.chat?.type === "private")?.message;
    if (!msg) {
      // Диагностика: от имени какого бота работает токен и не перехватывает ли сообщения вебхук
      const me = await tg("getMe", {});
      const hook = await tg("getWebhookInfo", {});
      return json({
        ok: false,
        message: "Боту пока никто не писал. Напишите боту любое сообщение и повторите.",
        bot: "@" + me.username,
        webhook_set: Boolean(hook.url),
        updates_received: updates.length,
      });
    }
    await db.from("app_settings").upsert({ key: "admin_chat_id", value: String(msg.chat.id) });
    await tg("sendMessage", {
      chat_id: msg.chat.id,
      text: "✅ Уведомления клиники «Улыбка» подключены.\n\nСюда будут приходить новые записи, переносы, отмены и заявки на звонок.",
    });
    return json({ ok: true, message: `Привязан чат: ${msg.chat.first_name ?? ""} ${msg.chat.username ? "@" + msg.chat.username : ""}`.trim() });
  }

  // ---- События из базы ----
  const chatId = await getChatId();
  if (!chatId) return json({ ok: false, message: "Чат администратора не привязан" });
  const id = Number(body.id);
  if (!Number.isInteger(id)) return json({ error: "Bad id" }, 400);

  let text = "";

  if (body.type === "appointment_created") {
    const a = await loadAppointment(id);
    if (!a || a.notified_at || !isFresh(a.created_at)) return json({ ok: true, skipped: true });
    if (await isEval(a.session_id)) return json({ ok: true, skipped: "eval" });
    const moved = /перенесено с записи №(\d+)/.exec(a.comment ?? "");
    const title = moved ? "🔁 Перенос записи" : "🦷 Новая запись";
    text = `${title} (${SOURCE[a.source] ?? a.source})\n` +
      `${a.patients.full_name}, ${phone(a.patients.phone)}\n` +
      `${a.services.name} — ${a.doctors.full_name}\n` +
      `${when(a.slots.starts_at)}`;
    if (moved) {
      const old = await loadAppointment(Number(moved[1]));
      if (old) text += `\nБыло: ${when(old.slots.starts_at)}`;
    }
    const userComment = (a.comment ?? "").replace(/\s*\(перенесено с записи №\d+\)/, "").trim();
    if (userComment) text += `\nКомментарий: ${userComment}`;
    await tg("sendMessage", { chat_id: chatId, text });
    await db.from("appointments").update({ notified_at: new Date().toISOString() }).eq("id", id);
  }

  else if (body.type === "appointment_cancelled") {
    const a = await loadAppointment(id);
    if (!a || a.status !== "cancelled" || a.cancel_notified_at || !isFresh(a.updated_at)) return json({ ok: true, skipped: true });
    if (await isEval(a.session_id)) return json({ ok: true, skipped: "eval" });
    // Если запись отменили ради переноса — об этом придёт сообщение «Перенос», отдельная «Отмена» не нужна
    const { data: successor } = await db.from("appointments").select("id").like("comment", `%перенесено с записи №${id})%`).maybeSingle();
    if (successor) {
      await db.from("appointments").update({ cancel_notified_at: new Date().toISOString() }).eq("id", id);
      return json({ ok: true, skipped: "reschedule" });
    }
    text = `❌ Отмена записи\n` +
      `${a.patients.full_name}, ${phone(a.patients.phone)}\n` +
      `${a.services.name} — ${a.doctors.full_name}\n` +
      `${when(a.slots.starts_at)} — время освободилось`;
    await tg("sendMessage", { chat_id: chatId, text });
    await db.from("appointments").update({ cancel_notified_at: new Date().toISOString() }).eq("id", id);
  }

  else if (body.type === "lead_created") {
    const { data: l } = await db.from("leads").select("*").eq("id", id).maybeSingle();
    if (!l || l.notified_at || !isFresh(l.created_at)) return json({ ok: true, skipped: true });
    if (await isEval(l.session_id)) return json({ ok: true, skipped: "eval" });
    text = `📞 Заявка на звонок (${SOURCE[l.source] ?? l.source})\n` +
      `${l.name}, ${phone(l.phone)}` +
      (l.comment ? `\n${l.comment}` : "");
    await tg("sendMessage", { chat_id: chatId, text });
    await db.from("leads").update({ notified_at: new Date().toISOString() }).eq("id", id);
  }

  else return json({ error: "Unknown type" }, 400);

  return json({ ok: true });
});
