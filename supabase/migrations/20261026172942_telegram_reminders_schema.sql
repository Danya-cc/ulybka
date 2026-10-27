-- ===== Привязка Telegram к пациенту =====
alter table public.patients add column tg_chat_id bigint unique;

-- Одноразовые ссылки t.me/бот?start=ТОКЕН. Выдаются после записи, живут 7 дней.
create table public.tg_link_tokens (
  token      text primary key default encode(extensions.gen_random_bytes(12), 'hex'),
  patient_id bigint not null references public.patients(id) on delete cascade,
  created_at timestamptz not null default now(),
  used_at    timestamptz
);
alter table public.tg_link_tokens enable row level security;

-- ===== Напоминания и подтверждения =====
alter table public.appointments
  add column reminder_sent_at timestamptz,
  add column confirmed_at     timestamptz;
grant update (confirmed_at) on public.appointments to authenticated;   -- администратор может отметить подтверждение по телефону

-- Диалоги в Telegram храним там же, где диалоги с сайта
alter table public.chat_sessions
  add column channel    text not null default 'web' check (channel in ('web', 'telegram')),
  add column tg_chat_id bigint;
create unique index chat_sessions_one_per_tg_chat on public.chat_sessions (tg_chat_id) where channel = 'telegram';

-- ===== Выдать ссылку для подписки (вызывает Зоя после записи) =====
create or replace function public.create_tg_link(p_patient_id bigint) returns text
language sql set search_path = '' as $$
  insert into public.tg_link_tokens (patient_id) values (p_patient_id) returning token
$$;

-- ===== Использовать ссылку: привязать чат к пациенту =====
create or replace function public.use_tg_link(p_token text, p_chat_id bigint) returns json
language plpgsql set search_path = '' as $$
declare t record;
begin
  select * into t from public.tg_link_tokens where token = p_token for update;
  if not found then raise exception 'LINK_NOT_FOUND' using errcode = 'P0001'; end if;
  if t.used_at is not null then raise exception 'LINK_USED' using errcode = 'P0001'; end if;
  if t.created_at < now() - interval '7 days' then raise exception 'LINK_EXPIRED' using errcode = 'P0001'; end if;

  update public.patients set tg_chat_id = null where tg_chat_id = p_chat_id and id <> t.patient_id;  -- один чат — один пациент
  update public.patients set tg_chat_id = p_chat_id where id = t.patient_id;
  update public.tg_link_tokens set used_at = now() where token = p_token;
  return (select json_build_object('patient_id', id, 'name', full_name) from public.patients where id = t.patient_id);
end $$;

-- ===== Действия пациента из Telegram: только со СВОИМИ будущими записями =====
create or replace function public.patient_appointments(p_patient_id bigint)
returns table (appointment_id bigint, service_id smallint, service text, doctor text, date text, weekday text,
               start_time text, confirmed boolean)
language sql stable set search_path = '' as $$
  select a.id, sv.id, sv.name, d.full_name,
         to_char(s.starts_at at time zone 'Europe/Moscow', 'DD.MM.YYYY'),
         (array['пн','вт','ср','чт','пт','сб','вс'])[extract(isodow from s.starts_at at time zone 'Europe/Moscow')::int],
         to_char(s.starts_at at time zone 'Europe/Moscow', 'HH24:MI'),
         a.confirmed_at is not null
  from public.appointments a
  join public.slots s on s.id = a.slot_id
  join public.services sv on sv.id = a.service_id
  join public.doctors d on d.id = a.doctor_id
  where a.patient_id = p_patient_id and a.status = 'booked' and s.starts_at > now()
  order by s.starts_at
$$;

create or replace function public.patient_confirm_appointment(p_appointment_id bigint, p_patient_id bigint) returns json
language plpgsql set search_path = '' as $$
begin
  update public.appointments set confirmed_at = coalesce(confirmed_at, now())
  where id = p_appointment_id and patient_id = p_patient_id and status = 'booked';
  if not found then raise exception 'APPOINTMENT_NOT_FOUND' using errcode = 'P0001'; end if;
  return json_build_object('confirmed_appointment_id', p_appointment_id);
end $$;

