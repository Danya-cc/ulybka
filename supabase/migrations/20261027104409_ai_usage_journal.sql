-- Журнал ИИ: каждый вызов Claude с токенами и стоимостью

-- Цены моделей, $ за 1 млн токенов. Меняются здесь, а не в коде.
create table public.ai_prices (
  model                text primary key,
  input_per_mtok       numeric not null,
  output_per_mtok      numeric not null,
  cache_write_per_mtok numeric not null,
  cache_read_per_mtok  numeric not null,
  source               text,
  updated_at           timestamptz not null default now()
);
insert into public.ai_prices values
  ('claude-sonnet-5-5', 2, 10, 2.5, 0.1, 'platform.claude.com/docs/en/about-claude/pricing, 27.10.2026', now());

create table public.ai_calls (
  id                 bigint generated always as identity primary key,
  created_at         timestamptz not null default now(),
  agent              text not null,                 -- 'zoya' (позже — другие агенты)
  session_id         uuid references public.chat_sessions(id) on delete set null,
  round              smallint not null default 0,   -- номер шага цикла агента внутри одного ответа
  model              text not null,
  input_tokens       integer not null default 0,
  output_tokens      integer not null default 0,
  cache_write_tokens integer not null default 0,
  cache_read_tokens  integer not null default 0,
  cost_usd           numeric(12,6),                 -- считает триггер по ai_prices
  tools              text[] not null default '{}',  -- какие инструменты модель попросила вызвать
  stop_reason        text,
  duration_ms        integer,
  error              text,
  is_eval            boolean not null default false -- вызовы из автотестов не смешиваем с реальными
);
create index ai_calls_created_idx on public.ai_calls (created_at desc);
create index ai_calls_session_idx on public.ai_calls (session_id);

create or replace function public.tg_ai_call_cost() returns trigger
language plpgsql set search_path = '' as $$
declare p public.ai_prices;
begin
  select * into p from public.ai_prices where model = new.model;
  if found then
    new.cost_usd := round((new.input_tokens * p.input_per_mtok + new.output_tokens * p.output_per_mtok
      + new.cache_write_tokens * p.cache_write_per_mtok + new.cache_read_tokens * p.cache_read_per_mtok) / 1e6, 6);
  end if;
  return new;
end $$;
create trigger ai_calls_cost before insert on public.ai_calls for each row execute function public.tg_ai_call_cost();

alter table public.ai_prices enable row level security;
alter table public.ai_calls  enable row level security;
revoke all on public.ai_prices, public.ai_calls from anon, authenticated;
grant select on public.ai_prices, public.ai_calls to authenticated;
create policy "staff read ai_prices" on public.ai_prices for select to authenticated using (public.is_staff());
create policy "staff read ai_calls"  on public.ai_calls  for select to authenticated using (public.is_staff());

-- Сводка по дням (по Москве) для админки
create view public.ai_daily with (security_invoker = true) as
select (c.created_at at time zone 'Europe/Moscow')::date as day,
       c.is_eval,
       count(distinct c.session_id)            as dialogs,
       count(*) filter (where c.round = 0)     as replies,
       count(*)                                as calls,
       sum(c.input_tokens + c.cache_write_tokens + c.cache_read_tokens) as input_tokens,
       sum(c.output_tokens)                    as output_tokens,
       sum(c.cost_usd)                         as cost_usd,
       count(*) filter (where c.error is not null) as errors
from public.ai_calls c
group by 1, 2;

-- Диалоги со стоимостью для админки
create view public.ai_dialogs with (security_invoker = true) as
select c.session_id,
       min(c.created_at)                      as started_at,
       max(c.created_at)                      as last_at,
       count(*) filter (where c.round = 0)    as replies,
       count(*)                               as calls,
       sum(c.cost_usd)                        as cost_usd,
       (select array_agg(distinct t) from public.ai_calls c2, unnest(c2.tools) t where c2.session_id = c.session_id) as tools,
       count(*) filter (where c.error is not null) as errors,
       bool_or(c.is_eval)                     as is_eval,
       (select left(m.content #>> '{}', 120) from public.messages m
         where m.session_id = c.session_id and m.role = 'user' and jsonb_typeof(m.content) = 'string'
         order by m.id limit 1)               as first_message
from public.ai_calls c
where c.session_id is not null
group by c.session_id;

revoke all on public.ai_daily, public.ai_dialogs from anon, authenticated;
grant select on public.ai_daily, public.ai_dialogs to authenticated;
