revoke update on public.patients, public.slots, public.messages, public.chat_sessions, public.doctor_schedule,
  public.staff, public.app_settings, public.doctors, public.services, public.doctor_services from anon, authenticated;
revoke insert, delete on public.doctors, public.services, public.doctor_services from anon, authenticated;
