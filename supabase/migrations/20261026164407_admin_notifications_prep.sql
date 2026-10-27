create extension if not exists pg_net;

-- Настройки приложения (например, id Telegram-чата администратора). Из браузера недоступны.
create table public.app_settings (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);
alter table public.app_settings enable row level security;

-- Отметки, чтобы одно событие не уведомляло дважды
alter table public.appointments add column notified_at timestamptz, add column cancel_notified_at timestamptz;
alter table public.leads add column notified_at timestamptz;
