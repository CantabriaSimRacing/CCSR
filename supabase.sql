-- Cantabria Sim Racing · base de datos completa (reglamentos, permisos, perfiles)
-- Se puede ejecutar entero cuantas veces haga falta: no da error si algo ya existe.
-- Pégalo en Supabase > SQL Editor y pulsa Run (si avisa de "destructive operation", confirma:
-- solo recrea las políticas y disparadores).

-- ========== TABLAS ==========
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

-- ========== PERMISOS ==========
-- ¿Puede el usuario actual editar este campeonato? ('all' = administrador)
create or replace function public.can_edit(c text) returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.managers
                 where user_id = auth.uid() and championship in (c, 'all'));
$$;

drop policy if exists "ver mis permisos" on public.managers;
create policy "ver mis permisos" on public.managers for select to authenticated using (user_id = auth.uid());

drop policy if exists "reglamentos públicos" on public.rules;
create policy "reglamentos públicos" on public.rules for select to anon, authenticated using (true);

drop policy if exists "crear si eres responsable" on public.rules;
create policy "crear si eres responsable" on public.rules for insert to authenticated with check (public.can_edit(championship));

drop policy if exists "editar si eres responsable" on public.rules;
create policy "editar si eres responsable" on public.rules for update to authenticated using (public.can_edit(championship)) with check (public.can_edit(championship));

drop policy if exists "ver historial si eres responsable" on public.rules_history;
create policy "ver historial si eres responsable" on public.rules_history for select to authenticated using (public.can_edit(championship));

drop policy if exists "ver mi perfil" on public.profiles;
create policy "ver mi perfil" on public.profiles for select to authenticated using (id = auth.uid());

drop policy if exists "administradores ven perfiles" on public.profiles;
create policy "administradores ven perfiles" on public.profiles for select to authenticated using (public.can_edit('all'));

drop policy if exists "editar mi perfil" on public.profiles;
create policy "editar mi perfil" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- ========== HISTORIAL DE REGLAMENTOS ==========
create or replace function public.rules_audit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.rules_history (championship, content, changed_by) values (old.championship, old.content, auth.uid());
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;

drop trigger if exists rules_audit_trg on public.rules;
create trigger rules_audit_trg before update on public.rules for each row execute function public.rules_audit();

-- ========== PERFIL AL REGISTRARSE ==========
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
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
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

-- Perfil vacío para las cuentas que ya existían
insert into public.profiles (id) select id from auth.users on conflict do nothing;

-- ========== REGLAMENTOS INICIALES (no sobrescribe los que ya editaste) ==========
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
