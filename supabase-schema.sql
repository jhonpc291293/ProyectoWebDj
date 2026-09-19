-- ============================================================================
--  VIP PAITA MIX · Pool de edits, remixes y mashups
--  Esquema completo para Supabase: roles, catálogo, membresías y descargas.
--
--  Cómo usarlo: Supabase → SQL Editor → New query → pega TODO → Run.
--  Es idempotente de verdad: puedes ejecutarlo las veces que quieras y jamás
--  toca tus tracks, tu marca, tus miembros, pagos o comunicados ya guardados.
--
--  ATENCIÓN: la primera vez que se corrió este script, reemplazó un esquema
--  muy anterior (el de una tienda de mezclas: products, gallery, orders). Esas
--  tablas viejas, si llegan a existir, se siguen limpiando por si acaso — pero
--  tracks, settings y plays YA NO se borran en cada corrida: son tu contenido real.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- 0. LIMPIEZA de la versión anterior (solo tablas de la tienda vieja, ya en desuso)
-- ---------------------------------------------------------------------------
drop view  if exists public.v_ventas_mes           cascade;
drop view  if exists public.v_top_productos        cascade;
drop view  if exists public.v_reproducciones       cascade;
drop view  if exists public.v_embudo_pistas        cascade;
drop view  if exists public.v_pedidos_pendientes   cascade;
drop table if exists public.orders                 cascade;
drop table if exists public.products               cascade;
drop table if exists public.gallery                cascade;

-- ---------------------------------------------------------------------------
-- 1. PERFILES Y ROLES
--    admin  = Ronald: todo el catálogo, miembros, pagos, planes
--    editor = los DJs del crew: solo sus propios tracks
--    member = suscriptores: descargan si su membresía está vigente
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id       uuid primary key references auth.users(id) on delete cascade,
  nombre   text default '',
  alias    text default '',              -- nombre artístico del DJ
  email    text default '',
  rol      text not null default 'member' check (rol in ('admin','editor','member')),
  telefono text default '',
  avatar   text default '',
  creado   timestamptz default now()
);
alter table public.profiles add column if not exists email text default '';

-- cada usuario nuevo de Supabase Auth obtiene su perfil automáticamente
create or replace function public.nuevo_perfil()
returns trigger language plpgsql security definer set search_path = public as $$
begin
    insert into public.profiles (id, nombre, email, telefono, rol)
    values (new.id,
          coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email,'@',1)),
      coalesce(new.email, ''),
          coalesce(new.raw_user_meta_data->>'telefono', ''),
          case when (select count(*) from public.profiles) = 0 then 'admin' else 'member' end)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists trg_nuevo_perfil on auth.users;
create trigger trg_nuevo_perfil after insert on auth.users
  for each row execute function public.nuevo_perfil();

-- ---------------------------------------------------------------------------
-- 2. FUNCIONES DE PERMISO
--    SECURITY DEFINER para que las políticas no se llamen a sí mismas.
-- ---------------------------------------------------------------------------
create or replace function public.mi_rol() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select rol from public.profiles where id = auth.uid()), 'anon');
$$;

create or replace function public.es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select public.mi_rol() = 'admin';
$$;

create or replace function public.es_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select public.mi_rol() in ('admin','editor');
$$;

-- (membresia_activa() se define en la sección 6, después de crear la tabla)

-- ---------------------------------------------------------------------------
-- 3. CONTENIDO DE LA MARCA
-- ---------------------------------------------------------------------------
create table if not exists public.settings (
  id          int primary key default 1,
  marca       text default 'VIP PAITA MIX',
  creador     text default 'Ronald Moscol',
  desde       int  default 2016,
  ciudad      text default 'Paita, Piura · Perú',
  claim       text default 'El pool de edits, remixes y mashups que suena en las pistas del norte.',
  hero_l1     text default 'EDITS QUE',
  hero_l2     text default 'LLENAN',
  hero_l3     text default 'LA PISTA',
  logo_url    text default '',
  hero_img    text default '',           -- imagen de portada del hero
  whatsapp    text default '51999999999',
  email       text default 'contacto@vippaitamix.com',
  moneda      text default 'S/',
  yape_nombre text default 'Ronald Moscol',
  yape_numero text default '999 999 999',
  pago_nota   text default 'Yapea o plinea al número y sube la captura. Activamos tu acceso el mismo día.',
  frases      jsonb default '["Edits","Remixes","Mashups","Intros","Acapellas","Cumbia","Reggaetón","Salsa","Tecnocumbia"]'::jsonb,
  hitos       jsonb default '[{"anio":"2016","texto":"Nace VIP PAITA MIX en Paita como grupo de intercambio entre DJs de la zona."},{"anio":"2019","texto":"El pool pasa de 5 a más de 40 DJs y se abre a todo Piura."},{"anio":"2022","texto":"Primer catálogo organizado por género y BPM, con lanzamientos semanales."},{"anio":"2026","texto":"Plataforma propia con membresías y descargas directas."}]'::jsonb,
  redes       jsonb default '{"instagram":"","facebook":"","tiktok":"","youtube":""}'::jsonb,
  tema        text default 'normal' check (tema in ('normal','halloween','navidad','ano-nuevo')),
  -- colores personalizados (hex, ej. "#08070b"): vacío = usa los del tema de temporada
  color_fondo      text default '',
  color_tarjetas   text default '',
  color_encabezado text default '',
  color_piepagina  text default '',
  color_texto      text default '',
  color_acento     text default '',
  -- tipografía personalizada (nombre exacto de Google Fonts): vacío = la de siempre
  fuente_titulos   text default '',
  fuente_texto     text default '',
  -- video del hero (para eventos puntuales): solo se muestra si video_activo = true.
  -- si hay archivo subido, ese manda; si no, se usa el link de YouTube.
  video_activo     boolean default false,
  video_url        text default '',
  video_archivo    text default '',
  actualizado timestamptz default now(),
  constraint settings_una_fila check (id = 1)
);

