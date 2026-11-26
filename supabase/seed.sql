-- =====================================================================
-- seed.sql - SOLO DATOS SINTETICOS PARA DEMO LOCAL
-- * Los usuarios son ficticios (@demo.example). Clave demo: Demo-12345
-- * Los factores son VALORES ILUSTRATIVOS marcados is_synthetic=true y
--   status='borrador'. NO son factores oficiales. Reemplazar por factores
--   reales (UPME/FECOC u otra fuente) con fuente, URL y anio.
-- * No ejecutar en un proyecto con usuarios reales.
-- =====================================================================

-- ---------- Usuarios ficticios ----------
create temp table _demo_users as
  select ('10000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid as id,
         'estudiante' || i || '@demo.example' as email, 'estudiante' as grupo, i::int as i
  from generate_series(1, 12) i
  union all
  select ('20000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
         'profesor' || i || '@demo.example', 'profesor', i::int
  from generate_series(1, 4) i                       -- <10: el dashboard debe ocultarlo
  union all
  select ('30000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
         'administrativo' || i || '@demo.example', 'administrativo', i::int
  from generate_series(1, 10) i
  union all
  select '90000000-0000-0000-0000-000000000001'::uuid,
         'admin.demo@demo.example', 'admin', 1;

insert into auth.users
  (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
   raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
   confirmation_token, recovery_token, email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
       extensions.crypt('Demo-12345', extensions.gen_salt('bf')), now(),
       '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
       '', '', '', ''
from _demo_users u;

insert into public.profiles (id, tipo_usuario, campus)
select u.id, u.grupo, case when u.i % 2 = 0 then 'Campus A' else 'Campus B' end
from _demo_users u where u.grupo <> 'admin';

insert into public.admin_users (user_id, admin_role)
values ('90000000-0000-0000-0000-000000000001', 'ambiental');

-- ---------- Consentimiento (borrador sujeto a revision institucional) ----------
insert into public.consent_versions (id, version, text_url, purpose, valid_from, active)
values ('c0000000-0000-0000-0000-000000000001', 'v0.1-borrador',
        'PENDIENTE: aviso sujeto a revision institucional',
        'Estimar huella de carbono (prototipo academico)', current_date, true);

insert into public.consents (profile_id, consent_version_id)
select u.id, 'c0000000-0000-0000-0000-000000000001' from _demo_users u where u.grupo <> 'admin';

-- ---------- Periodo ----------
insert into public.survey_periods (id, name, start_date, end_date, methodology_version, status)
values ('a0000000-0000-0000-0000-000000000001', 'Demo agosto 2026',
        '2026-08-01', '2026-08-31', 'v0.1-demo', 'abierto');

-- ---------- Factores SINTETICOS (ilustrativos) ----------
insert into public.emission_factors
  (category, question_code, factor_value, unit_activity, shared_household, geography,
   method, source, reference_year, valid_from, version, status, is_synthetic, justification)
select v.category, v.code, v.val, v.unit, v.shared, 'Colombia',
       'valor ilustrativo', 'DEMO SINTETICO - no es un factor oficial',
       2026, '2026-01-01', 'demo-1', 'borrador', true, 'Valor ilustrativo para pruebas'
from (values
  ('electricidad',  'ELEC_KWH',          0.100::numeric, 'kWh',      true),
  ('combustibles',  'GAS_M3',            2.000::numeric, 'm3',       true),
  ('transporte',    'TRANS_BUS_KM',      0.100::numeric, 'km',       false),
  ('transporte',    'TRANS_AUTO_KM',     0.200::numeric, 'km',       false),
  ('transporte',    'TRANS_MOTO_KM',     0.080::numeric, 'km',       false),
  ('viajes_aereos', 'AIR_NAC_TRAYECTOS', 100.0::numeric, 'trayecto', false)
) as v(category, code, val, unit, shared);

-- ---------- Encuestas y respuestas sinteticas ----------
insert into public.surveys (profile_id, period_id, status, submitted_at)
select u.id, 'a0000000-0000-0000-0000-000000000001', 'enviada', now()
from _demo_users u where u.grupo <> 'admin';

insert into public.activity_answers (survey_id, category, question_code, numeric_value, unit, is_estimated)
select s.id, v.category, v.code, v.val, v.unit, v.est
from public.surveys s
join _demo_users u on u.id = s.profile_id
cross join lateral (values
  ('hogar',        'HOGAR_PERSONAS', (1 + (u.i % 5))::numeric,      'personas', false),
  ('electricidad', 'ELEC_KWH',       (80 + (u.i * 7 % 60))::numeric, 'kWh',      (u.i % 4 = 0)),
  ('combustibles', 'GAS_M3',         (3 + (u.i % 4))::numeric,       'm3',       true)
) as v(category, code, val, unit, est);

insert into public.activity_answers (survey_id, category, question_code, numeric_value, unit, is_estimated)
select s.id, 'transporte',
       case u.i % 3 when 0 then 'TRANS_BUS_KM' when 1 then 'TRANS_AUTO_KM' else 'TRANS_MOTO_KM' end,
       (60 + (u.i * 11 % 90))::numeric, 'km', false
from public.surveys s join _demo_users u on u.id = s.profile_id;

insert into public.activity_answers (survey_id, category, question_code, numeric_value, unit, is_estimated)
select s.id, 'viajes_aereos', 'AIR_NAC_TRAYECTOS', 1, 'trayecto', false
from public.surveys s join _demo_users u on u.id = s.profile_id
where u.i % 4 = 0;

-- ---------- Calculo (demo: permitir factores en borrador) ----------
update public.app_settings set value = 'true' where key = 'allow_draft_factors';

select public._calculate_survey(s.id, true) from public.surveys s;

drop table _demo_users;
