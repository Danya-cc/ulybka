-- ===== 6. Единый формат телефона: только цифры, 8XXXXXXXXXX -> 7XXXXXXXXXX =====
create or replace function public.normalize_phone(p text) returns text
language sql immutable set search_path = '' as $$
  select case
    when d ~ '^8[0-9]{10}$' then '7' || substr(d, 2)
    when d ~ '^9[0-9]{9}$'  then '7' || d
    else d end
  from (select regexp_replace(coalesce(p,''), '\D', '', 'g') as d) x
$$;

create or replace function public.tg_normalize_phone() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.phone := public.normalize_phone(new.phone);
  return new;
end $$;

create trigger patients_normalize_phone before insert or update of phone on public.patients
  for each row execute function public.tg_normalize_phone();
create trigger leads_normalize_phone before insert or update of phone on public.leads
  for each row execute function public.tg_normalize_phone();

alter table public.patients add constraint patients_phone_format check (phone ~ '^[0-9]{10,15}$');
alter table public.leads    add constraint leads_phone_format    check (phone ~ '^[0-9]{10,15}$');

-- ===== 8. Откуда запись и когда менялась =====
alter table public.appointments
  add column source text not null default 'chat' check (source in ('chat','admin','phone')),
  add column session_id uuid references public.chat_sessions(id),
  add column updated_at timestamptz not null default now();

-- ===== 2. Один слот — одна АКТИВНАЯ запись (отменённые не мешают) =====
alter table public.appointments drop constraint appointments_slot_id_key;
create unique index appointments_one_active_per_slot on public.appointments (slot_id) where status = 'booked';
create index appointments_patient_idx on public.appointments (patient_id);

-- ===== 1, 4, 5. Проверки при создании записи + занятие слота в той же транзакции =====
create or replace function public.tg_appointment_before_insert() returns trigger
language plpgsql set search_path = '' as $$
declare s record;
begin
  if not exists (select 1 from public.doctor_services
                 where doctor_id = new.doctor_id and service_id = new.service_id) then
    raise exception 'DOCTOR_DOES_NOT_PROVIDE_SERVICE' using errcode = 'P0001';
  end if;

  -- блокируем строку слота: второй одновременный запрос будет ждать, а потом увидит, что слот занят
  select * into s from public.slots where id = new.slot_id for update;
  if not found then raise exception 'SLOT_NOT_FOUND' using errcode = 'P0001'; end if;
  if s.doctor_id <> new.doctor_id then raise exception 'SLOT_BELONGS_TO_OTHER_DOCTOR' using errcode = 'P0001'; end if;
  if s.starts_at <= now() then raise exception 'SLOT_IN_PAST' using errcode = 'P0001'; end if;
  if s.is_booked then raise exception 'SLOT_TAKEN' using errcode = 'P0001'; end if;

  update public.slots set is_booked = true where id = new.slot_id;
  new.status := 'booked';
  return new;
end $$;

create trigger appointments_before_insert before insert on public.appointments
  for each row execute function public.tg_appointment_before_insert();

-- ===== 3. Отмена освобождает слот =====
create or replace function public.tg_appointment_status_change() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  if old.status = 'booked' and new.status = 'cancelled' then
    update public.slots set is_booked = false where id = new.slot_id;
  elsif old.status = 'cancelled' and new.status = 'booked' then
    raise exception 'USE_NEW_APPOINTMENT_INSTEAD' using errcode = 'P0001';
  end if;
  return new;
end $$;

create trigger appointments_status_change before update on public.appointments
  for each row execute function public.tg_appointment_status_change();

-- ===== Функция записи для Зои: всё за один вызов, всё или ничего =====
create or replace function public.book_appointment(
  p_slot_id bigint, p_service_id smallint, p_full_name text, p_phone text,
  p_session_id uuid default null, p_comment text default null, p_source text default 'chat'
) returns json
language plpgsql set search_path = '' as $$
declare v_patient_id bigint; v_doctor_id smallint; v_appt_id bigint; r json;
begin
  if char_length(trim(coalesce(p_full_name,''))) not between 1 and 100 then
    raise exception 'INVALID_NAME' using errcode = 'P0001';
  end if;
  if public.normalize_phone(p_phone) !~ '^[0-9]{10,15}$' then
    raise exception 'INVALID_PHONE' using errcode = 'P0001';
  end if;

  select doctor_id into v_doctor_id from public.slots where id = p_slot_id;
  if not found then raise exception 'SLOT_NOT_FOUND' using errcode = 'P0001'; end if;

  insert into public.patients (full_name, phone) values (trim(p_full_name), p_phone)
  on conflict (phone) do update set full_name = excluded.full_name
  returning id into v_patient_id;

  insert into public.appointments (patient_id, doctor_id, service_id, slot_id, comment, source, session_id)
  values (v_patient_id, v_doctor_id, p_service_id, p_slot_id, p_comment, p_source, p_session_id)
  returning id into v_appt_id;

  select json_build_object(
    'appointment_id', a.id,
    'service', sv.name,
    'doctor', d.full_name,
    'starts_at', to_char(s.starts_at at time zone 'Europe/Moscow', 'DD.MM.YYYY HH24:MI'),
    'patient', p.full_name,
    'phone', p.phone
  ) into r
  from public.appointments a
  join public.slots s on s.id = a.slot_id
  join public.services sv on sv.id = a.service_id
  join public.doctors d on d.id = a.doctor_id
  join public.patients p on p.id = a.patient_id
  where a.id = v_appt_id;
  return r;
