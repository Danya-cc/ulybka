-- Триггеры, которые меняют расписание (slots), работают с правами базы,
-- а не того, кто нажал кнопку. Прямой доступ к slots у сотрудников остаётся закрытым.
alter function public.tg_appointment_status_change() security definer;
alter function public.tg_appointment_before_insert() security definer;
revoke execute on function public.tg_appointment_status_change() from public, anon, authenticated;
revoke execute on function public.tg_appointment_before_insert() from public, anon, authenticated;
