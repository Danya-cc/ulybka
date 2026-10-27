-- Личные ссылки на запись: приходят в напоминании Лиды и открывают страницу записи на сайте
create table public.appt_links (
  token text primary key default encode(extensions.gen_random_bytes(12), 'hex'),
  appointment_id bigint not null references public.appointments(id) on delete cascade,
  patient_id bigint not null references public.patients(id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index appt_links_appointment_idx on public.appt_links(appointment_id);
alter table public.appt_links enable row level security; -- политик нет: доступ только у сервера

-- Ссылка живёт до конца следующего дня после приёма
create or replace function public.create_appt_link(p_appointment_id bigint)
returns text language plpgsql set search_path = '' as $$
declare v_token text; v_patient bigint; v_start timestamptz;
begin
  select l.token into v_token from public.appt_links l
   where l.appointment_id = p_appointment_id and l.expires_at > now() limit 1;
  if v_token is not null then return v_token; end if;
  select a.patient_id, s.starts_at into v_patient, v_start
    from public.appointments a join public.slots s on s.id = a.slot_id where a.id = p_appointment_id;
  if not found then raise exception 'APPOINTMENT_NOT_FOUND' using errcode = 'P0001'; end if;
  insert into public.appt_links (appointment_id, patient_id, expires_at)
  values (p_appointment_id, v_patient, v_start + interval '1 day') returning token into v_token;
  return v_token;
end $$;

create or replace function public.appt_by_token(p_token text)
returns json language plpgsql stable set search_path = '' as $$
declare l record; r json;
begin
  select * into l from public.appt_links where token = p_token;
  if not found then raise exception 'LINK_NOT_FOUND' using errcode = 'P0001'; end if;
  if l.expires_at <= now() then raise exception 'LINK_EXPIRED' using errcode = 'P0001'; end if;
  select json_build_object(
    'appointment_id', a.id, 'patient_id', a.patient_id,
    'first_name', split_part(p.full_name, ' ', 1),
    'service', sv.name, 'doctor', d.full_name, 'specialty', d.specialty,
    'date', to_char(s.starts_at at time zone 'Europe/Moscow', 'DD.MM.YYYY'),
    'weekday', (array['понедельник','вторник','среда','четверг','пятница','суббота','воскресенье'])[extract(isodow from s.starts_at at time zone 'Europe/Moscow')::int],
    'start_time', to_char(s.starts_at at time zone 'Europe/Moscow', 'HH24:MI'),
    'status', a.status, 'confirmed', a.confirmed_at is not null, 'in_past', s.starts_at <= now()
  ) into r
  from public.appointments a
  join public.patients p on p.id = a.patient_id
  join public.slots s on s.id = a.slot_id
  join public.services sv on sv.id = a.service_id
  join public.doctors d on d.id = a.doctor_id
  where a.id = l.appointment_id;
  return r;
end $$;

revoke all on function public.create_appt_link(bigint) from public, anon, authenticated;
revoke all on function public.appt_by_token(text) from public, anon, authenticated;
revoke all on table public.appt_links from anon, authenticated;