-- si "settings" ya existía de una instalación anterior (sin la columna "tema"),
-- se la agrega aquí sin tocar el resto de la fila
alter table public.settings add column if not exists tema text not null default 'normal';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'settings_tema_valido') then
    alter table public.settings add constraint settings_tema_valido
      check (tema in ('normal','halloween','navidad','ano-nuevo'));
  end if;
end $$;
alter table public.settings add column if not exists color_fondo      text not null default '';
alter table public.settings add column if not exists color_tarjetas   text not null default '';
alter table public.settings add column if not exists color_encabezado text not null default '';
alter table public.settings add column if not exists color_piepagina  text not null default '';
alter table public.settings add column if not exists color_texto      text not null default '';
alter table public.settings add column if not exists color_acento     text not null default '';
alter table public.settings add column if not exists fuente_titulos   text not null default '';
alter table public.settings add column if not exists fuente_texto     text not null default '';
alter table public.settings add column if not exists video_activo    boolean not null default false;
alter table public.settings add column if not exists video_url       text not null default '';
alter table public.settings add column if not exists video_archivo   text not null default '';

-- el crew que se muestra en la web (independiente de las cuentas de acceso)
create table if not exists public.crew (
  id      uuid primary key default gen_random_uuid(),
  orden   int  default 0,
  alias   text not null,
  nombre  text default '',
  cargo   text default 'DJ / Editor',
  email   text default '',
  bio     text default '',
  foto    text default '',
  ig      text default '',
  visible boolean default true,
  creado  timestamptz default now()
);
alter table public.crew add column if not exists email text default '';

-- comunicados del equipo: novedades, avisos de temporada, dinámicas nuevas...
-- cualquiera del equipo (admin o editor) publica; cada uno edita solo los suyos
create table if not exists public.comunicados (
  id       uuid primary key default gen_random_uuid(),
  titulo   text not null,
  cuerpo   text default '',
  imagen   text default '',                -- póster o gráfica, opcional
  autor_id uuid references public.profiles(id) on delete set null,
  autor    text default '',
  fijado   boolean default false,          -- se muestra primero, sin importar la fecha
  visible  boolean default true,
  creado   timestamptz default now()
);
create index if not exists idx_comunicados_creado on public.comunicados(creado desc);

-- ---------------------------------------------------------------------------
-- 4. CATÁLOGO
-- ---------------------------------------------------------------------------
create table if not exists public.tracks (
  id          uuid primary key default gen_random_uuid(),
  titulo      text not null,
  artista     text default '',                 -- artista original
  tipo        text default 'edit' check (tipo in ('edit','remix','mashup','intro','acapella','transicion')),
  genero      text default '',
  bpm         int,
  tonalidad   text default '',
  duracion    text default '',
  anio        int,
  portada     text default '',                 -- imagen pública
  preview     text default '',                 -- fragmento público (60-90 s)
  editor_id   uuid references public.profiles(id) on delete set null,
  editor      text default '',                 -- alias mostrado en la web
  editor_email text default '',                -- correo de la cuenta que subió el track
  gratis      boolean default false,           -- descargable por cualquier registrado
  precio      numeric(10,2) default 0,         -- > 0 = se puede comprar suelto, sin membresía
  destacado   boolean default false,
  visible     boolean default true,
  descargas   int default 0,
  creado      timestamptz default now()
);
-- si "tracks" ya existía de una instalación anterior (sin la columna "precio")
alter table public.tracks add column if not exists precio numeric(10,2) default 0;
alter table public.tracks add column if not exists editor_email text default '';

-- La ruta del archivo COMPLETO vive aparte: así ningún visitante puede leerla.
create table if not exists public.track_files (
  track_id uuid primary key references public.tracks(id) on delete cascade,
  ruta     text not null,                      -- ruta dentro del bucket privado
  peso_mb  numeric(10,2),
  formato  text default 'mp3'
);

