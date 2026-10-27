-- Память о пациенте и вход на сайт через Telegram.
-- Принцип: всё о пациенте хранится в базе и привязано к пациенту, а не к устройству.
-- Зоя видит это только в диалоге, где личность подтверждена через Telegram.

-- ===== 1. Подтверждённый пациент в диалоге =====
alter table public.chat_sessions
  add column verified_patient_id bigint references public.patients(id) on delete set null,
  add column verified_at timestamptz;

-- ===== 2. Запросы на вход через Telegram =====
create table public.tg_login_requests (
  token        text primary key default encode(extensions.gen_random_bytes(12), 'hex'),
  session_id   uuid not null references public.chat_sessions(id) on delete cascade,
  patient_id   bigint references public.patients(id) on delete cascade,  -- кто открыл ссылку в Telegram
  status       text not null default 'pending' check (status in ('pending','awaiting_confirm','confirmed','rejected','not_linked')),
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '10 minutes'
);
alter table public.tg_login_requests enable row level security;   -- политик нет: только сервер

-- Сайт: начать вход (создаётся одноразовый токен для ссылки t.me/<бот>?start=login_<токен>)
create or replace function public.tg_login_start(p_session_id uuid) returns text
language sql set search_path = '' as $$
  insert into public.tg_login_requests (session_id) values (p_session_id) returning token
$$;

-- Лида: человек открыл ссылку. Если его Telegram привязан к пациенту — просим подтвердить кнопкой.
create or replace function public.tg_login_attach(p_token text, p_chat_id bigint) returns json
language plpgsql set search_path = '' as $$
declare r public.tg_login_requests; v_patient public.patients;
begin
  select * into r from public.tg_login_requests where token = p_token for update;
  if not found or r.expires_at <= now() or r.status not in ('pending','awaiting_confirm') then
    return json_build_object('status', 'expired');
  end if;
  select * into v_patient from public.patients where tg_chat_id = p_chat_id;
  if not found then
    update public.tg_login_requests set status = 'not_linked' where token = p_token;
    return json_build_object('status', 'not_linked');
  end if;
  update public.tg_login_requests set status = 'awaiting_confirm', patient_id = v_patient.id where token = p_token;
  return json_build_object('status', 'awaiting_confirm', 'name', v_patient.full_name);
end $$;

-- Лида: ответ на «Это вы входите?». Подтверждает только тот же Telegram, который открыл ссылку.
create or replace function public.tg_login_confirm(p_token text, p_chat_id bigint, p_yes boolean) returns json
language plpgsql set search_path = '' as $$
declare r public.tg_login_requests;
begin
  select l.* into r from public.tg_login_requests l
    join public.patients p on p.id = l.patient_id and p.tg_chat_id = p_chat_id
   where l.token = p_token for update of l;
  if not found or r.status <> 'awaiting_confirm' or r.expires_at <= now() then
    return json_build_object('status', 'expired');
  end if;
  if not p_yes then
    update public.tg_login_requests set status = 'rejected' where token = p_token;
    return json_build_object('status', 'rejected');
  end if;
  update public.tg_login_requests set status = 'confirmed' where token = p_token;
  update public.chat_sessions set verified_patient_id = r.patient_id, verified_at = now() where id = r.session_id;
  return json_build_object('status', 'confirmed');
end $$;

-- Сайт: статус входа (опрос каждые пару секунд)
create or replace function public.tg_login_status(p_session_id uuid, p_token text) returns json
language sql stable set search_path = '' as $$
  select coalesce((
    select json_build_object(
      'status', case when l.status in ('pending','awaiting_confirm') and l.expires_at <= now() then 'expired' else l.status end,
      'name', case when l.status = 'confirmed' then split_part(p.full_name, ' ', 1) end)
    from public.tg_login_requests l left join public.patients p on p.id = l.patient_id
    where l.token = p_token and l.session_id = p_session_id), json_build_object('status', 'expired'))
$$;

