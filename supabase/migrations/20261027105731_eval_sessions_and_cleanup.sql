-- Тестовые диалоги: всё, что сделано в диалоге автотестов, не уведомляет владельца и убирается после прогона

-- Диалог считается тестовым, если в журнале есть хоть один вызов с пометкой is_eval
create or replace function public.is_eval_session(p_session_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_session_id is not null and exists (select 1 from public.ai_calls where session_id = p_session_id and is_eval)
$$;
revoke all on function public.is_eval_session(uuid) from public, anon, authenticated;

-- Уборка после прогона: снимаем тестовые записи (слоты освобождаются), удаляем заявки и тестовых пациентов.
-- Переписка и журнал остаются — по ним видно, как прошёл прогон (в админке: «показывать автотесты»).
create or replace function public.cleanup_eval_data() returns json
language plpgsql security definer set search_path = '' as $$
declare v_sessions uuid[]; v_patients bigint[]; n_appt int; n_leads int; n_pat int;
begin
  select coalesce(array_agg(distinct session_id), '{}') into v_sessions from public.ai_calls where is_eval and session_id is not null;
  select coalesce(array_agg(distinct patient_id), '{}') into v_patients from public.appointments where session_id = any(v_sessions);

  update public.appointments set status = 'cancelled', cancel_notified_at = now()
   where session_id = any(v_sessions) and status = 'booked';           -- триггер освободит слоты
  delete from public.appointments where session_id = any(v_sessions);
  get diagnostics n_appt = row_count;
  delete from public.leads where session_id = any(v_sessions);
  get diagnostics n_leads = row_count;
  delete from public.patients p
   where p.id = any(v_patients) and not exists (select 1 from public.appointments a where a.patient_id = p.id);
  get diagnostics n_pat = row_count;
  return json_build_object('appointments', n_appt, 'leads', n_leads, 'patients', n_pat);
end $$;
revoke all on function public.cleanup_eval_data() from public, anon, authenticated;
