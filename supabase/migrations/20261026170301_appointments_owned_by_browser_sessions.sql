drop function public.reschedule_appointment(bigint, bigint, uuid);
drop function public.cancel_appointment(bigint, uuid);
drop function public.get_session_appointments(uuid);

-- Записи, сделанные в любом из диалогов этого браузера (только будущие и активные)
create function public.get_session_appointments(p_session_ids uuid[])
returns table (appointment_id bigint, service_id smallint, service text, doctor_id smallint, doctor text,
               date text, weekday text, start_time text, patient text, phone text)
language sql stable set search_path = '' as $$
  select a.id, sv.id, sv.name, d.id, d.full_name,
         to_char(s.starts_at at time zone 'Europe/Moscow', 'DD.MM.YYYY'),
         (array['пн','вт','ср','чт','пт','сб','вс'])[extract(isodow from s.starts_at at time zone 'Europe/Moscow')::int],
         to_char(s.starts_at at time zone 'Europe/Moscow', 'HH24:MI'),
         p.full_name, p.phone
  from public.appointments a
  join public.slots s on s.id = a.slot_id
  join public.services sv on sv.id = a.service_id
  join public.doctors d on d.id = a.doctor_id
  join public.patients p on p.id = a.patient_id
  where a.session_id = any(p_session_ids) and a.status = 'booked' and s.starts_at > now()
  order by s.starts_at
$$;

create function public.cancel_appointment(p_appointment_id bigint, p_session_ids uuid[])
returns json language plpgsql set search_path = '' as $$
declare a record;
begin
  select ap.*, s.starts_at into a
  from public.appointments ap join public.slots s on s.id = ap.slot_id
  where ap.id = p_appointment_id for update of ap;
  if not found or a.session_id is null or not (a.session_id = any(p_session_ids)) then
    raise exception 'APPOINTMENT_NOT_IN_THIS_CHAT' using errcode = 'P0001';
  end if;
  if a.status <> 'booked' then raise exception 'APPOINTMENT_NOT_ACTIVE' using errcode = 'P0001'; end if;
  if a.starts_at <= now() then raise exception 'APPOINTMENT_IN_PAST' using errcode = 'P0001'; end if;

  update public.appointments set status = 'cancelled' where id = p_appointment_id;
  return json_build_object('cancelled_appointment_id', p_appointment_id,
    'was', to_char(a.starts_at at time zone 'Europe/Moscow', 'DD.MM.YYYY HH24:MI'));
end $$;

create function public.reschedule_appointment(p_appointment_id bigint, p_new_slot_id bigint, p_session_ids uuid[])
returns json language plpgsql set search_path = '' as $$
declare a record; v_doctor smallint; v_new_id bigint; r json;
begin
  select * into a from public.appointments where id = p_appointment_id for update;
  if not found or a.session_id is null or not (a.session_id = any(p_session_ids)) then
    raise exception 'APPOINTMENT_NOT_IN_THIS_CHAT' using errcode = 'P0001';
  end if;
  if a.status <> 'booked' then raise exception 'APPOINTMENT_NOT_ACTIVE' using errcode = 'P0001'; end if;
  if a.slot_id = p_new_slot_id then raise exception 'SAME_SLOT' using errcode = 'P0001'; end if;

  select doctor_id into v_doctor from public.slots where id = p_new_slot_id;
  if not found then raise exception 'SLOT_NOT_FOUND' using errcode = 'P0001'; end if;

  perform public.cancel_appointment(p_appointment_id, p_session_ids);

  insert into public.appointments (patient_id, doctor_id, service_id, slot_id, comment, source, session_id)
  values (a.patient_id, v_doctor, a.service_id, p_new_slot_id,
          trim(coalesce(a.comment, '') || ' (перенесено с записи №' || a.id || ')'), a.source, a.session_id)
  returning id into v_new_id;

  select json_build_object('new_appointment_id', ap.id, 'service', sv.name, 'doctor', d.full_name,
           'starts_at', to_char(s.starts_at at time zone 'Europe/Moscow', 'DD.MM.YYYY HH24:MI'))
  into r
  from public.appointments ap join public.slots s on s.id = ap.slot_id
  join public.services sv on sv.id = ap.service_id join public.doctors d on d.id = ap.doctor_id
  where ap.id = v_new_id;
  return r;
end $$;

revoke execute on function public.get_session_appointments(uuid[]) from public, anon, authenticated;
revoke execute on function public.cancel_appointment(bigint, uuid[]) from public, anon, authenticated;
revoke execute on function public.reschedule_appointment(bigint, bigint, uuid[]) from public, anon, authenticated;
grant execute on function public.get_session_appointments(uuid[]) to service_role;
grant execute on function public.cancel_appointment(bigint, uuid[]) to service_role;
grant execute on function public.reschedule_appointment(bigint, bigint, uuid[]) to service_role;
