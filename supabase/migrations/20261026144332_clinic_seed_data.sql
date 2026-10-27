insert into public.doctors (full_name, specialty, experience_years, description) values
  ('Анна Иванова',   'терапевт',             12, 'Кариес, чистка, отбеливание'),
  ('Дмитрий Петров', 'хирург-имплантолог',   15, 'Удаление, имплантация'),
  ('Елена Смирнова', 'ортодонт',              9, 'Брекеты и элайнеры');

insert into public.services (name, description, price, price_is_from, duration_min) values
  ('Консультация и осмотр',     'С планом лечения',             0,     false, 30),
  ('Профессиональная чистка',   'Ультразвук + Air Flow',        3000,  false, 60),
  ('Лечение кариеса',           'С анестезией и пломбой',       4500,  true,  60),
  ('Удаление зуба',             'Простое удаление',             2500,  true,  30),
  ('Отбеливание',               'Кабинетное, 1 визит',          12000, false, 60),
  ('Имплантация',               'Под ключ, с коронкой',         35000, true,  60);

-- Кто что делает
insert into public.doctor_services (doctor_id, service_id)
select d.id, s.id from public.doctors d join public.services s on
  (d.full_name = 'Анна Иванова'   and s.name in ('Консультация и осмотр','Профессиональная чистка','Лечение кариеса','Отбеливание')) or
  (d.full_name = 'Дмитрий Петров' and s.name in ('Консультация и осмотр','Удаление зуба','Имплантация')) or
  (d.full_name = 'Елена Смирнова' and s.name in ('Консультация и осмотр'));

-- Расписание на 14 дней вперёд, приём по часу с 9:00 до 21:00 (последний в 20:00), время московское.
-- Иванова: пн–пт, Петров: вт, чт, сб, Смирнова: пн, ср, пт, сб. Примерно треть окон уже занята.
select setseed(0.42);
insert into public.slots (doctor_id, starts_at, ends_at, is_booked)
select d.id,
       (day + make_interval(hours => h)) at time zone 'Europe/Moscow',
       (day + make_interval(hours => h + 1)) at time zone 'Europe/Moscow',
       random() < 0.35
from public.doctors d
cross join generate_series((now() at time zone 'Europe/Moscow')::date,
                           (now() at time zone 'Europe/Moscow')::date + 13, interval '1 day') as day
cross join generate_series(9, 20) as h
where (d.full_name = 'Анна Иванова'   and extract(isodow from day) between 1 and 5)
   or (d.full_name = 'Дмитрий Петров' and extract(isodow from day) in (2,4,6))
   or (d.full_name = 'Елена Смирнова' and extract(isodow from day) in (1,3,5,6));