-- compra suelta de una o varias canciones (sin necesitar membresía). El acceso
-- comprado no vence: queda disponible para siempre una vez aprobado el pago.
create table if not exists public.compras (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  monto        numeric(10,2) default 0,
  metodo       text default 'yape',
  comprobante  text default '',               -- ruta en bucket privado
  estado       text default 'pendiente' check (estado in ('pendiente','aprobada','rechazada')),
  aprobado_por uuid references public.profiles(id) on delete set null,
  creado       timestamptz default now()
);
create table if not exists public.compra_tracks (
  compra_id uuid not null references public.compras(id) on delete cascade,
  track_id  uuid not null references public.tracks(id) on delete cascade,
  precio    numeric(10,2) default 0,          -- precio al momento de comprar (por si luego cambia)
  primary key (compra_id, track_id)
);
create index if not exists idx_compras_user     on public.compras(user_id);
create index if not exists idx_compras_estado   on public.compras(estado);
create index if not exists idx_compra_tracks_tk on public.compra_tracks(track_id);

create index if not exists idx_tracks_tipo   on public.tracks(tipo);
create index if not exists idx_tracks_genero on public.tracks(genero);
create index if not exists idx_tracks_editor on public.tracks(editor_id);
create index if not exists idx_tracks_creado on public.tracks(creado desc);

-- ---------------------------------------------------------------------------
-- 5. MEMBRESÍAS
-- ---------------------------------------------------------------------------
create table if not exists public.plans (
  id            uuid primary key default gen_random_uuid(),
  orden         int default 0,
  nombre        text not null,
  dias          int  not null default 30,
  precio        numeric(10,2) not null default 0,
  descripcion   text default '',
  beneficios    jsonb default '[]'::jsonb,
  limite_diario int default 0,                 -- 0 = sin límite
  destacado     boolean default false,
  activo        boolean default true,
  creado        timestamptz default now()
);

-- track con contenido premium: solo lo descarga quien tenga un plan de este
-- precio o uno mayor (o lo haya comprado suelto). Vacío = cualquier membresía
-- activa, como hasta ahora. Se agrega aquí, después de "plans", porque la
-- columna referencia esa tabla.
alter table public.tracks add column if not exists plan_minimo_id uuid references public.plans(id) on delete set null;

create table if not exists public.memberships (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  plan_id       uuid references public.plans(id) on delete set null,
  plan_nombre   text default '',
  monto         numeric(10,2) default 0,
  metodo        text default 'yape',
  comprobante   text default '',               -- ruta en bucket privado
  estado        text default 'pendiente' check (estado in ('pendiente','activa','vencida','rechazada')),
  inicio        date,
  fin           date,
  notas         text default '',
  aprobado_por  uuid references public.profiles(id) on delete set null,
  creado        timestamptz default now()
);

create index if not exists idx_memb_user   on public.memberships(user_id);
create index if not exists idx_memb_estado on public.memberships(estado);

create table if not exists public.downloads (
  id       bigserial primary key,
  creado   timestamptz default now(),
  user_id  uuid references public.profiles(id) on delete set null,
  track_id uuid references public.tracks(id) on delete cascade
);
create index if not exists idx_dl_user  on public.downloads(user_id, creado desc);
create index if not exists idx_dl_track on public.downloads(track_id);

create table if not exists public.plays (
  id       bigserial primary key,
  creado   timestamptz default now(),
  track_id uuid references public.tracks(id) on delete cascade,
  user_id  uuid references public.profiles(id) on delete set null
);
create index if not exists idx_plays_track on public.plays(track_id);

-- solicitudes de booking / contacto
create table if not exists public.bookings (
  id      uuid primary key default gen_random_uuid(),
  creado  timestamptz default now(),
  nombre  text default '',
  email   text default '',
  tipo    text default '',
  fecha   date,
  lugar   text default '',
  mensaje text default '',
  estado  text default 'nuevo' check (estado in ('nuevo','cotizado','cerrado','perdido')),
  notas   text default ''
);

-- ---------------------------------------------------------------------------
-- 6. AUTOMATISMOS
-- ---------------------------------------------------------------------------

-- ¿este usuario puede descargar? (admin y editores del pool siempre pueden)
create or replace function public.membresia_activa() returns boolean
language sql stable security definer set search_path = public as $$
  select public.es_staff()
      or exists (select 1 from public.memberships m
                 where m.user_id = auth.uid()
                   and m.estado  = 'activa'
                   and m.fin    >= current_date);
$$;

-- medianoche de Perú expresada en instante UTC (Perú no usa horario de verano).
-- el cast a timestamp antes del segundo "at time zone" es obligatorio: sin él,
-- Postgres resuelve el otro overload del operador y el resultado queda mal
-- (trata la fecha como si ya fuera UTC en vez de hora local).
create or replace function public.inicio_dia_local() returns timestamptz
language sql stable as $$
  select (((now() at time zone 'America/Lima')::date)::timestamp) at time zone 'America/Lima';
