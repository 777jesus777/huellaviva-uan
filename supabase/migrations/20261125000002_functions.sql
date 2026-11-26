-- =====================================================================
-- Migracion 2/3: funciones auxiliares, calculo reproducible,
-- dashboard agregado seguro y triggers de auditoria.
-- =====================================================================

-- ---------- Ayudantes para RLS ----------
create or replace function public.is_admin(p_role text default null)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.admin_users a
    where a.user_id = auth.uid() and (p_role is null or a.admin_role = p_role)
  );
$$;

create or replace function public.has_active_consent()
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.consents c
    join public.consent_versions v on v.id = c.consent_version_id
    where c.profile_id = auth.uid() and c.revoked_at is null and v.active
  );
$$;

create or replace function public.period_is_open(p_period_id uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.survey_periods p
    where p.id = p_period_id and p.status = 'abierto'
      and current_date between p.start_date and p.end_date
  );
$$;

create or replace function public.owns_survey(p_survey_id uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.surveys s
                 where s.id = p_survey_id and s.profile_id = auth.uid());
$$;

create or replace function public.survey_is_editable(p_survey_id uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.surveys s
                 where s.id = p_survey_id and s.profile_id = auth.uid()
                   and public.period_is_open(s.period_id));
$$;

create or replace function public.get_setting(p_key text)
returns text language sql security definer stable set search_path = public as $$
  select value from public.app_settings where key = p_key;
$$;

