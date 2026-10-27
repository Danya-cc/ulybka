// Лида — бот клиники «Улыбка» для пациентов в Telegram.
//
// Что умеет (без ИИ — только шаблоны и кнопки):
//   • /start <токен> — привязывает Telegram к пациенту (одноразовая ссылка, которую Зоя даёт после записи);
//   • напоминание за день до приёма (action: "send_reminders", вызывается из базы по расписанию):
//     в тексте только дата и время, подробности — на странице записи на сайте (r.html?t=<токен>);
//   • кнопки «Приду» / «Отменить» прямо в Telegram, «Подробнее и перенос» — ссылка на страницу записи;
//   • /start login_<токен> — подтверждение входа на сайт: «Это вы входите?» → Да / Нет.
// Свободную переписку Лида не ведёт: чтобы в иностранный мессенджер не уходили подробности о здоровье.
// На любое сообщение она отвечает подсказкой со ссылкой на запись и на Зою.

import { createClient } from "npm:@supabase/supabase-js@2";

const SITE_URL = "https://danya-cc.github.io/ulybka/";
const PHONE = "+7 (495) 000-12-34";

// Отдельный бот для пациентов. Служебный бот владельца (TELEGRAM_BOT_TOKEN) использует notify-admin.
const TOKEN = Deno.env.get("TELEGRAM_PATIENT_BOT_TOKEN") ?? Deno.env.get("TELEGRAM_BOT_TOKEN")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}").default;
const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

// ---------------- Telegram ----------------
async function tg(method: string, payload: unknown) {
  const res = await fetch(`https://api.telegram.org/bot${TOKEN}/${method}`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload),
  });
  const data = await res.json();
  if (!data.ok) throw new Error(`Telegram ${method}: ${data.description}`);
  return data.result;
}
const send = (chat_id: number | string, text: string, extra: Record<string, unknown> = {}) =>
  tg("sendMessage", { chat_id, text, ...extra }).catch((e) => console.error(e.message));

async function getSetting(key: string) {
  const { data } = await db.from("app_settings").select("value").eq("key", key).maybeSingle();
  return data?.value ?? null;
}
async function setSetting(key: string, value: string) {
  await db.from("app_settings").upsert({ key, value, updated_at: new Date().toISOString() });
}
const randomHex = (n: number) => [...crypto.getRandomValues(new Uint8Array(n))].map((b) => b.toString(16).padStart(2, "0")).join("");

// Личная ссылка на страницу записи (токен живёт до следующего дня после приёма)
async function apptUrl(appointmentId: number) {
  const { data, error } = await db.rpc("create_appt_link", { p_appointment_id: appointmentId });
  if (error) throw error;
  return `${SITE_URL}r.html?t=${data}`;
}

// ---------------- Напоминание ----------------
const reminderKeyboard = (id: number, url: string) => ({
  inline_keyboard: [
    [{ text: "✅ Приду", callback_data: `c:${id}` }, { text: "❌ Отменить", callback_data: `x:${id}` }],
    [{ text: "📋 Подробнее и перенос", url }],
  ],
});
const reminderText = (r: any) =>
  `Здравствуйте! Это Лида из клиники «Улыбка».\n\nНапоминаю о приёме завтра, ${r.weekday} ${r.date}, в ${r.start_time}.\n\nПридёте?`;

async function sendReminders() {
  const { data, error } = await db.rpc("appointments_to_remind");
  if (error) throw error;
  let sent = 0;
  for (const r of data) {
    try {
      const url = await apptUrl(r.appointment_id);
      await tg("sendMessage", { chat_id: r.tg_chat_id, text: reminderText(r), reply_markup: reminderKeyboard(r.appointment_id, url) });
      await db.from("appointments").update({ reminder_sent_at: new Date().toISOString() }).eq("id", r.appointment_id);
      sent++;
    } catch (e: any) {
      console.error("reminder failed", r.appointment_id, e.message); // например, пациент заблокировал бота
    }
  }
  return { found: data.length, sent };
}

// ---------------- Сообщения и кнопки ----------------
const NOT_LINKED = `Здравствуйте! Это Лида, ассистент стоматологии «Улыбка».\n\nЧтобы получать напоминания о приёме, запишитесь на сайте ${SITE_URL} — после записи администратор Зоя пришлёт личную ссылку на этого бота.`;

async function patientByChat(chatId: number) {
  const { data } = await db.from("patients").select("id, full_name").eq("tg_chat_id", chatId).maybeSingle();
  return data;
}

// Ближайшие записи: только дата и время, без услуги и врача
async function upcoming(patientId: number) {
  const { data } = await db.rpc("patient_appointments", { p_patient_id: patientId });
  return (data ?? []) as any[];
}
const upcomingText = (list: any[]) =>
  list.length ? "\n\nВаши записи:\n" + list.map((a) => `• ${a.weekday} ${a.date.slice(0, 5)} в ${a.start_time}`).join("\n") : "";

