-- Cantabria Sim Racing · base de datos completa (reglamentos, permisos, perfiles)
-- Se puede ejecutar entero cuantas veces haga falta: no da error si algo ya existe.
-- Si Supabase avisa de "destructive operation", confirma: solo recrea políticas y funciones.

-- ========== 1. TABLAS ==========
create table if not exists public.managers (
  user_id uuid not null references auth.users(id) on delete cascade,
  championship text not null check (championship in ('ra','rs','mo','all')),
  primary key (user_id, championship)
);

create table if not exists public.rules (
  championship text primary key check (championship in ('ra','rs','mo')),
  content jsonb not null default '[]',
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

create table if not exists public.rules_history (
  id bigint generated always as identity primary key,
  championship text not null,
  content jsonb not null,
  changed_at timestamptz not null default now(),
  changed_by uuid
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  birth_year int check (birth_year is null or birth_year between 1900 and 2100),
  created_at timestamptz not null default now()
);
alter table public.profiles add column if not exists consent_at timestamptz;
alter table public.profiles add column if not exists minor_authorized boolean not null default false;

alter table public.managers enable row level security;
alter table public.rules enable row level security;
alter table public.rules_history enable row level security;
alter table public.profiles enable row level security;

-- ========== 2. LIMPIEZA (para poder recrear todo sin errores) ==========
drop policy if exists "ver mis permisos" on public.managers;
drop policy if exists "reglamentos públicos" on public.rules;
drop policy if exists "crear si eres responsable" on public.rules;
drop policy if exists "editar si eres responsable" on public.rules;
drop policy if exists "ver historial si eres responsable" on public.rules_history;
drop policy if exists "ver mi perfil" on public.profiles;
drop policy if exists "administradores ven perfiles" on public.profiles;
drop policy if exists "editar mi perfil" on public.profiles;
drop function if exists public.can_edit(text);   -- versión antigua, expuesta a la API

-- ========== 3. PERMISOS (función en un esquema privado, no expuesto a la API) ==========
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

-- ¿Puede el usuario actual editar este campeonato? ('all' = administrador)
create or replace function private.can_edit(c text) returns boolean
language sql security definer set search_path = '' stable as $$
  select exists (select 1 from public.managers
                 where user_id = (select auth.uid()) and championship in (c, 'all'));
$$;
revoke execute on function private.can_edit(text) from public, anon;
grant execute on function private.can_edit(text) to authenticated;

-- ========== 4. POLÍTICAS ==========
create policy "ver mis permisos" on public.managers for select to authenticated using (user_id = (select auth.uid()));

create policy "reglamentos públicos" on public.rules for select to anon, authenticated using (true);
create policy "crear si eres responsable" on public.rules for insert to authenticated with check (private.can_edit(championship));
create policy "editar si eres responsable" on public.rules for update to authenticated using (private.can_edit(championship)) with check (private.can_edit(championship));

create policy "ver historial si eres responsable" on public.rules_history for select to authenticated using (private.can_edit(championship));

create policy "ver mi perfil" on public.profiles for select to authenticated using (id = (select auth.uid()));
create policy "administradores ven perfiles" on public.profiles for select to authenticated using (private.can_edit('all'));
create policy "editar mi perfil" on public.profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- ========== 5. HISTORIAL DE REGLAMENTOS ==========
create or replace function public.rules_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.rules_history (championship, content, changed_by) values (old.championship, old.content, auth.uid());
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;
revoke execute on function public.rules_audit() from public, anon, authenticated;

drop trigger if exists rules_audit_trg on public.rules;
create trigger rules_audit_trg before update on public.rules for each row execute function public.rules_audit();

-- ========== 6. PERFIL AL REGISTRARSE ==========
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- Si algo falla al crear el perfil, el registro de la cuenta NO se bloquea
  begin
    insert into public.profiles (id, full_name, birth_year, consent_at, minor_authorized)
    values (
      new.id,
      left(nullif(trim(new.raw_user_meta_data->>'full_name'), ''), 120),
      case when (new.raw_user_meta_data->>'birth_year') ~ '^[0-9]{4}$'
           then (new.raw_user_meta_data->>'birth_year')::int end,
      case when (new.raw_user_meta_data->>'consent') = 'true' then now() end,
      coalesce((new.raw_user_meta_data->>'minor_authorized') = 'true', false)
    )
    on conflict (id) do nothing;
  exception when others then
    raise warning 'handle_new_user: %', sqlerrm;
  end;
  return new;
end $$;
revoke execute on function public.handle_new_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

-- Perfil vacío para las cuentas que ya existían
insert into public.profiles (id) select id from auth.users on conflict do nothing;

-- ========== 7. REGLAMENTOS INICIALES (no sobrescribe los que ya editaste) ==========
insert into public.rules (championship, content) values
('ra','[{"title":"Puntuación","text":"25, 18, 15, 12, 10, 8, 6, 4, 2 y 1 puntos por rally."},{"title":"Etapas","text":"Varias etapas especiales por rally y un solo intento válido por etapa."},{"title":"Coches","text":"Coches homologados por categoría y copa."},{"title":"Reclamaciones","text":"Repeticiones obligatorias en caso de reclamación; comisarios independientes."}]'),
('rs','[{"title":"Puntuación","text":"Puntuación por prueba según la clasificación final de cada rallysprint."},{"title":"Formato","text":"Tramos más cortos, pensados para competir en una sola sesión."},{"title":"Coches","text":"Coches homologados por categoría y copa."},{"title":"Juego limpio","text":"Sanciones públicas y razonadas; trato respetuoso en todos los canales."}]'),
('mo','[{"title":"Puntuación","text":"Puntos por subida según el mejor tiempo de las mangas."},{"title":"Formato","text":"Subidas cronometradas con varias mangas por prueba."},{"title":"Coches","text":"Coches homologados por categoría y copa."},{"title":"Reclamaciones","text":"Repeticiones obligatorias en caso de reclamación; comisarios independientes."}]')
on conflict (championship) do nothing;

-- ========== DAR PERMISOS (ejecútalo aparte, cambiando el correo) ==========
-- Administrador de todo:
--   insert into public.managers select id, 'all' from auth.users where email = 'correo@ejemplo.com' on conflict do nothing;
-- Responsable de un campeonato (ra = Rally, rs = Rallysprint, mo = Montaña):
--   insert into public.managers select id, 'ra' from auth.users where email = 'correo@ejemplo.com' on conflict do nothing;

-- ========== DIAGNÓSTICO (ejecútalo aparte cuando lo necesites) ==========
--   select email, email_confirmed_at, created_at from auth.users order by created_at desc;
--   update auth.users set email_confirmed_at = now() where email_confirmed_at is null;
