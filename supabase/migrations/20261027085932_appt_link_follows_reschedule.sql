-- После переноса ссылка из напоминания ведёт на новую запись
create or replace function public.appt_by_token(p_token text)
returns json language plpgsql stable set search_path = '' as $$
declare l record; v_id bigint; v_next bigint; v_moved boolean := false; r json;
begin
  select * into l from public.appt_links where token = p_token;
  if not found then raise exception 'LINK_NOT_FOUND' using errcode = 'P0001'; end if;
  if l.expires_at <= now() then raise exception 'LINK_EXPIRED' using errcode = 'P0001'; end if;

  v_id := l.appointment_id;
  for i in 1..10 loop
    select a.id into v_next from public.appointments a
     where a.patient_id = l.patient_id
       and a.comment like '%(перенесено с записи №' || v_id || ')%'
     order by a.id desc limit 1;
    exit when v_next is null;
    v_id := v_next; v_moved := true; v_next := null;
  end loop;

  select json_build_object(
    'appointment_id', a.id, 'patient_id', a.patient_id,
    'first_name', split_part(p.full_name, ' ', 1),
    'service', sv.name, 'doctor', d.full_name, 'specialty', d.specialty,
    'date', to_char(s.starts_at at time zone 'Europe/Moscow', 'DD.MM.YYYY'),
    'weekday', (array['понедельник','вторник','среда','четверг','пятница','суббота','воскресенье'])[extract(isodow from s.starts_at at time zone 'Europe/Moscow')::int],
    'start_time', to_char(s.starts_at at time zone 'Europe/Moscow', 'HH24:MI'),
    'status', a.status, 'confirmed', a.confirmed_at is not null, 'in_past', s.starts_at <= now(),
    'moved', v_moved
  ) into r
  from public.appointments a
  join public.patients p on p.id = a.patient_id
  join public.slots s on s.id = a.slot_id
  join public.services sv on sv.id = a.service_id
  join public.doctors d on d.id = a.doctor_id
  where a.id = v_id;
  return r;
end $$;
revoke all on function public.appt_by_token(text) from public, anon, authenticated;