// Кнопка на ближайшую запись (или на сайт, если записей нет)
async function linkButtons(list: any[]) {
  const rows: any[] = [];
  if (list.length) rows.push([{ text: "📋 Открыть запись", url: await apptUrl(list[0].appointment_id) }]);
  rows.push([{ text: "💬 Написать Зое на сайте", url: SITE_URL }]);
  return { inline_keyboard: rows };
}

async function handleMessage(msg: any) {
  if (msg.chat?.type !== "private" || typeof msg.text !== "string") return;
  const chatId = msg.chat.id;
  const text = msg.text.trim();

  if (text.startsWith("/start")) {
    const token = text.split(/\s+/)[1];
    if (token?.startsWith("login_")) return handleLogin(chatId, token.slice(6));
    if (token) {
      const { data, error } = await db.rpc("use_tg_link", { p_token: token, p_chat_id: chatId });
      if (error) {
        const m = error.message;
        const why = m.includes("LINK_USED") ? "Эта ссылка уже использована." : m.includes("LINK_EXPIRED") ? "Срок действия ссылки истёк." : "Ссылка не найдена.";
        const p = await patientByChat(chatId);
        return send(chatId, p ? `${why} Но вы уже подключены, ${p.full_name}: я напомню о приёме за день.` : `${why}\n\n${NOT_LINKED}`);
      }
      const list = await upcoming(data.patient_id);
      return send(chatId, `Готово, ${data.name}! Я Лида, ассистент клиники «Улыбка». Напомню о приёме за день до визита.${upcomingText(list)}`,
        { reply_markup: await linkButtons(list) });
    }
    const p = await patientByChat(chatId);
    if (!p) return send(chatId, NOT_LINKED);
    const list = await upcoming(p.id);
    return send(chatId, `Здравствуйте, ${p.full_name}! Это Лида из клиники «Улыбка». Я напомню о приёме за день.${upcomingText(list)}`,
      { reply_markup: await linkButtons(list) });
  }

  const patient = await patientByChat(chatId);
  if (!patient) return send(chatId, NOT_LINKED);
  const list = await upcoming(patient.id);
  return send(chatId,
    `Я присылаю напоминания о приёмах, а переписку здесь не веду. Посмотреть, подтвердить, перенести или отменить запись можно на странице записи. С вопросами поможет администратор Зоя на сайте или по телефону ${PHONE}.`,
    { reply_markup: await linkButtons(list) });
}

// Вход на сайт через Telegram. Кнопка подтверждения обязательна: иначе злоумышленник мог бы
// подсунуть пациенту свою ссылку и войти на сайте под его именем, как только тот нажмёт Start.
async function handleLogin(chatId: number, token: string) {
  const { data } = await db.rpc("tg_login_attach", { p_token: token, p_chat_id: chatId });
  if (data?.status === "not_linked") {
    return send(chatId, `Ваш Telegram пока не привязан к записи в клинике, поэтому войти не получится.\n\nЗапишитесь у администратора Зои на сайте — после записи она пришлёт личную ссылку на этого бота. Или позвоните: ${PHONE}.`);
  }
  if (data?.status !== "awaiting_confirm") return send(chatId, "Ссылка для входа устарела. Нажмите «Войти через Telegram» на сайте ещё раз.");
  return send(chatId, `Вход в чат на сайте клиники «Улыбка».\n\n${data.name}, это вы сейчас входите? Если вы ничего не открывали на сайте — нажмите «Нет».`, {
    reply_markup: { inline_keyboard: [[{ text: "✅ Да, это я", callback_data: `ly:${token}` }, { text: "Нет", callback_data: `ln:${token}` }]] },
  });
}