-- ---------- Calculo reproducible ----------
-- emisiones (kgCO2e) = actividad (ajustada) x factor.
-- Si el factor es 'shared_household', la actividad se divide entre las
-- personas del hogar (respuesta HOGAR_PERSONAS; por defecto 1).
-- Las unidades de la respuesta y del factor deben coincidir (sin conversiones
-- implicitas); si no coinciden se lanza error para no calcular mal.
create or replace function public._calculate_survey(p_survey_id uuid, p_allow_draft boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_period  public.survey_periods%rowtype;
  v_calc_id uuid;
  v_persons numeric;
  v_factor  public.emission_factors%rowtype;
  v_activity numeric;
  v_em      numeric;
  v_total   numeric := 0;
  r         record;
begin
  select sp.* into v_period
  from public.surveys s join public.survey_periods sp on sp.id = s.period_id
  where s.id = p_survey_id;
  if not found then raise exception 'Encuesta no encontrada'; end if;

  select a.numeric_value into v_persons
  from public.activity_answers a
  where a.survey_id = p_survey_id and a.question_code = 'HOGAR_PERSONAS';
  v_persons := case when coalesce(v_persons, 0) >= 1 then v_persons else 1 end;

  insert into public.calculations (survey_id, methodology_version, used_draft_factors)
  values (p_survey_id, v_period.methodology_version, p_allow_draft)
  returning id into v_calc_id;

  for r in
    select * from public.activity_answers
    where survey_id = p_survey_id and numeric_value is not null
  loop
    select f.* into v_factor
    from public.emission_factors f
    where f.question_code = r.question_code
      and f.valid_from <= v_period.start_date
      and (f.valid_to is null or f.valid_to >= v_period.start_date)
      and (f.status = 'aprobado' or (p_allow_draft and f.status = 'borrador'))
    order by f.reference_year desc, f.valid_from desc
    limit 1;

    if not found then continue; end if;   -- respuesta sin factor (ej. n.o de personas)

    if r.unit is distinct from v_factor.unit_activity then
      raise exception 'Unidad "%" de % no coincide con la del factor ("%")',
        r.unit, r.question_code, v_factor.unit_activity;
    end if;

    v_activity := r.numeric_value / case when v_factor.shared_household then v_persons else 1 end;
    v_em := v_activity * v_factor.factor_value;

    insert into public.calculation_details
      (calculation_id, answer_id, factor_id, category, activity_value, converted_value, emissions_kgco2e)
    values
      (v_calc_id, r.id, v_factor.id, v_factor.category, r.numeric_value, v_activity, round(v_em, 4));

    v_total := v_total + v_em;
  end loop;

  update public.calculations set total_kgco2e = round(v_total, 4) where id = v_calc_id;
  return v_calc_id;
end $$;

-- Envoltorio para participantes: solo su propia encuesta.
create or replace function public.calculate_my_survey(p_survey_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
begin
  if not public.owns_survey(p_survey_id) then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  return public._calculate_survey(p_survey_id, public.get_setting('allow_draft_factors') = 'true');
end $$;

-- ---------- Dashboard agregado (solo administradores) ----------
-- Oculta grupos con menos de min_group_size respuestas.
create or replace function public.dashboard_summary(
  p_period_id uuid, p_group text default null, p_campus text default null)
returns table (grupo text, participantes bigint, promedio_kgco2e numeric, mediana_kgco2e numeric)
language plpgsql security definer stable set search_path = public as $$
declare v_min int := public.get_setting('min_group_size')::int;
begin
  if not public.is_admin() then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  return query
  with latest as (
    select distinct on (c.survey_id) c.survey_id, c.total_kgco2e
    from public.calculations c order by c.survey_id, c.calculated_at desc
  ), base as (
    select p.tipo_usuario, l.total_kgco2e
    from public.surveys s
    join public.profiles p on p.id = s.profile_id
    join latest l on l.survey_id = s.id
    where s.period_id = p_period_id and s.status = 'enviada'
      and (p_group  is null or p.tipo_usuario = p_group)
      and (p_campus is null or p.campus = p_campus)
  )
  select b.tipo_usuario, count(*)::bigint,
         round(avg(b.total_kgco2e), 2),
         round((percentile_cont(0.5) within group (order by b.total_kgco2e))::numeric, 2)
  from base b
  group by b.tipo_usuario
  having count(*) >= v_min
  order by b.tipo_usuario;
end $$;

create or replace function public.dashboard_by_category(
  p_period_id uuid, p_group text default null, p_campus text default null)
returns table (grupo text, categoria text, participantes bigint, promedio_kgco2e numeric)
language plpgsql security definer stable set search_path = public as $$
declare v_min int := public.get_setting('min_group_size')::int;
begin
  if not public.is_admin() then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  return query
  with latest as (
    select distinct on (c.survey_id) c.id as calc_id, c.survey_id
    from public.calculations c order by c.survey_id, c.calculated_at desc
  ), per as (
    select p.tipo_usuario, d.category, s.id as survey_id, sum(d.emissions_kgco2e) as kg
    from public.surveys s
    join public.profiles p on p.id = s.profile_id
    join latest l on l.survey_id = s.id
    join public.calculation_details d on d.calculation_id = l.calc_id
    where s.period_id = p_period_id and s.status = 'enviada'
      and (p_group  is null or p.tipo_usuario = p_group)
      and (p_campus is null or p.campus = p_campus)
    group by p.tipo_usuario, d.category, s.id
  )
  select per.tipo_usuario, per.category, count(*)::bigint, round(avg(per.kg), 2)
  from per
  group by per.tipo_usuario, per.category
  having count(*) >= v_min
  order by per.tipo_usuario, per.category;
end $$;

-- ---------- Triggers ----------
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

create trigger trg_surveys_touch before update on public.surveys
  for each row execute function public.touch_updated_at();

-- Un factor ya usado en calculos no puede cambiar de valor/unidad: se crea una version nueva.
create or replace function public.protect_used_factor()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.calculation_details d where d.factor_id = old.id)
     and (new.factor_value  is distinct from old.factor_value
       or new.unit_activity is distinct from old.unit_activity
       or new.question_code is distinct from old.question_code) then
    raise exception 'El factor % ya fue usado en calculos; cree una nueva version', old.id;
  end if;
  return new;
end $$;

create trigger trg_factor_protect before update on public.emission_factors
  for each row execute function public.protect_used_factor();

-- Auditoria de cambios administrativos (sin secretos).
create or replace function public.audit_row_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_old jsonb; v_new jsonb;
begin
  if tg_op in ('UPDATE','DELETE') then v_old := to_jsonb(old); end if;
  if tg_op in ('INSERT','UPDATE') then v_new := to_jsonb(new); end if;
  insert into public.admin_audit_log (actor_id, action, entity, entity_id, before_json, after_json)
  values (auth.uid(), tg_op, tg_table_name,
          coalesce(v_new->>'id', v_old->>'id', v_new->>'key', v_old->>'key'),
          v_old, v_new);
  return null;
end $$;

create trigger trg_audit_factors after insert or update on public.emission_factors
  for each row execute function public.audit_row_change();
create trigger trg_audit_periods after insert or update on public.survey_periods
  for each row execute function public.audit_row_change();
create trigger trg_audit_settings after insert or update on public.app_settings
  for each row execute function public.audit_row_change();