-- ===== 3. Память: только то, что пациент сказал сам, и только разрешённые типы =====
create table public.patient_notes (
  patient_id  bigint not null references public.patients(id) on delete cascade,
  kind        text not null check (kind in ('preferred_time', 'preferred_doctor', 'address_as', 'preferred_days')),
  value       text not null check (char_length(value) between 1 and 200),
  source      text not null default 'zoya' check (source in ('zoya', 'admin')),
  session_id  uuid references public.chat_sessions(id) on delete set null,
  updated_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '1 year',   -- срок хранения
  primary key (patient_id, kind)
);
alter table public.patient_notes enable row level security;
revoke all on public.patient_notes from anon, authenticated;
grant select, delete on public.patient_notes to authenticated;
create policy "staff read patient_notes"   on public.patient_notes for select to authenticated using (public.is_staff());
create policy "staff delete patient_notes" on public.patient_notes for delete to authenticated using (public.is_staff());

create or replace function public.remember_preference(p_patient_id bigint, p_kind text, p_value text, p_session_id uuid)
returns json language sql set search_path = '' as $$
  insert into public.patient_notes (patient_id, kind, value, session_id)
  values (p_patient_id, p_kind, trim(p_value), p_session_id)
  on conflict (patient_id, kind) do update
    set value = excluded.value, session_id = excluded.session_id, updated_at = now(), expires_at = now() + interval '1 year'
  returning json_build_object('saved', kind, 'value', value)
$$;

create or replace function public.forget_preferences(p_patient_id bigint) returns int
language plpgsql set search_path = '' as $$
declare n int;
begin
  delete from public.patient_notes where patient_id = p_patient_id;
  get diagnostics n = row_count;
  return n;
end $$;

-- ===== 4. Профиль пациента для Зои: история записей + сохранённые предпочтения =====
-- Здоровья здесь нет: только имя, визиты (услуга, врач, время) и то, что пациент попросил запомнить.
create or replace function public.patient_profile(p_patient_id bigint) returns json
language sql stable set search_path = '' as $$
  with a as (
    select ap.status, s.starts_at, sv.name service, d.full_name doctor,
           extract(hour from s.starts_at at time zone 'Europe/Moscow')::int h
    from public.appointments ap
    join public.slots s on s.id = ap.slot_id
    join public.services sv on sv.id = ap.service_id
    join public.doctors d on d.id = ap.doctor_id
    where ap.patient_id = p_patient_id and ap.status in ('booked', 'done')
  )
  select json_build_object(
    'name', p.full_name,
    'phone', p.phone,
    'visits_done', (select count(*) from a where status = 'done'),
    'last_visit', (select json_build_object('date', to_char(starts_at at time zone 'Europe/Moscow', 'DD.MM.YYYY'), 'service', service, 'doctor', doctor)
                   from a where status = 'done' order by starts_at desc limit 1),
    'usual_doctor', (select doctor from a group by doctor having count(*) >= 2 order by count(*) desc limit 1),
    'usual_time', (select case when avg(h) < 12 then 'утро' when avg(h) < 17 then 'день' else 'вечер' end from a having count(*) >= 2),
    'upcoming', (select coalesce(json_agg(json_build_object('date', to_char(starts_at at time zone 'Europe/Moscow', 'DD.MM.YYYY HH24:MI'),
                   'service', service, 'doctor', doctor) order by starts_at), '[]'::json) from a where status = 'booked' and starts_at > now()),
    'preferences', (select coalesce(json_object_agg(kind, value), '{}'::json) from public.patient_notes
                    where patient_id = p_patient_id and expires_at > now())
  )
  from public.patients p where p.id = p_patient_id
$$;

revoke all on function public.tg_login_start(uuid) from public, anon, authenticated;
revoke all on function public.tg_login_attach(text, bigint) from public, anon, authenticated;
revoke all on function public.tg_login_confirm(text, bigint, boolean) from public, anon, authenticated;
revoke all on function public.tg_login_status(uuid, text) from public, anon, authenticated;
revoke all on function public.remember_preference(bigint, text, text, uuid) from public, anon, authenticated;
revoke all on function public.forget_preferences(bigint) from public, anon, authenticated;
revoke all on function public.patient_profile(bigint) from public, anon, authenticated;
