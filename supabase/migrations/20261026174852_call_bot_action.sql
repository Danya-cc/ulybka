-- Служебные действия бота (рассылка, профиль) вызываются только из базы, с секретным ключом
create or replace function public.call_bot_action(p_action text) returns bigint
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := 'https://jeaqmrzudzaazhzrnnzh.supabase.co/functions/v1/telegram-bot',
    body := jsonb_build_object('action', p_action),
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select value from public.app_settings where key = 'cron_secret')),
    timeout_milliseconds := 60000
  )
$$;
revoke execute on function public.call_bot_action(text) from public, anon, authenticated;