async function handleCallback(cb: any) {
  const chatId = cb.message?.chat?.id, messageId = cb.message?.message_id;
  const answer = (text?: string) => tg("answerCallbackQuery", { callback_query_id: cb.id, ...(text ? { text } : {}) }).catch(() => {});
  const [kind, rawId] = String(cb.data ?? "").split(":");

  // Подтверждение входа на сайт
  if ((kind === "ly" || kind === "ln") && chatId) {
    const { data } = await db.rpc("tg_login_confirm", { p_token: rawId, p_chat_id: chatId, p_yes: kind === "ly" });
    const textByStatus: Record<string, string> = {
      confirmed: "✅ Готово, вы вошли. Вернитесь на сайт — Зоя уже видит ваши записи.",
      rejected: "Вход отклонён. Если это были не вы, просто проигнорируйте: без вашего подтверждения никто не увидит ваши данные.",
    };
    await answer(data?.status === "confirmed" ? "Вход подтверждён" : undefined);
    await tg("editMessageText", { chat_id: chatId, message_id: messageId, text: textByStatus[data?.status] ?? "Ссылка для входа устарела. Нажмите «Войти через Telegram» на сайте ещё раз." }).catch(() => {});
    return;
  }

  const patient = chatId ? await patientByChat(chatId) : null;
  if (!patient) { await answer("Запись не найдена"); return; }

  const id = Number(rawId);
  const original = cb.message?.text ?? "";
  const finish = (suffix: string) => tg("editMessageText", { chat_id: chatId, message_id: messageId, text: `${original}\n\n${suffix}` }).catch(() => {});
  const keyboard = async () => reminderKeyboard(id, await apptUrl(id));

  if (kind === "c") {
    const { error } = await db.rpc("patient_confirm_appointment", { p_appointment_id: id, p_patient_id: patient.id });
    await answer(error ? "Не получилось — запись не найдена" : "Спасибо, ждём вас!");
    if (!error) await finish("✅ Вы подтвердили визит. Ждём вас!");
  } else if (kind === "x") {
    await answer();
    await tg("editMessageReplyMarkup", { chat_id: chatId, message_id: messageId, reply_markup: { inline_keyboard: [[
      { text: "Да, отменить", callback_data: `xx:${id}` }, { text: "Нет, оставить", callback_data: `k:${id}` },
    ]] } }).catch(() => {});
  } else if (kind === "xx") {
    const { error } = await db.rpc("patient_cancel_appointment", { p_appointment_id: id, p_patient_id: patient.id });
    await answer(error ? "Не получилось отменить" : "Запись отменена");
    if (!error) await finish("❌ Запись отменена. Записаться снова можно на сайте у администратора Зои.");
  } else if (kind === "k") {
    await answer("Оставили запись");
    await tg("editMessageReplyMarkup", { chat_id: chatId, message_id: messageId, reply_markup: await keyboard() }).catch(() => {});
  } else if (kind === "r") {
    // кнопка «Перенести» из старых напоминаний: теперь перенос — на странице записи
    await answer();
    await send(chatId, "Перенести запись можно на странице записи:", { reply_markup: { inline_keyboard: [[{ text: "📋 Открыть запись", url: await apptUrl(id) }]] } });
  } else {
    await answer();
  }
}

// ---------------- Точка входа ----------------
Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "Bad JSON" }, 400); }

  // Служебные действия: настройка вебхука, профиля и рассылка (из базы по расписанию)
  if (body?.action) {
    const cronSecret = await getSetting("cron_secret");
    const authorized = cronSecret && req.headers.get("x-cron-secret") === cronSecret;

    if (body.action === "setup") {
      if (cronSecret && !authorized) return json({ error: "Forbidden" }, 403);
      const webhookSecret = randomHex(24);
      const me = await tg("getMe", {});
      await tg("setWebhook", { url: `${SUPABASE_URL}/functions/v1/telegram-bot`, secret_token: webhookSecret,
        allowed_updates: ["message", "callback_query"], drop_pending_updates: true });
      await setSetting("webhook_secret", webhookSecret);
      await setSetting("bot_username", me.username);
      if (!cronSecret) await setSetting("cron_secret", randomHex(24));
      return json({ ok: true, bot: "@" + me.username });
    }
    if (body.action === "set_profile") {
      if (!authorized) return json({ error: "Forbidden" }, 403);
      await tg("setMyName", { name: "Лида · клиника «Улыбка»" });
      await tg("setMyShortDescription", { short_description: "Напоминаю о приёме в стоматологии «Улыбка» за день до визита." });
      await tg("setMyDescription", { description: "Здравствуйте! Я Лида, ассистент стоматологии «Улыбка».\n\nНапомню о приёме за день до визита. Подтвердить или отменить запись можно прямо здесь, перенести — на странице записи.\n\nЧтобы подключиться, запишитесь на сайте — администратор Зоя пришлёт личную ссылку." });
      const me = await tg("getMe", {});
      return json({ ok: true, patient_bot: "@" + me.username });
    }
    if (body.action === "send_reminders") {
      if (!authorized) return json({ error: "Forbidden" }, 403);
      return json({ ok: true, ...(await sendReminders()) });
    }
    return json({ error: "Unknown action" }, 400);
  }

  // Сообщения от Telegram: проверяем секрет, который сами выдали при настройке вебхука
  const secret = await getSetting("webhook_secret");
  if (!secret || req.headers.get("x-telegram-bot-api-secret-token") !== secret) return json({ error: "Forbidden" }, 403);
  try {
    if (body.callback_query) await handleCallback(body.callback_query);
    else if (body.message) await handleMessage(body.message);
  } catch (e) {
    console.error("update error", e);
  }
  return json({ ok: true }); // Telegram ждёт 200, иначе будет присылать то же сообщение снова
});
