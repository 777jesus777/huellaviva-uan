-- =====================================================================
-- Migracion 3/3: Row Level Security y privilegios minimos.
-- Principio: el participante solo toca lo suyo; el administrador NO lee
-- filas individuales, solo agregados via funciones; factores/periodos
-- solo los edita el admin ambiental y todo queda auditado.
-- =====================================================================

-- ---------- Privilegios minimos ----------
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

grant select on public.consent_versions to anon, authenticated;  -- aviso visible antes de iniciar sesion

grant select, insert, update         on public.profiles          to authenticated;
grant select, insert, update         on public.consents          to authenticated;
grant select, insert, update         on public.survey_periods    to authenticated;
grant select, insert, update, delete on public.surveys           to authenticated;
grant select, insert, update, delete on public.activity_answers  to authenticated;
grant select, insert, update         on public.emission_factors  to authenticated;
grant select                         on public.calculations      to authenticated;
grant select                         on public.calculation_details to authenticated;
grant select                         on public.admin_audit_log   to authenticated;
grant select, insert, update         on public.data_requests     to authenticated;
grant select, update                 on public.app_settings      to authenticated;
-- admin_users: sin privilegios ni politicas (invisible desde la API)

grant execute on function
  public.is_admin(text), public.has_active_consent(), public.period_is_open(uuid),
  public.owns_survey(uuid), public.survey_is_editable(uuid), public.get_setting(text),
  public.calculate_my_survey(uuid),
  public.dashboard_summary(uuid, text, text),
  public.dashboard_by_category(uuid, text, text)
to authenticated;
-- _calculate_survey: sin grants (solo owner/seed).

-- ---------- Activar RLS en TODAS las tablas ----------
alter table public.profiles             enable row level security;
alter table public.admin_users          enable row level security;
alter table public.app_settings         enable row level security;
alter table public.consent_versions     enable row level security;
alter table public.consents             enable row level security;
alter table public.survey_periods       enable row level security;
alter table public.surveys              enable row level security;
alter table public.activity_answers     enable row level security;
alter table public.emission_factors     enable row level security;
alter table public.calculations         enable row level security;
alter table public.calculation_details  enable row level security;
alter table public.admin_audit_log      enable row level security;
alter table public.data_requests        enable row level security;

-- ---------- profiles ----------
create policy profiles_select_own on public.profiles for select to authenticated
  using (id = (select auth.uid()));
create policy profiles_insert_own on public.profiles for insert to authenticated
  with check (id = (select auth.uid()));
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- ---------- consentimiento ----------
create policy consent_versions_read on public.consent_versions for select to anon, authenticated
  using (active);
create policy consents_select_own on public.consents for select to authenticated
  using (profile_id = (select auth.uid()));
create policy consents_insert_own on public.consents for insert to authenticated
  with check (profile_id = (select auth.uid()));
create policy consents_update_own on public.consents for update to authenticated
  using (profile_id = (select auth.uid())) with check (profile_id = (select auth.uid()));

-- ---------- periodos ----------
create policy periods_read on public.survey_periods for select to authenticated using (true);
create policy periods_admin_insert on public.survey_periods for insert to authenticated
  with check (public.is_admin('ambiental'));
create policy periods_admin_update on public.survey_periods for update to authenticated
  using (public.is_admin('ambiental')) with check (public.is_admin('ambiental'));

-- ---------- encuestas (RF-01: sin consentimiento no se persiste) ----------
create policy surveys_select_own on public.surveys for select to authenticated
  using (profile_id = (select auth.uid()));
create policy surveys_insert_own on public.surveys for insert to authenticated
  with check (profile_id = (select auth.uid())
              and public.has_active_consent()
              and public.period_is_open(period_id));
create policy surveys_update_own on public.surveys for update to authenticated
  using (profile_id = (select auth.uid()) and public.period_is_open(period_id))
  with check (profile_id = (select auth.uid()) and public.period_is_open(period_id));
create policy surveys_delete_own on public.surveys for delete to authenticated
  using (profile_id = (select auth.uid()) and public.period_is_open(period_id));

-- ---------- respuestas ----------
create policy answers_select_own on public.activity_answers for select to authenticated
  using (public.owns_survey(survey_id));
create policy answers_insert_own on public.activity_answers for insert to authenticated
  with check (public.survey_is_editable(survey_id));
create policy answers_update_own on public.activity_answers for update to authenticated
  using (public.survey_is_editable(survey_id)) with check (public.survey_is_editable(survey_id));
create policy answers_delete_own on public.activity_answers for delete to authenticated
  using (public.survey_is_editable(survey_id));

-- ---------- factores (lectura para transparencia; escritura solo admin ambiental) ----------
create policy factors_read on public.emission_factors for select to authenticated using (true);
create policy factors_admin_insert on public.emission_factors for insert to authenticated
  with check (public.is_admin('ambiental'));
create policy factors_admin_update on public.emission_factors for update to authenticated
  using (public.is_admin('ambiental')) with check (public.is_admin('ambiental'));

-- ---------- calculos (solo lectura del propio resultado; se escriben via funcion) ----------
create policy calcs_select_own on public.calculations for select to authenticated
  using (public.owns_survey(survey_id));
create policy calc_details_select_own on public.calculation_details for select to authenticated
  using (exists (select 1 from public.calculations c
                 where c.id = calculation_id and public.owns_survey(c.survey_id)));

-- ---------- auditoria ----------
create policy audit_admin_read on public.admin_audit_log for select to authenticated
  using (public.is_admin());

-- ---------- solicitudes de correccion/supresion (RF-09) ----------
create policy requests_select on public.data_requests for select to authenticated
  using (profile_id = (select auth.uid()) or public.is_admin('tecnico'));
create policy requests_insert_own on public.data_requests for insert to authenticated
  with check (profile_id = (select auth.uid()));
create policy requests_admin_update on public.data_requests for update to authenticated
  using (public.is_admin('tecnico')) with check (public.is_admin('tecnico'));

-- ---------- configuracion ----------
create policy settings_read on public.app_settings for select to authenticated using (true);
create policy settings_admin_update on public.app_settings for update to authenticated
  using (public.is_admin('tecnico')) with check (public.is_admin('tecnico'));
