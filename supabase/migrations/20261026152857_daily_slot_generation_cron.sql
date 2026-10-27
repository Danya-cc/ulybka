create extension if not exists pg_cron;
-- Каждый день в 03:00 по Москве (00:00 UTC) достраиваем расписание на 14 дней вперёд
select cron.schedule('generate-slots-daily', '0 0 * * *', $$select public.generate_slots(14)$$);
select public.generate_slots(14);
