// Служебная функция для автотестов Зои (evals/run.mjs).
// action "cleanup": снимает записи, сделанные в тестовых диалогах, удаляет тестовые заявки и пациентов.
// action "verified_session": создаёт диалог, где личность «подтверждена» для тестового пациента.
// Доступ — только с ключом автотестов (в базе хранится лишь его SHA-256).

import { createClient } from "npm:@supabase/supabase-js@2";

const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}").default;
const db = createClient(Deno.env.get("SUPABASE_URL")!, SERVICE_KEY, { auth: { persistSession: false } });
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

async function sha256(text: string) {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)))]
    .map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const key = req.headers.get("x-eval-key") ?? "";
  const { data: s } = await db.from("app_settings").select("value").eq("key", "eval_key_sha256").maybeSingle();
  if (!key || !s?.value || (await sha256(key)) !== s.value) return json({ error: "Forbidden" }, 403);

  let body: any = {};
  try { body = await req.json(); } catch { /* пустое тело */ }
  if (body.action === "cleanup") {
    const { data, error } = await db.rpc("cleanup_eval_data");
    if (error) return json({ error: error.message }, 500);
    return json({ ok: true, removed: data });
  }
  // Подтверждённый тестовый пациент «Тест Памятин» с сохранённым пожеланием — для тестов памяти
  if (body.action === "verified_session") {
    const { data, error } = await db.rpc("eval_verified_session");
    if (error) return json({ error: error.message }, 500);
    return json({ ok: true, ...data });
  }
  return json({ error: "Unknown action" }, 400);
});
