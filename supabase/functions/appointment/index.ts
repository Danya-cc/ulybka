// Страница записи по личной ссылке из напоминания Лиды (r.html?t=<токен>).
// Без ИИ: показать запись, подтвердить, отменить. Перенос делает Зоя на сайте.
// Токен — пропуск к записям одного пациента; он приходит только ему в Telegram.

import { createClient } from "npm:@supabase/supabase-js@2";

const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}").default;
const db = createClient(Deno.env.get("SUPABASE_URL")!, SERVICE_KEY, { auth: { persistSession: false } });

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, apikey, authorization, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const ERRORS: Record<string, string> = {
  LINK_NOT_FOUND: "Ссылка не найдена. Проверьте, что открыли её полностью.",
  LINK_EXPIRED: "Срок действия ссылки истёк.",
  APPOINTMENT_NOT_FOUND: "Запись не найдена.",
  APPOINTMENT_NOT_ACTIVE: "Эта запись уже отменена или завершена.",
  APPOINTMENT_IN_PAST: "Время этой записи уже прошло.",
};
const explain = (m: string) => ERRORS[Object.keys(ERRORS).find((k) => m.includes(k)) ?? ""] ?? "Что-то пошло не так. Позвоните нам: +7 (495) 000-12-34.";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "Bad JSON" }, 400); }

  const token = String(body?.token ?? "");
  if (!/^[0-9a-f]{24}$/.test(token)) return json({ error: ERRORS.LINK_NOT_FOUND }, 404);

  const load = async () => {
    const { data, error } = await db.rpc("appt_by_token", { p_token: token });
    if (error) throw error;
    return data;
  };

  try {
    const appt = await load();
    if (body.action === "confirm" || body.action === "cancel") {
      const fn = body.action === "confirm" ? "patient_confirm_appointment" : "patient_cancel_appointment";
      const { error } = await db.rpc(fn, { p_appointment_id: appt.appointment_id, p_patient_id: appt.patient_id });
      if (error) throw error;
    }
    const fresh = await load();
    delete fresh.patient_id; // наружу внутренние id пациента не отдаём
    return json({ appointment: fresh });
  } catch (e: any) {
    const msg = e?.message ?? String(e);
    console.error("appointment page", body?.action, msg);
    return json({ error: explain(msg) }, 400);
  }
});
