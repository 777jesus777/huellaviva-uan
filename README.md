# HuellaViva UAN

Prototipo **académico** para estimar la huella de carbono de la comunidad universitaria
(Universidad Antonio Nariño). Trabajo final integrador: Gestión de Requisitos + Persistencia de Software.

> **Advertencia:** estimador educativo y de diagnóstico. No es un inventario institucional
> verificado, una certificación, una compensación de emisiones ni un resultado oficial de RENARE.
> Los factores incluidos en `seed.sql` son **sintéticos** (ilustrativos) y no deben usarse como oficiales.

## Estructura

```
docs/                  análisis, diseño, diagramas, manuales y referencias
src/                   código fuente (frontend)
supabase/migrations/   SQL versionado (esquema, funciones, RLS)
supabase/seed.sql      solo datos sintéticos
tests/                 pruebas (RLS, cálculo)
assets/                ícono y capturas limpias
.env.example           nombres de variables (sin valores)
```

## Requisitos

- [Supabase CLI](https://supabase.com/docs/guides/cli) y Docker (para entorno local)
- Node.js 18+ (cuando se agregue el frontend)

## Ejecutar la base de datos en local

```bash
supabase start          # levanta Postgres/Auth locales
supabase db reset       # aplica migraciones + seed.sql (datos sintéticos)
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f tests/rls_tests.sql
```

Si las pruebas pasan verás `OK participante`, `OK administrador` y `OK usuario no autorizado`.

Usuarios demo (solo local): `estudiante1@demo.example`, `admin.demo@demo.example`; clave `Demo-12345`.

## Publicar el esquema en un proyecto de Supabase

```bash
supabase login
supabase link --project-ref <TU_PROJECT_REF>
supabase db push        # aplica solo las migraciones (NO el seed)
```

Para dar rol de administrador a un usuario real, ejecuta en el SQL Editor del dashboard
(no desde el navegador de la app):

```sql
insert into public.admin_users (user_id, admin_role) values ('<uuid-del-usuario>', 'ambiental');
```

## Variables de entorno

Copia `.env.example` a `.env.local` y completa `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY`.
La `service_role` nunca se publica.

## Reglas de privacidad del diseño

- RLS activa en todas las tablas; el admin no lee filas individuales, solo agregados.
- Los agregados ocultan grupos con menos de 10 respuestas (`app_settings.min_group_size`, regla de diseño).
- Sin consentimiento activo no se puede crear una encuesta.
- Un factor ya usado en cálculos no se sobrescribe: se crea una versión nueva.
- Un factor `aprobado` exige fuente, URL, aprobador y no ser sintético.

## Estado

- [x] Esquema, funciones, RLS, seed sintético, pruebas de permisos
- [ ] Encuesta final y factores reales con fuente
- [ ] Frontend (participante y dashboard)
- [ ] Documento de análisis y diseño
