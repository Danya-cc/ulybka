-- Нормализация: +7/8/7 + 10 цифр, или просто 10 цифр с кодом на 3/4/8/9 -> 7XXXXXXXXXX
create or replace function public.normalize_phone(p text) returns text
language sql immutable set search_path = '' as $$
  select case
    when d ~ '^[78][0-9]{10}$'   then '7' || substr(d, 2)
    when d ~ '^[3489][0-9]{9}$'  then '7' || d
    else d end
  from (select regexp_replace(coalesce(p,''), '\D', '', 'g') as d) x
$$;

-- Валидный номер: российский, 7 + код (3xx, 4xx, 8xx, 9xx) + 7 цифр
create or replace function public.is_valid_phone(p text) returns boolean
language sql immutable set search_path = '' as $$
  select public.normalize_phone(p) ~ '^7[3489][0-9]{9}$'
$$;

-- Новые правила для новых строк. NOT VALID — старые тестовые записи не трогаем
alter table public.patients drop constraint patients_phone_format;
alter table public.leads    drop constraint leads_phone_format;
alter table public.patients add constraint patients_phone_format check (phone ~ '^7[3489][0-9]{9}$') not valid;
alter table public.leads    add constraint leads_phone_format    check (phone ~ '^7[3489][0-9]{9}$') not valid;

-- Форма на сайте: та же проверка
drop policy "site can submit form leads" on public.leads;
create policy "site can submit form leads" on public.leads
  for insert to anon, authenticated
  with check (
    source = 'form' and status = 'new' and session_id is null
    and char_length(name) between 1 and 100
    and phone ~ '^7[3489][0-9]{9}$'
    and (comment is null or char_length(comment) <= 500)
  );

-- Функция записи: понятная ошибка ещё до попытки вставки
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
  if not public.is_valid_phone(p_phone) then
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
    'appointment_id', a.id, 'service', sv.name, 'doctor', d.full_name,
    'starts_at', to_char(s.starts_at at time zone 'Europe/Moscow', 'DD.MM.YYYY HH24:MI'),
    'patient', p.full_name, 'phone', p.phone
  ) into r
  from public.appointments a
  join public.slots s on s.id = a.slot_id
  join public.services sv on sv.id = a.service_id
  join public.doctors d on d.id = a.doctor_id
  join public.patients p on p.id = a.patient_id
  where a.id = v_appt_id;
  return r;
end $$;

revoke execute on function public.book_appointment(bigint, smallint, text, text, uuid, text, text) from public, anon, authenticated;
grant execute on function public.book_appointment(bigint, smallint, text, text, uuid, text, text) to service_role;