$$;

-- solo el admin cambia roles, y nunca desde la tabla directamente
create or replace function public.cambiar_rol(p_user uuid, p_rol text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.es_admin() then raise exception 'Solo el administrador puede cambiar roles'; end if;
  if p_rol not in ('admin','editor','member') then raise exception 'Rol no válido: %', p_rol; end if;
  update public.profiles set rol = p_rol where id = p_user;
end $$;

-- contador de descargas por track
create or replace function public.sumar_descarga()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.tracks set descargas = coalesce(descargas,0) + 1 where id = new.track_id;
  return new;
end $$;
drop trigger if exists trg_sumar_descarga on public.downloads;
create trigger trg_sumar_descarga after insert on public.downloads
  for each row execute function public.sumar_descarga();

-- vence las membresías cuyo plazo ya pasó (se llama al abrir el panel)
create or replace function public.vencer_membresias() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.es_admin() then raise exception 'Solo el administrador puede ejecutar esta acción'; end if;
  update public.memberships set estado = 'vencida'
   where estado = 'activa' and fin < current_date;
  get diagnostics n = row_count;
  return n;
end $$;

-- aprobar un pago: activa la membresía y calcula el vencimiento.
-- si el miembro ya tenía una membresía vigente, los días se SUMAN a partir
-- de su fecha de vencimiento actual en vez de reiniciar desde hoy.
create or replace function public.aprobar_membresia(p_id uuid) returns public.memberships
language plpgsql security definer set search_path = public as $$
declare m public.memberships; d int; v_user uuid; v_base date;
begin
  if not public.es_admin() then raise exception 'Solo el administrador puede aprobar pagos'; end if;
  select mm.user_id, coalesce(p.dias, 30) into v_user, d
    from public.memberships mm left join public.plans p on p.id = mm.plan_id
   where mm.id = p_id;

  select greatest(current_date, coalesce(max(fin), current_date)) into v_base
    from public.memberships
   where user_id = v_user and estado = 'activa' and fin >= current_date;

  update public.memberships
     set estado = 'activa',
         inicio = current_date,
         fin    = v_base + coalesce(d, 30),
         aprobado_por = auth.uid()
   where id = p_id
  returning * into m;
  return m;
end $$;

-- aprobar una compra suelta: desbloquea esas canciones para siempre, sin vencimiento
create or replace function public.aprobar_compra(p_id uuid) returns public.compras
language plpgsql security definer set search_path = public as $$
declare c public.compras;
begin
  if not public.es_admin() then raise exception 'Solo el administrador puede aprobar compras'; end if;
  update public.compras set estado = 'aprobada', aprobado_por = auth.uid()
   where id = p_id
  returning * into c;
  return c;
end $$;

-- ¿el usuario ya compró y le aprobaron este track específico?
create or replace function public.compro_track(p_track uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.compra_tracks ct join public.compras c on c.id = ct.compra_id
     where ct.track_id = p_track and c.user_id = auth.uid() and c.estado = 'aprobada'
  );
$$;

-- lista de tracks que el usuario ya tiene comprados y aprobados (para pintar el catálogo)
create or replace function public.mis_compras() returns table(track_id uuid)
language sql stable security definer set search_path = public as $$
  select ct.track_id from public.compra_tracks ct join public.compras c on c.id = ct.compra_id
   where c.user_id = auth.uid() and c.estado = 'aprobada';
$$;

-- LA PUERTA DE VERDAD: decide si el usuario actual puede bajar este track,
-- tomando en cuenta el plan mínimo exigido por el track (si tiene uno).
-- Un track sin plan_minimo_id se comporta como siempre: cualquier membresía
-- activa alcanza. Con plan_minimo_id, hace falta un plan de ese precio o uno
-- mayor (o haberlo comprado suelto, o ser del staff, o que el track sea gratis).
create or replace function public.puede_descargar_track(p_track uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.es_staff()
      or exists (select 1 from public.tracks t where t.id = p_track and t.gratis)
      or public.compro_track(p_track)
      or exists (
        select 1
          from public.tracks t
          join public.memberships m on m.user_id = auth.uid()
                                    and m.estado = 'activa' and m.fin >= current_date
          left join public.plans mp on mp.id = m.plan_id
          left join public.plans rp on rp.id = t.plan_minimo_id
         where t.id = p_track
           and (t.plan_minimo_id is null or coalesce(mp.precio,0) >= coalesce(rp.precio,0))
      );
$$;

-- LA PUERTA DE LAS DESCARGAS: valida membresía, compra suelta y límite diario,
-- registra la descarga y devuelve la ruta del archivo.
create or replace function public.solicitar_descarga(p_track uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_ruta text; v_gratis boolean; v_limite int; v_hoy int; v_comprado boolean;
begin
  if auth.uid() is null then raise exception 'Necesitas iniciar sesión'; end if;

  select t.gratis, tf.ruta into v_gratis, v_ruta
    from public.tracks t join public.track_files tf on tf.track_id = t.id
   where t.id = p_track and t.visible;
  if v_ruta is null then raise exception 'Este track no tiene archivo disponible'; end if;

  v_comprado := public.compro_track(p_track);

  if not public.puede_descargar_track(p_track) then
    raise exception 'Esta canción necesita un plan superior activo, o comprarla por separado';
  end if;

  -- límite diario del plan (0 = sin límite); una compra suelta no gasta ese límite
  if not v_comprado then
    select coalesce(p.limite_diario, 0) into v_limite
      from public.memberships m join public.plans p on p.id = m.plan_id
     where m.user_id = auth.uid() and m.estado = 'activa' and m.fin >= current_date
     order by m.fin desc limit 1;

    if coalesce(v_limite,0) > 0 and not public.es_admin() then
      select count(*) into v_hoy from public.downloads
       where user_id = auth.uid() and creado >= public.inicio_dia_local();
      if v_hoy >= v_limite then
        raise exception 'Alcanzaste tu límite de % descargas por día', v_limite;
      end if;
    end if;
  end if;

  insert into public.downloads (user_id, track_id) values (auth.uid(), p_track);
  return v_ruta;
end $$;

-- resumen de la cuenta del miembro (para la web pública)
create or replace function public.mi_membresia() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select jsonb_build_object(
        -- si quedó marcada "activa" pero ya venció (todavía no pasa el barrido de
        -- vencer_membresias, que solo corre cuando el admin abre su panel), se
        -- reporta como vencida: así coincide con membresia_activa(), que es lo
        -- que de verdad decide el acceso a los archivos por RLS
        'estado', case when m.estado='activa' and m.fin < current_date then 'vencida' else m.estado end,
        'plan', coalesce(p.nombre, m.plan_nombre),
        'plan_precio', coalesce(p.precio, 0),
        'inicio', m.inicio, 'fin', m.fin,
        'dias_restantes', greatest(0, m.fin - current_date),
        'limite_diario', coalesce(p.limite_diario, 0),
        'descargas_hoy', (select count(*) from public.downloads d
                           where d.user_id = auth.uid() and d.creado >= public.inicio_dia_local()))
       from public.memberships m left join public.plans p on p.id = m.plan_id
      where m.user_id = auth.uid()
      order by case when m.estado='activa' and m.fin>=current_date then 0
                     when m.estado='pendiente' then 1 else 2 end,
               m.fin desc nulls last
      limit 1),
    jsonb_build_object('estado','ninguna'));
$$;

-- ---------------------------------------------------------------------------
-- 7. SEGURIDAD (RLS)
-- ---------------------------------------------------------------------------
alter table public.profiles    enable row level security;
alter table public.settings    enable row level security;
alter table public.crew        enable row level security;
alter table public.comunicados enable row level security;
alter table public.tracks      enable row level security;
alter table public.track_files enable row level security;
alter table public.plans       enable row level security;
alter table public.memberships enable row level security;
alter table public.downloads   enable row level security;
alter table public.plays       enable row level security;
alter table public.bookings    enable row level security;

do $$
declare t text;
begin
  -- contenido público: cualquiera lee lo visible
  foreach t in array array['settings','crew','tracks','plans','comunicados'] loop
    execute format('drop policy if exists "lectura publica" on public.%I', t);
    execute format('drop policy if exists "admin total"     on public.%I', t);
    if t = 'settings' then
      execute format('create policy "lectura publica" on public.%I for select to anon, authenticated using (true)', t);
    elsif t = 'plans' then
      execute format('create policy "lectura publica" on public.%I for select to anon, authenticated using (activo)', t);
    else
      execute format('create policy "lectura publica" on public.%I for select to anon, authenticated using (visible)', t);
    end if;
    execute format('create policy "admin total" on public.%I for all to authenticated using (public.es_admin()) with check (public.es_admin())', t);
  end loop;
end $$;

-- perfiles: cada uno ve y edita el suyo; el admin ve y edita todos
drop policy if exists "ve su perfil"      on public.profiles;
drop policy if exists "edita su perfil"   on public.profiles;
drop policy if exists "admin ve perfiles" on public.profiles;
create policy "ve su perfil"      on public.profiles for select to authenticated using (id = auth.uid());
create policy "edita su perfil"   on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
create policy "admin ve perfiles" on public.profiles for all to authenticated
  using (public.es_admin()) with check (public.es_admin());
-- Nadie puede ascenderse: la columna "rol" no es actualizable desde la API
-- (ver los permisos de columna en la sección 8). Se cambia con cambiar_rol().

-- catálogo: el editor solo puede consultar y gestionar SUS tracks
drop policy if exists "editor crea"  on public.tracks;
drop policy if exists "editor edita" on public.tracks;
drop policy if exists "editor borra" on public.tracks;
drop policy if exists "staff ve todo" on public.tracks;
drop policy if exists "admin ve tracks" on public.tracks;
drop policy if exists "editor ve sus tracks" on public.tracks;
create policy "admin ve tracks" on public.tracks for select to authenticated
  using (public.es_admin());
create policy "editor ve sus tracks" on public.tracks for select to authenticated
  using (public.mi_rol() = 'editor' and editor_id = auth.uid());
create policy "editor crea"  on public.tracks for insert to authenticated
  with check (public.mi_rol() = 'editor' and editor_id = auth.uid());
create policy "editor edita" on public.tracks for update to authenticated
  using (public.mi_rol() = 'editor' and editor_id = auth.uid())
  with check (editor_id = auth.uid());
create policy "editor borra" on public.tracks for delete to authenticated
  using (public.mi_rol() = 'editor' and editor_id = auth.uid());

-- comunicados: cualquiera del equipo publica; cada uno edita solo los suyos (el admin, todos)
drop policy if exists "editor crea comunicado"  on public.comunicados;
drop policy if exists "editor edita comunicado" on public.comunicados;
drop policy if exists "editor borra comunicado" on public.comunicados;
drop policy if exists "staff ve comunicados"     on public.comunicados;
create policy "staff ve comunicados" on public.comunicados for select to authenticated using (public.es_staff());
create policy "editor crea comunicado"  on public.comunicados for insert to authenticated
  with check (public.mi_rol() = 'editor' and autor_id = auth.uid());
create policy "editor edita comunicado" on public.comunicados for update to authenticated
  using (public.mi_rol() = 'editor' and autor_id = auth.uid())
  with check (autor_id = auth.uid());
create policy "editor borra comunicado" on public.comunicados for delete to authenticated
  using (public.mi_rol() = 'editor' and autor_id = auth.uid());

-- rutas de archivo: según puede_descargar_track (respeta el plan mínimo del
-- track), gratis, comprado suelto, el dueño o el admin
drop policy if exists "miembros leen rutas" on public.track_files;
drop policy if exists "staff gestiona rutas" on public.track_files;
create policy "miembros leen rutas" on public.track_files for select to authenticated
  using (public.puede_descargar_track(track_id)
         or exists (select 1 from public.tracks t where t.id = track_id and t.editor_id = auth.uid()));
create policy "staff gestiona rutas" on public.track_files for all to authenticated
  using (public.es_admin()
         or exists (select 1 from public.tracks t where t.id = track_id and t.editor_id = auth.uid()))
  with check (public.es_admin()
         or exists (select 1 from public.tracks t where t.id = track_id and t.editor_id = auth.uid()));

-- membresías: cada miembro crea y ve las suyas; solo el admin cambia estados
drop policy if exists "crea su solicitud" on public.memberships;
drop policy if exists "ve sus membresias" on public.memberships;
drop policy if exists "admin membresias"  on public.memberships;
create policy "crea su solicitud" on public.memberships for insert to authenticated
  with check (user_id = auth.uid() and estado = 'pendiente');
create policy "ve sus membresias" on public.memberships for select to authenticated
  using (user_id = auth.uid());
create policy "admin membresias"  on public.memberships for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- compras sueltas: cada quien crea y ve las suyas; solo el admin cambia estados
alter table public.compras       enable row level security;
alter table public.compra_tracks enable row level security;
drop policy if exists "crea su compra" on public.compras;
drop policy if exists "ve sus compras" on public.compras;
drop policy if exists "admin compras"  on public.compras;
create policy "crea su compra" on public.compras for insert to authenticated
  with check (user_id = auth.uid() and estado = 'pendiente');
create policy "ve sus compras" on public.compras for select to authenticated
  using (user_id = auth.uid());
create policy "admin compras"  on public.compras for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- líneas de la compra: solo se leen/crean a través de una compra propia
drop policy if exists "crea lineas compra"  on public.compra_tracks;
drop policy if exists "ve lineas compra"    on public.compra_tracks;
drop policy if exists "admin lineas compra" on public.compra_tracks;
create policy "crea lineas compra" on public.compra_tracks for insert to authenticated
  with check (exists (select 1 from public.compras c
                       where c.id = compra_id and c.user_id = auth.uid() and c.estado = 'pendiente'));
create policy "ve lineas compra" on public.compra_tracks for select to authenticated
  using (exists (select 1 from public.compras c where c.id = compra_id and c.user_id = auth.uid()));
create policy "admin lineas compra" on public.compra_tracks for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- descargas y reproducciones
drop policy if exists "ve sus descargas" on public.downloads;
drop policy if exists "staff descargas"  on public.downloads;
create policy "ve sus descargas" on public.downloads for select to authenticated using (user_id = auth.uid());
create policy "staff descargas"  on public.downloads for select to authenticated using (public.es_staff());

drop policy if exists "registra play" on public.plays;
drop policy if exists "staff plays"   on public.plays;
create policy "registra play" on public.plays for insert to anon, authenticated
  with check (exists (select 1 from public.tracks t where t.id = track_id and t.visible));
create policy "staff plays"   on public.plays for select to authenticated using (public.es_staff());

-- booking
drop policy if exists "crea booking"  on public.bookings;
drop policy if exists "admin booking" on public.bookings;
create policy "crea booking"  on public.bookings for insert to anon, authenticated with check (true);
create policy "admin booking" on public.bookings for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- ---------------------------------------------------------------------------
-- 8. PERMISOS DE TABLA
-- ---------------------------------------------------------------------------
grant usage on schema public to anon, authenticated;

grant select on public.settings, public.crew, public.tracks, public.plans, public.comunicados to anon, authenticated;
grant insert on public.plays, public.bookings to anon, authenticated;
grant usage, select on sequence public.plays_id_seq to anon, authenticated;
grant usage, select on sequence public.downloads_id_seq to anon, authenticated;

grant select, insert, update, delete on
  public.settings, public.crew, public.tracks, public.track_files,
  public.plans, public.memberships, public.bookings, public.comunicados,
  public.compras, public.compra_tracks to authenticated;
grant select on public.downloads, public.plays to authenticated;

-- perfiles: se puede editar el nombre y el contacto, NUNCA la columna "rol"
grant select, insert, delete on public.profiles to authenticated;
grant update (nombre, alias, telefono, avatar) on public.profiles to authenticated;

grant execute on function public.solicitar_descarga(uuid), public.mi_membresia(),
  public.membresia_activa(), public.mi_rol(), public.es_admin(), public.es_staff(),
  public.compro_track(uuid), public.mis_compras(), public.puede_descargar_track(uuid) to authenticated;
grant execute on function public.aprobar_membresia(uuid), public.vencer_membresias(),
  public.cambiar_rol(uuid, text), public.aprobar_compra(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. ARCHIVOS (Storage)
--    portadas / previews = públicos      descargas / comprobantes = privados
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public) values
  ('portadas','portadas',true), ('previews','previews',true),
  ('descargas','descargas',false), ('comprobantes','comprobantes',false)
on conflict (id) do update set public = excluded.public;

drop policy if exists "lee publicos"        on storage.objects;
drop policy if exists "staff sube"          on storage.objects;
drop policy if exists "staff actualiza"     on storage.objects;
drop policy if exists "staff borra"         on storage.objects;
drop policy if exists "descarga miembros"   on storage.objects;
drop policy if exists "sube comprobante"    on storage.objects;
drop policy if exists "lee comprobante"     on storage.objects;

create policy "lee publicos" on storage.objects for select to anon, authenticated
  using (bucket_id in ('portadas','previews'));

create policy "staff sube" on storage.objects for insert to authenticated
  with check (bucket_id in ('portadas','previews','descargas') and public.es_staff());
-- un editor solo actualiza o borra lo que subió él mismo; el admin, cualquier archivo
create policy "staff actualiza" on storage.objects for update to authenticated
  using (bucket_id in ('portadas','previews','descargas') and public.es_staff()
         and (public.es_admin() or owner = auth.uid()));
create policy "staff borra" on storage.objects for delete to authenticated
  using (bucket_id in ('portadas','previews','descargas') and public.es_staff()
         and (public.es_admin() or owner = auth.uid()));

-- el archivo completo solo se firma si puede_descargar_track lo permite
-- (respeta el plan mínimo del track, gratis, o comprado suelto)
create policy "descarga miembros" on storage.objects for select to authenticated
  using (bucket_id = 'descargas' and exists (
    select 1 from public.track_files tf
     where tf.ruta = storage.objects.name and public.puede_descargar_track(tf.track_id)
  ));

create policy "sube comprobante" on storage.objects for insert to authenticated
  with check (bucket_id = 'comprobantes' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "lee comprobante" on storage.objects for select to authenticated
  using (bucket_id = 'comprobantes' and (owner = auth.uid() or public.es_admin()));

-- ---------------------------------------------------------------------------
-- 10. VISTAS PARA ANÁLISIS (respetan RLS; solo staff/admin las lee)
-- ---------------------------------------------------------------------------
create or replace view public.v_ingresos_mes with (security_invoker = on) as
select date_trunc('month', creado)::date as mes,
       count(*) as membresias, sum(monto) as ingresos,
       round(avg(monto),2) as ticket_promedio
from public.memberships where estado in ('activa','vencida')
group by 1 order by 1 desc;

create or replace view public.v_top_tracks with (security_invoker = on) as
select t.id, t.titulo, t.artista, t.tipo, t.genero, t.bpm, t.editor,
       t.descargas,
       (select count(*) from public.plays p where p.track_id = t.id) as reproducciones
from public.tracks t order by t.descargas desc;

create or replace view public.v_editores with (security_invoker = on) as
select coalesce(nullif(t.editor,''), 'sin asignar') as editor,
       count(*) as tracks, sum(t.descargas) as descargas,
       max(t.creado) as ultimo_aporte
from public.tracks t group by 1 order by descargas desc;

create or replace view public.v_miembros with (security_invoker = on) as
select p.id, p.nombre, p.alias, p.telefono, m.estado, m.plan_nombre, m.inicio, m.fin,
       greatest(0, m.fin - current_date) as dias_restantes,
      (select count(*) from public.downloads d where d.user_id = p.id) as descargas_totales,
      p.email
from public.profiles p
left join public.memberships m on m.user_id = p.id
     and m.id = (select id from public.memberships x where x.user_id = p.id
                 order by case x.estado when 'activa' then 0 when 'pendiente' then 1 else 2 end,
                          x.fin desc nulls last limit 1)
where p.rol = 'member';

revoke all on public.v_ingresos_mes, public.v_top_tracks, public.v_editores, public.v_miembros from anon;
grant select on public.v_ingresos_mes, public.v_top_tracks, public.v_editores, public.v_miembros to authenticated;

-- ---------------------------------------------------------------------------
-- 11. DATOS INICIALES
-- ---------------------------------------------------------------------------
insert into public.settings (id) values (1) on conflict (id) do nothing;

-- perfiles para los usuarios que ya existían; el más antiguo queda admin
update public.profiles p set email = coalesce(u.email, '')
from auth.users u where u.id = p.id and coalesce(p.email, '') = '';

insert into public.profiles (id, nombre, email, rol)
select u.id, coalesce(u.raw_user_meta_data->>'nombre', split_part(u.email,'@',1)), coalesce(u.email, ''), 'member'
from auth.users u
where not exists (select 1 from public.profiles p where p.id = u.id);

update public.profiles set rol = 'admin'
 where id = (select id from auth.users order by created_at asc limit 1)
   and not exists (select 1 from public.profiles where rol = 'admin');

insert into public.plans (orden, nombre, dias, precio, descripcion, beneficios, limite_diario, destacado)
select * from (values
  (1,'Semanal',  7,  15.00, 'Para probar el pool una semana completa.',
     '["Acceso a todo el catálogo","Descargas ilimitadas","Novedades de la semana"]'::jsonb, 0, false),
  (2,'Mensual', 30,  40.00, 'El plan que usa la mayoría del crew.',
     '["Acceso a todo el catálogo","Descargas ilimitadas","Lanzamientos semanales","Soporte por WhatsApp"]'::jsonb, 0, true),
  (3,'Trimestral', 90, 100.00, 'Tres meses al precio de dos y medio.',
     '["Todo lo del plan Mensual","Ahorro de S/ 20","Pedidos de edits a medida"]'::jsonb, 0, false),
  (4,'Anual', 365, 320.00, 'Para el DJ que trabaja todas las semanas.',
     '["Todo lo del plan Trimestral","Dos meses gratis","Acceso anticipado a estrenos"]'::jsonb, 0, false)
) as v where not exists (select 1 from public.plans);

insert into public.crew (orden, alias, nombre, cargo, bio)
select * from (values
  (1,'DJ Ronald','Ronald Moscol','Fundador · Director', 'Creador de VIP PAITA MIX en 2016. Cumbia, tecnocumbia y todo lo que mueve el norte.'),
  (2,'DJ Invitado 2','','DJ / Editor',''),
  (3,'DJ Invitado 3','','DJ / Editor',''),
  (4,'DJ Invitado 4','','DJ / Editor',''),
  (5,'DJ Invitado 5','','DJ / Editor','')
) as v where not exists (select 1 from public.crew);

insert into public.tracks (titulo, artista, tipo, genero, bpm, tonalidad, duracion, anio, editor, gratis, destacado)
select * from (values
  ('Ojitos Hechiceros (VIP Edit)',   'Sensación',        'edit',     'Cumbia',       98,'Am','3:40',2026,'DJ Ronald', true,  true),
  ('Cariñito (Tribal Remix)',        'Los Hijos del Sol','remix',    'Tecnocumbia', 128,'Gm','4:05',2026,'DJ Ronald', false, true),
  ('Mix Salsa Brava · Mashup',       'Varios',           'mashup',   'Salsa',        95,'Dm','5:12',2026,'DJ Ronald', false, false),
  ('Intro Perreo 2026',              'Varios',           'intro',    'Reggaetón',    96,'F#m','1:20',2026,'DJ Ronald',false, false),
  ('Acapella · Que Bonito',          'Rocío Dúrcal',     'acapella', 'Cumbia',       92,'C','2:10', 2026,'DJ Ronald', false, false),
  ('Transición Cumbia → Reggaetón',  'Varios',           'transicion','Cumbia',      98,'Am','1:45',2026,'DJ Ronald', false, false)
) as v where not exists (select 1 from public.tracks);

-- Listo.
-- Siguiente paso: Authentication → Users → Add user para cada DJ,
-- y en el panel (Editores) cambia su rol a "editor".
