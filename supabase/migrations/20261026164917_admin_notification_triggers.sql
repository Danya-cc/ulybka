-- При новой записи, отмене или заявке база сама вызывает функцию notify-admin.
-- pg_net отправляет запрос асинхронно, уже после сохранения: запись пациента не ждёт Telegram
-- и не сломается, если Telegram недоступен.
create or replace function public.tg_notify_admin() returns trigger
language plpgsql security definer set search_path = '' as $$
declare t text;
begin
  if tg_table_name = 'appointments' then
    if tg_op = 'INSERT' then t := 'appointment_created';
    elsif old.status = 'booked' and new.status = 'cancelled' then t := 'appointment_cancelled';
    else return new;
    end if;
  else
    t := 'lead_created';
  end if;

  perform net.http_post(
    url := 'https://jeaqmrzudzaazhzrnnzh.supabase.co/functions/v1/notify-admin',
    body := jsonb_build_object('type', t, 'id', new.id),
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
  return new;
end $$;
revoke execute on function public.tg_notify_admin() from public, anon, authenticated;

create trigger appointments_notify_insert after insert on public.appointments
  for each row execute function public.tg_notify_admin();
create trigger appointments_notify_cancel after update of status on public.appointments
  for each row execute function public.tg_notify_admin();
create trigger leads_notify_insert after insert on public.leads
  for each row execute function public.tg_notify_admin();
