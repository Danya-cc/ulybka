create or replace function public.appointments_to_remind()
returns table (appointment_id bigint, tg_chat_id bigint, patient text, service text, doctor text, weekday text, date text, start_time text)
language sql stable set search_path = '' as $$
  select a.id, p.tg_chat_id, p.full_name, sv.name, d.full_name,
         (array['понедельник','вторник','среда','четверг','пятница','суббота','воскресенье'])[extract(isodow from s.starts_at at time zone 'Europe/Moscow')::int],
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
revoke execute on function public.appointments_to_remind() from public, anon, authenticated;
grant execute on function public.appointments_to_remind() to service_role;
