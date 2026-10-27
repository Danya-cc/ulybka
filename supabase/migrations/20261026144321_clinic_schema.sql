-- Врачи
create table public.doctors (
  id               smallint generated always as identity primary key,
  full_name        text not null,
  specialty        text not null,
  experience_years smallint not null,
  description      text,
  is_active        boolean not null default true
);

-- Услуги и цены
create table public.services (
  id           smallint generated always as identity primary key,
  name         text not null unique,
  description  text,
  price        integer not null check (price >= 0),
  price_is_from boolean not null default false,   -- true = "от 4 500 ₽"
  duration_min smallint not null
);

-- Какой врач какие услуги оказывает
create table public.doctor_services (
  doctor_id  smallint references public.doctors(id) on delete cascade,
  service_id smallint references public.services(id) on delete cascade,
  primary key (doctor_id, service_id)
);

-- Расписание: окна приёма врачей
create table public.slots (
  id        bigint generated always as identity primary key,
  doctor_id smallint not null references public.doctors(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at   timestamptz not null,
  is_booked boolean not null default false,
  unique (doctor_id, starts_at)
);
create index slots_free_idx on public.slots (starts_at) where not is_booked;

-- Пациенты
create table public.patients (
  id         bigint generated always as identity primary key,
  full_name  text not null,
  phone      text not null unique,
  created_at timestamptz not null default now()
);

-- Записи на приём
create table public.appointments (
  id         bigint generated always as identity primary key,
  patient_id bigint not null references public.patients(id),
  doctor_id  smallint not null references public.doctors(id),
  service_id smallint not null references public.services(id),
  slot_id    bigint not null unique references public.slots(id),
  status     text not null default 'booked' check (status in ('booked','cancelled','done')),
  comment    text,
  created_at timestamptz not null default now()
);

-- Диалоги в чате на сайте
create table public.chat_sessions (
  id         uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now()
);

create table public.messages (
  id         bigint generated always as identity primary key,
  session_id uuid not null references public.chat_sessions(id) on delete cascade,
  role       text not null check (role in ('user','assistant')),
  content    jsonb not null,           -- храним в формате Claude API (текст и вызовы инструментов)
  created_at timestamptz not null default now()
);
create index messages_session_idx on public.messages (session_id, id);

-- Заявки (из формы "Перезвоним вам" и из чата)
create table public.leads (
  id         bigint generated always as identity primary key,
  name       text not null,
  phone      text not null,
  source     text not null check (source in ('form','chat')),
  comment    text,
  session_id uuid references public.chat_sessions(id),
  status     text not null default 'new' check (status in ('new','in_progress','done')),
  created_at timestamptz not null default now()
);

-- Безопасность: из браузера по умолчанию ничего нельзя.
-- Edge Function работает со служебным ключом и видит всё.
alter table public.doctors         enable row level security;
alter table public.services        enable row level security;
alter table public.doctor_services enable row level security;
alter table public.slots           enable row level security;
alter table public.patients        enable row level security;
alter table public.appointments    enable row level security;
alter table public.chat_sessions   enable row level security;
alter table public.messages        enable row level security;
alter table public.leads           enable row level security;

-- Публично можно только читать врачей и услуги (это и так есть на сайте)
create policy "public read doctors"  on public.doctors  for select to anon, authenticated using (is_active);
create policy "public read services" on public.services for select to anon, authenticated using (true);
create policy "public read doctor_services" on public.doctor_services for select to anon, authenticated using (true);
