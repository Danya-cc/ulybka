-- Запуск рассылки: база сама вызывает функцию бота с секретным ключом
create or replace function public.trigger_send_reminders() returns bigint
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := 'https://jeaqmrzudzaazhzrnnzh.supabase.co/functions/v1/telegram-bot',
    body := '{"action":"send_reminders"}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select value from public.app_settings where key = 'cron_secret')),
    timeout_milliseconds := 60000
  )
$$;
revoke execute on function public.trigger_send_reminders() from public, anon, authenticated;

-- Каждый день в 12:00 по Москве (09:00 UTC) — напоминания о завтрашних приёмах
select cron.schedule('send-reminders-daily', '0 9 * * *', $$select public.trigger_send_reminders()$$);
