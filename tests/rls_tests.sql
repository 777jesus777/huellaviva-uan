-- =====================================================================
-- Pruebas de RLS: participante, administrador y usuario no autorizado.
-- Ejecutar DESPUES de `supabase db reset` (aplica migraciones + seed):
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f tests/rls_tests.sql
-- Todo corre en una transaccion que termina en ROLLBACK.
-- =====================================================================
begin;

-- ---------- 1) PARTICIPANTE (estudiante1) ----------
do $$
declare n int; rc int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub','10000000-0000-0000-0000-000000000001','role','authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from public.surveys;
  assert n = 1, 'P1 FALLO: el participante debe ver solo su encuesta, ve ' || n;

  select count(distinct survey_id) into n from public.activity_answers;
  assert n = 1, 'P2 FALLO: el participante ve respuestas de otros';

  select count(*) into n from public.profiles;
  assert n = 1, 'P3 FALLO: el participante ve perfiles ajenos';

  begin
    perform 1 from public.admin_users;
    raise exception 'P4 FALLO: el participante pudo leer admin_users';
  exception when insufficient_privilege then null;
  end;

  begin
    perform * from public.dashboard_summary('a0000000-0000-0000-0000-000000000001');
    raise exception 'P5 FALLO: el participante pudo usar el dashboard';
  exception when insufficient_privilege then null;
  end;

  update public.emission_factors set factor_value = 999;
  get diagnostics rc = row_count;
  assert rc = 0, 'P6 FALLO: el participante pudo editar factores';

  reset role;
  raise notice 'OK participante';
end $$;

-- ---------- 2) ADMINISTRADOR (ambiental) ----------
do $$
declare n int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub','90000000-0000-0000-0000-000000000001','role','authenticated')::text, true);
  set local role authenticated;

  select count(*) into n from public.surveys;
  assert n = 0, 'A1 FALLO: el admin lee encuestas individuales (' || n || ')';

  select count(*) into n from public.activity_answers;
  assert n = 0, 'A2 FALLO: el admin lee respuestas individuales';

  select count(*) into n from public.dashboard_summary('a0000000-0000-0000-0000-000000000001');
  assert n = 2, 'A3 FALLO: se esperaban 2 grupos (estudiante, administrativo); hay ' || n;

  select count(*) into n from public.dashboard_summary('a0000000-0000-0000-0000-000000000001')
   where grupo = 'profesor';
  assert n = 0, 'A4 FALLO: el grupo <10 (profesor) no fue ocultado';

  -- edicion de factor autorizada y auditada (justificacion cambia, valor no)
  update public.emission_factors set justification = 'prueba RLS' where question_code = 'ELEC_KWH';
  select count(*) into n from public.admin_audit_log where entity = 'emission_factors' and action = 'UPDATE';
  assert n >= 1, 'A5 FALLO: la edicion del factor no quedo auditada';

  reset role;
  raise notice 'OK administrador';
end $$;

-- ---------- 3) USUARIO NO AUTORIZADO (anon) ----------
do $$
declare n int;
begin
  set local role anon;

  begin
    perform 1 from public.surveys;
    raise exception 'N1 FALLO: anon pudo leer surveys';
  exception when insufficient_privilege then null;
  end;

  begin
    perform 1 from public.emission_factors;
    raise exception 'N2 FALLO: anon pudo leer factores';
  exception when insufficient_privilege then null;
  end;

  select count(*) into n from public.consent_versions;
  assert n >= 1, 'N3 FALLO: anon deberia ver el aviso de consentimiento activo';

  reset role;
  raise notice 'OK usuario no autorizado';
end $$;

rollback;