end $$;

-- ===== Поиск свободного времени для Зои =====
create or replace function public.get_free_slots(
  p_service_id smallint, p_date_from date, p_date_to date,
  p_doctor_id smallint default null, p_after time default null, p_before time default null,
  p_limit int default 10
) returns table (slot_id bigint, doctor_id smallint, doctor text, specialty text, date text, weekday text, start_time text)
language sql stable set search_path = '' as $$
  select s.id, d.id, d.full_name, d.specialty,
         to_char(s.starts_at at time zone 'Europe/Moscow', 'DD.MM.YYYY'),
         (array['пн','вт','ср','чт','пт','сб','вс'])[extract(isodow from s.starts_at at time zone 'Europe/Moscow')::int],
         to_char(s.starts_at at time zone 'Europe/Moscow', 'HH24:MI')
  from public.slots s
  join public.doctors d on d.id = s.doctor_id and d.is_active
  join public.doctor_services ds on ds.doctor_id = s.doctor_id and ds.service_id = p_service_id
  where not s.is_booked
    and s.starts_at > now() + interval '1 hour'           -- не предлагаем время, на которое уже не успеть
    and (s.starts_at at time zone 'Europe/Moscow')::date between p_date_from and least(p_date_to, p_date_from + 30)
    and (p_doctor_id is null or s.doctor_id = p_doctor_id)
    and (p_after  is null or (s.starts_at at time zone 'Europe/Moscow')::time >= p_after)
    and (p_before is null or (s.starts_at at time zone 'Europe/Moscow')::time <  p_before)
  order by s.starts_at, d.id
  limit least(greatest(p_limit, 1), 30)
$$;

-- ===== 7. Рабочий график врачей и автоматическое продление расписания =====
create table public.doctor_schedule (
  doctor_id  smallint not null references public.doctors(id) on delete cascade,
  isodow     smallint not null check (isodow between 1 and 7),   -- 1 = пн ... 7 = вс
  start_hour smallint not null check (start_hour between 0 and 23),
  end_hour   smallint not null check (end_hour between 1 and 24), -- последний приём начинается в end_hour - 1
  primary key (doctor_id, isodow),
  check (end_hour > start_hour)
);
alter table public.doctor_schedule enable row level security;

insert into public.doctor_schedule (doctor_id, isodow, start_hour, end_hour)
select d.id, dow, 9, 21 from public.doctors d
cross join generate_series(1,7) dow
where (d.full_name = 'Анна Иванова'   and dow between 1 and 5)
   or (d.full_name = 'Дмитрий Петров' and dow in (2,4,6))
   or (d.full_name = 'Елена Смирнова' and dow in (1,3,5,6));

create or replace function public.generate_slots(p_days_ahead int default 14) returns int
language plpgsql set search_path = '' as $$
declare n int;
begin
  insert into public.slots (doctor_id, starts_at, ends_at)
  select ds.doctor_id,
         (day::date + make_interval(hours => h)) at time zone 'Europe/Moscow',
         (day::date + make_interval(hours => h + 1)) at time zone 'Europe/Moscow'
  from generate_series((now() at time zone 'Europe/Moscow')::date,
                       (now() at time zone 'Europe/Moscow')::date + p_days_ahead, interval '1 day') day
  join public.doctor_schedule ds on ds.isodow = extract(isodow from day)
  cross join lateral generate_series(ds.start_hour, ds.end_hour - 1) h
  join public.doctors d on d.id = ds.doctor_id and d.is_active
  on conflict (doctor_id, starts_at) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- ===== Функции вызывает только сервер (Edge Function), не браузер =====
revoke execute on function public.book_appointment(bigint, smallint, text, text, uuid, text, text) from public, anon, authenticated;
revoke execute on function public.get_free_slots(smallint, date, date, smallint, time, time, int) from public, anon, authenticated;
revoke execute on function public.generate_slots(int) from public, anon, authenticated;
grant execute on function public.book_appointment(bigint, smallint, text, text, uuid, text, text) to service_role;
grant execute on function public.get_free_slots(smallint, date, date, smallint, time, time, int) to service_role;
grant execute on function public.generate_slots(int) to service_role;
