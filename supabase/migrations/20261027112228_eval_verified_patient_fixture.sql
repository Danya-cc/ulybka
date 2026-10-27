-- Автотесты памяти: подтверждённый тестовый пациент без настоящего Telegram

create or replace function public.eval_verified_session() returns json
language plpgsql security definer set search_path = '' as $$
declare v_patient bigint; v_session uuid;
begin
  insert into public.patients (full_name, phone) values ('Тест Памятин', '79990000099')
  on conflict (phone) do update set full_name = excluded.full_name
  returning id into v_patient;
  delete from public.patient_notes where patient_id = v_patient;
  insert into public.patient_notes (patient_id, kind, value) values (v_patient, 'preferred_time', 'только после 18:00');

  insert into public.chat_sessions (verified_patient_id, verified_at) values (v_patient, now()) returning id into v_session;
  -- метка в журнале: диалог тестовый (не уведомляет владельца и убирается после прогона)
  insert into public.ai_calls (agent, session_id, round, model, is_eval) values ('evals', v_session, -1, 'fixture', true);
  return json_build_object('session_id', v_session, 'patient_id', v_patient);
end $$;
revoke all on function public.eval_verified_session() from public, anon, authenticated;

-- Уборка дополнительно удаляет тестового пациента памяти (заметки удаляются каскадом)
create or replace function public.cleanup_eval_data() returns json
language plpgsql security definer set search_path = '' as $$
declare v_sessions uuid[]; v_patients bigint[]; n_appt int; n_leads int; n_pat int;
begin
  select coalesce(array_agg(distinct session_id), '{}') into v_sessions from public.ai_calls where is_eval and session_id is not null;
  select coalesce(array_agg(distinct patient_id), '{}') into v_patients from public.appointments where session_id = any(v_sessions);
  v_patients := v_patients || coalesce((select array_agg(id) from public.patients where phone = '79990000099'), '{}');

  update public.appointments set status = 'cancelled', cancel_notified_at = now()
   where session_id = any(v_sessions) and status = 'booked';
  delete from public.appointments where session_id = any(v_sessions);
  get diagnostics n_appt = row_count;
  delete from public.leads where session_id = any(v_sessions);
  get diagnostics n_leads = row_count;
  update public.chat_sessions set verified_patient_id = null where id = any(v_sessions);
  delete from public.patients p
   where p.id = any(v_patients) and not exists (select 1 from public.appointments a where a.patient_id = p.id);
  get diagnostics n_pat = row_count;
  return json_build_object('appointments', n_appt, 'leads', n_leads, 'patients', n_pat);
end $$;
revoke all on function public.cleanup_eval_data() from public, anon, authenticated;