create or replace function public.patient_cancel_appointment(p_appointment_id bigint, p_patient_id bigint) returns json
language plpgsql set search_path = '' as $$
declare a record;
begin
  select ap.*, s.starts_at into a from public.appointments ap join public.slots s on s.id = ap.slot_id
  where ap.id = p_appointment_id for update of ap;
  if not found or a.patient_id <> p_patient_id then raise exception 'APPOINTMENT_NOT_FOUND' using errcode = 'P0001'; end if;
  if a.status <> 'booked' then raise exception 'APPOINTMENT_NOT_ACTIVE' using errcode = 'P0001'; end if;
  if a.starts_at <= now() then raise exception 'APPOINTMENT_IN_PAST' using errcode = 'P0001'; end if;
  update public.appointments set status = 'cancelled' where id = p_appointment_id;
  return json_build_object('cancelled_appointment_id', p_appointment_id,
    'was', to_char(a.starts_at at time zone 'Europe/Moscow', 'DD.MM.YYYY HH24:MI'));
end $$;

create or replace function public.patient_reschedule_appointment(p_appointment_id bigint, p_new_slot_id bigint, p_patient_id bigint)
returns json language plpgsql set search_path = '' as $$
declare a record; v_doctor smallint; v_new_id bigint; r json;
begin
  select * into a from public.appointments where id = p_appointment_id for update;
  if not found or a.patient_id <> p_patient_id then raise exception 'APPOINTMENT_NOT_FOUND' using errcode = 'P0001'; end if;
  if a.status <> 'booked' then raise exception 'APPOINTMENT_NOT_ACTIVE' using errcode = 'P0001'; end if;
  if a.slot_id = p_new_slot_id then raise exception 'SAME_SLOT' using errcode = 'P0001'; end if;
  select doctor_id into v_doctor from public.slots where id = p_new_slot_id;
  if not found then raise exception 'SLOT_NOT_FOUND' using errcode = 'P0001'; end if;

  update public.appointments set status = 'cancelled' where id = p_appointment_id;
  insert into public.appointments (patient_id, doctor_id, service_id, slot_id, comment, source, session_id, confirmed_at)
  values (a.patient_id, v_doctor, a.service_id, p_new_slot_id,
          trim(coalesce(a.comment, '') || ' (перенесено с записи №' || a.id || ')'), a.source, a.session_id, now())
  returning id into v_new_id;

  select json_build_object('new_appointment_id', ap.id, 'service', sv.name, 'doctor', d.full_name,
           'starts_at', to_char(s.starts_at at time zone 'Europe/Moscow', 'DD.MM.YYYY HH24:MI'))
  into r from public.appointments ap join public.slots s on s.id = ap.slot_id
  join public.services sv on sv.id = ap.service_id join public.doctors d on d.id = ap.doctor_id where ap.id = v_new_id;
  return r;
end $$;

-- ===== Кому завтра напомнить =====
create or replace function public.appointments_to_remind()
returns table (appointment_id bigint, tg_chat_id bigint, patient text, service text, doctor text, weekday text, date text, start_time text)
language sql stable set search_path = '' as $$
  select a.id, p.tg_chat_id, p.full_name, sv.name, d.full_name,
         to_char(s.starts_at at time zone 'Europe/Moscow', 'TMDay'),
         to_char(s.starts_at at time zone 'Europe/Moscow', 'DD.MM'),
         to_char(s.starts_at at time zone 'Europe/Moscow', 'HH24:MI')
  from public.appointments a
  join public.patients p on p.id = a.patient_id
  join public.slots s on s.id = a.slot_id
  join public.services sv on sv.id = a.service_id
  join public.doctors d on d.id = a.doctor_id
  where a.status = 'booked' and a.reminder_sent_at is null and p.tg_chat_id is not null
    and (s.starts_at at time zone 'Europe/Moscow')::date = (now() at time zone 'Europe/Moscow')::date + 1
$$;

-- Всё это вызывает только сервер
do $$ declare f text; begin
  foreach f in array array[
    'public.create_tg_link(bigint)', 'public.use_tg_link(text, bigint)', 'public.patient_appointments(bigint)',
    'public.patient_confirm_appointment(bigint, bigint)', 'public.patient_cancel_appointment(bigint, bigint)',
    'public.patient_reschedule_appointment(bigint, bigint, bigint)', 'public.appointments_to_remind()'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
revoke insert, update, delete on public.tg_link_tokens from anon, authenticated;
