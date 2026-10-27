-- ===== Сотрудники клиники: кто может входить в панель =====
create table public.staff (
  email      text primary key check (email = lower(email)),
  full_name  text,
  created_at timestamptz not null default now()
);
alter table public.staff enable row level security;   -- список сотрудников правится только в Supabase

-- Вошедший пользователь — сотрудник? (email из токена входа)
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.staff where email = lower(coalesce(auth.jwt() ->> 'email', '')))
$$;
revoke execute on function public.is_staff() from public, anon;
grant execute on function public.is_staff() to authenticated;

-- ===== Новый статус записи: пациент не пришёл =====
alter table public.appointments drop constraint appointments_status_check;
alter table public.appointments add constraint appointments_status_check
  check (status in ('booked', 'cancelled', 'done', 'no_show'));

-- ===== Что сотрудник может ЧИТАТЬ =====
create policy "staff read appointments"    on public.appointments    for select to authenticated using (public.is_staff());
create policy "staff read patients"        on public.patients        for select to authenticated using (public.is_staff());
create policy "staff read slots"           on public.slots           for select to authenticated using (public.is_staff());
create policy "staff read leads"           on public.leads           for select to authenticated using (public.is_staff());
create policy "staff read messages"        on public.messages        for select to authenticated using (public.is_staff());
create policy "staff read doctor_schedule" on public.doctor_schedule for select to authenticated using (public.is_staff());

-- ===== Что сотрудник может МЕНЯТЬ: только статус и комментарий =====
create policy "staff update appointments" on public.appointments for update to authenticated
  using (public.is_staff()) with check (public.is_staff());
create policy "staff update leads" on public.leads for update to authenticated
  using (public.is_staff()) with check (public.is_staff());

revoke update on public.appointments from anon, authenticated;
revoke update on public.leads        from anon, authenticated;
grant update (status, comment) on public.appointments to authenticated;
grant update (status, comment) on public.leads        to authenticated;

-- Вставлять и удалять напрямую из браузера нельзя никому: запись — только через функцию ниже
revoke insert, delete on public.appointments, public.patients, public.slots, public.messages,
  public.chat_sessions, public.doctor_schedule, public.staff, public.app_settings from anon, authenticated;
revoke delete on public.leads from anon, authenticated;

-- ===== Функции для панели (проверяют, что вызывает сотрудник) =====
create or replace function public.admin_get_free_slots(
  p_service_id smallint, p_date_from date, p_date_to date, p_doctor_id smallint default null
) returns table (slot_id bigint, doctor_id smallint, doctor text, specialty text, date text, weekday text, start_time text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'NOT_STAFF' using errcode = '42501'; end if;
  return query select * from public.get_free_slots(p_service_id, p_date_from, p_date_to, p_doctor_id, null, null, 30);
end $$;

create or replace function public.admin_book_appointment(
  p_slot_id bigint, p_service_id smallint, p_full_name text, p_phone text, p_comment text default null
) returns json
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'NOT_STAFF' using errcode = '42501'; end if;
  return public.book_appointment(p_slot_id, p_service_id, p_full_name, p_phone, null, p_comment, 'phone');
end $$;

revoke execute on function public.admin_get_free_slots(smallint, date, date, smallint) from public, anon;
revoke execute on function public.admin_book_appointment(bigint, smallint, text, text, text) from public, anon;
grant execute on function public.admin_get_free_slots(smallint, date, date, smallint) to authenticated;
grant execute on function public.admin_book_appointment(bigint, smallint, text, text, text) to authenticated;
