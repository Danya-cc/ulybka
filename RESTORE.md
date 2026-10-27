# Восстановление проекта «Улыбка» с нуля

Инструкция на случай, если проект в Supabase удалён, сломан или его нужно перенести на другой сервер.
Всё, что нужно для восстановления **кода и структуры базы**, лежит в этом репозитории.

## Что где хранится

| Что | Где | Есть в Git |
|---|---|---|
| Сайт: `index.html`, `r.html`, `admin.html` | этот репозиторий → GitHub Pages | да |
| Код функций: `zoya`, `appointment`, `telegram-bot`, `notify-admin` | `supabase/functions/` | да |
| Структура базы: таблицы, правила, триггеры, права, расписание (cron), справочники врачей и услуг | `supabase/migrations/` (19 файлов, применять по порядку) | да |
| Секреты: ключ Claude API, токены двух Telegram-ботов | менеджер паролей владельца | **нет, и не должно быть** |
| Данные: пациенты, записи, заявки, переписки | бэкапы базы | **нет, и не должно быть** (персональные данные) |
| Служебные настройки: `admin_chat_id`, `bot_username`, `webhook_secret`, `cron_secret` | таблица `app_settings`, создаются заново (шаг 6) | нет |
| Сотрудники с доступом в админку | Supabase Auth + таблица `staff` (шаг 7) | нет |

Проверено 27.10.2026: все миграции применены к чистой базе PostgreSQL, и результат совпал с рабочей базой
по таблицам, ограничениям, индексам, триггерам, функциям, политикам доступа, правам, расписанию и справочникам.

## Шаги восстановления

Нужны: аккаунт Supabase, [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started), доступ к этому репозиторию и секреты из менеджера паролей.

### 1. Новый проект Supabase
Создать проект в панели Supabase. Записать его адрес (`https://<НОВЫЙ_ID>.supabase.co`) и публичный ключ (`sb_publishable_…`).

### 2. Заменить адрес старого проекта
Адрес проекта зашит в трёх миграциях (база вызывает функции по HTTP) и в трёх страницах сайта:

```bash
OLD=jeaqmrzudzaazhzrnnzh
NEW=<НОВЫЙ_ID>
grep -rl "$OLD" supabase/migrations index.html r.html admin.html | xargs sed -i "s/$OLD/$NEW/g"
```

В `index.html`, `r.html` и `admin.html` заменить старый публичный ключ `sb_publishable_…` на новый.
Если сайт переезжает на другой адрес, поменять `SITE_URL` в `supabase/functions/telegram-bot/index.ts`.

### 3. Структура базы
```bash
supabase link --project-ref <НОВЫЙ_ID>
supabase db push
```
Миграции включают расширения `pg_cron` и `pg_net`, справочники врачей и услуг и расписание.

> Миграция `clinic_seed_data` создаёт **демо-расписание**, в котором часть окон случайно помечена занятыми.
> Для настоящей клиники её нужно заменить настоящими врачами и услугами, а окна сгенерировать функцией
> `select public.generate_slots(14);` (она же запускается каждую ночь сама).

### 4. Функции и секреты
```bash
supabase functions deploy zoya appointment telegram-bot notify-admin --no-verify-jwt
supabase secrets set ANTHROPIC_API_KEY=... TELEGRAM_BOT_TOKEN=... TELEGRAM_PATIENT_BOT_TOKEN=...
```
- `TELEGRAM_BOT_TOKEN` — служебный бот владельца (уведомления).
- `TELEGRAM_PATIENT_BOT_TOKEN` — Лида, бот для пациентов.

### 5. Сайт
Закоммитить изменения из шага 2 и отправить в GitHub: GitHub Pages опубликует сайт сам.

### 6. Telegram
1. **Лида.** Подключить вебхук. Первый вызов разрешён без пароля, потому что `cron_secret` ещё не создан:
   ```bash
   curl -X POST https://<НОВЫЙ_ID>.supabase.co/functions/v1/telegram-bot \
        -H "Content-Type: application/json" -d '{"action":"setup"}'
   ```
   Затем в SQL-редакторе Supabase задать имя и описание бота: `select public.call_bot_action('set_profile');`
2. **Служебный бот.** Владелец пишет служебному боту любое сообщение, после чего:
   ```bash
   curl -X POST https://<НОВЫЙ_ID>.supabase.co/functions/v1/notify-admin \
        -H "Content-Type: application/json" -d '{"action":"setup"}'
   ```
   Если бот ответит, что сообщений нет, вписать chat id вручную:
   `insert into public.app_settings (key, value) values ('admin_chat_id', '<chat id>');`

### 7. Доступ в админку
В Supabase: **Authentication → Users → Add user** (email и пароль). Затем в SQL-редакторе:
```sql
insert into public.staff (email, full_name) values ('admin@clinic.ru', 'Имя Фамилия');
```

### 8. Данные
Восстановить последнюю выгрузку базы (только данные, структура уже создана):
```bash
psql "<строка подключения к новой базе>" -f backup-data.sql
```
После загрузки данных выполнить `select public.generate_slots(14);`.

### 9. Проверка
- [ ] На сайте загружаются цены и врачи.
- [ ] Зоя отвечает в чате и показывает свободное время.
- [ ] Тестовая запись появляется в админке, в служебный бот приходит «🦷 Новая запись».
- [ ] Ссылка из ответа Зои подключает Лиду в Telegram.
- [ ] `select public.call_bot_action('send_reminders');` возвращает `200` в `net._http_response`.
- [ ] Тестовую запись удалить.

## Правило на будущее

Любое изменение базы делать **только миграцией**, сохранять её файлом в `supabase/migrations/`
и коммитить вместе с кодом. Тогда эта инструкция всегда остаётся рабочей.
