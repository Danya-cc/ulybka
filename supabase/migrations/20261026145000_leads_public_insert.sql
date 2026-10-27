-- Посетитель сайта может только ДОБАВИТЬ заявку из формы. Читать, менять и удалять заявки — нельзя.
create policy "site can submit form leads" on public.leads
  for insert to anon, authenticated
  with check (
    source = 'form'
    and status = 'new'
    and session_id is null
    and char_length(name) between 1 and 100
    and phone ~ '^\+?[0-9]{10,15}$'
    and (comment is null or char_length(comment) <= 500)
  );
