-- =====================================================================
-- HuellaViva UAN - Esquema base (PROTOTIPO ACADEMICO)
-- Migracion 1/3: tablas, restricciones e indices.
-- No es un inventario institucional verificado ni un registro RENARE.
-- =====================================================================

-- ---------- Perfiles y roles ----------
create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  tipo_usuario text not null check (tipo_usuario in ('estudiante','profesor','administrativo')),
  campus       text,                       -- opcional (minimizacion)
  estado       text not null default 'activo' check (estado in ('activo','retirado')),
  created_at   timestamptz not null default now()
);
comment on table public.profiles is
  'Perfil minimo del participante. NO guardar documento, direccion ni placa.';

-- El rol administrativo NO vive en profiles (el usuario podria editarlo).
-- Esta tabla no tiene politicas RLS: nadie la lee/escribe desde la API.
create table public.admin_users (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  admin_role text not null check (admin_role in ('ambiental','tecnico')),
  created_at timestamptz not null default now()
);

-- Configuracion (umbral de agregacion, uso de factores en borrador)
create table public.app_settings (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);
insert into public.app_settings (key, value) values
  ('min_group_size',      '10'),     -- regla de diseno del proyecto, no umbral legal
  ('allow_draft_factors', 'false');  -- solo true en entornos de demo

-- ---------- Consentimiento ----------
create table public.consent_versions (
  id         uuid primary key default gen_random_uuid(),
  version    text not null unique,
  text_url   text not null,
  purpose    text not null,
  valid_from date not null,
  active     boolean not null default false
);

create table public.consents (
  id                 uuid primary key default gen_random_uuid(),
  profile_id         uuid not null references public.profiles(id) on delete cascade,
  consent_version_id uuid not null references public.consent_versions(id),
  accepted_at        timestamptz not null default now(),
  revoked_at         timestamptz,
  check (revoked_at is null or revoked_at >= accepted_at)
);

-- ---------- Periodos y encuestas ----------
create table public.survey_periods (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null,
  start_date          date not null,
  end_date            date not null,
  methodology_version text not null,
  status              text not null default 'borrador' check (status in ('borrador','abierto','cerrado')),
  check (end_date >= start_date)
);

create table public.surveys (
  id           uuid primary key default gen_random_uuid(),
  profile_id   uuid not null references public.profiles(id) on delete cascade,
  period_id    uuid not null references public.survey_periods(id),
  status       text not null default 'borrador' check (status in ('borrador','enviada')),
  submitted_at timestamptz,
  updated_at   timestamptz not null default now(),
  unique (profile_id, period_id)           -- una encuesta por persona y periodo
);

create table public.activity_answers (
  id            uuid primary key default gen_random_uuid(),
  survey_id     uuid not null references public.surveys(id) on delete cascade,
  category      text not null,
  question_code text not null,
  numeric_value numeric check (numeric_value is null or numeric_value >= 0),
  text_value    text,
  unit          text,
  is_estimated  boolean not null default false,   -- dato medido vs estimado
  check (numeric_value is not null or text_value is not null),
  unique (survey_id, question_code)
);

-- ---------- Factores de emision versionados ----------
create table public.emission_factors (
  id                 uuid primary key default gen_random_uuid(),
  category           text not null,
  question_code      text not null,               -- une el factor con la pregunta
  factor_value       numeric not null check (factor_value >= 0),
  unit_activity      text not null,               -- ej. kWh, km, m3, trayecto
  unit_emission      text not null default 'kgCO2e' check (unit_emission = 'kgCO2e'),
  gas_basis          text not null default 'CO2e',
  shared_household   boolean not null default false, -- si true: se divide entre personas del hogar
  geography          text not null,
  method             text,
  source             text not null,
  source_url         text,
  reference_year     int  not null,
  valid_from         date not null,
  valid_to           date,
  version            text not null,
  status             text not null default 'borrador' check (status in ('borrador','aprobado','retirado')),
  is_synthetic       boolean not null default false,
  justification      text not null,
  approved_by        uuid references auth.users(id),
  loaded_at          timestamptz not null default now(),
  check (valid_to is null or valid_to >= valid_from),
  -- Un factor "aprobado" debe tener fuente verificable y aprobador; nunca sintetico.
  check (status <> 'aprobado'
         or (source_url is not null and is_synthetic = false and approved_by is not null)),
  unique (question_code, version, geography)
);

-- ---------- Calculos ----------
create table public.calculations (
  id                  uuid primary key default gen_random_uuid(),
  survey_id           uuid not null references public.surveys(id) on delete cascade,
  methodology_version text not null,
  total_kgco2e        numeric(14,4) not null default 0,
  used_draft_factors  boolean not null default false,
  calculated_at       timestamptz not null default now()
);

create table public.calculation_details (
  id              uuid primary key default gen_random_uuid(),
  calculation_id  uuid not null references public.calculations(id) on delete cascade,
  answer_id       uuid references public.activity_answers(id) on delete set null,
  factor_id       uuid not null references public.emission_factors(id) on delete restrict,
  category        text not null,
  activity_value  numeric not null,
  converted_value numeric not null,   -- actividad ya ajustada (ej. dividida entre personas)
  emissions_kgco2e numeric(14,4) not null
);

-- ---------- Auditoria y derechos del titular ----------
create table public.admin_audit_log (
  id          uuid primary key default gen_random_uuid(),
  actor_id    uuid,
  action      text not null,
  entity      text not null,
  entity_id   text,
  before_json jsonb,
  after_json  jsonb,
  created_at  timestamptz not null default now()
);

create table public.data_requests (
  id           uuid primary key default gen_random_uuid(),
  profile_id   uuid not null references public.profiles(id) on delete cascade,
  request_type text not null check (request_type in ('correccion','supresion','retiro')),
  description  text,
  status       text not null default 'recibida' check (status in ('recibida','en_proceso','atendida','rechazada')),
  created_at   timestamptz not null default now(),
  resolved_at  timestamptz
);

-- ---------- Indices ----------
create index idx_consents_profile      on public.consents(profile_id);
create index idx_surveys_period        on public.surveys(period_id);
create index idx_answers_survey        on public.activity_answers(survey_id);
create index idx_factors_lookup        on public.emission_factors(question_code, valid_from);
create index idx_calcs_survey          on public.calculations(survey_id, calculated_at desc);
create index idx_calc_details_calc     on public.calculation_details(calculation_id);
create index idx_requests_profile      on public.data_requests(profile_id);
