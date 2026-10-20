-- Presupuestos 3D: negocios compartidos
-- Pega todo este texto en el SQL Editor de Supabase y toca "Run".

create table public.businesses (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 120),
  invite_code text not null unique,
  created_by uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.members (
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  email text,
  joined_at timestamptz not null default now(),
  primary key (business_id, user_id)
);
create index members_user_idx on public.members (user_id);

-- Un registro por presupuesto, trabajo, filamento en stock, pieza en stock y datos del negocio
create table public.records (
  business_id uuid not null references public.businesses(id) on delete cascade,
  kind text not null check (kind in ('quote', 'job', 'fstock', 'pstock', 'settings')),
  id text not null check (char_length(id) between 1 and 80),
  data jsonb not null default '{}'::jsonb,
  deleted boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  primary key (business_id, kind, id)
);
create index records_sync_idx on public.records (business_id, updated_at);

-- La hora de cada cambio la pone el servidor, para que la sincronización sea confiable
create function public.touch_record() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;
create trigger records_touch before insert or update on public.records
for each row execute function public.touch_record();

create function public.is_member(b uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.members m where m.business_id = b and m.user_id = (select auth.uid()));
$$;

create function public.is_owner(b uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.members m where m.business_id = b and m.user_id = (select auth.uid()) and m.role = 'owner');
$$;

alter table public.businesses enable row level security;
alter table public.members enable row level security;
alter table public.records enable row level security;
revoke all on public.businesses, public.members, public.records from anon;

create policy "Socios ven su negocio" on public.businesses for select to authenticated using (public.is_member(id));
create policy "El dueño cambia el nombre" on public.businesses for update to authenticated using (public.is_owner(id)) with check (public.is_owner(id));
create policy "El dueño borra el negocio" on public.businesses for delete to authenticated using (public.is_owner(id));

create policy "Socios ven a los socios" on public.members for select to authenticated using (public.is_member(business_id));

create policy "Socios leen los registros" on public.records for select to authenticated using (public.is_member(business_id));
create policy "Socios crean registros" on public.records for insert to authenticated with check (public.is_member(business_id));
create policy "Socios editan registros" on public.records for update to authenticated using (public.is_member(business_id)) with check (public.is_member(business_id));

-- Código de invitación legible, por ejemplo 3FA9-C21B
create function public.make_invite_code() returns text
language plpgsql set search_path = '' as $$
declare
  h text;
  code text;
begin
  loop
    h := upper(md5(gen_random_uuid()::text || clock_timestamp()::text));
    code := substr(h, 1, 4) || '-' || substr(h, 5, 4);
    exit when not exists (select 1 from public.businesses where invite_code = code);
  end loop;
  return code;
end $$;

create function public.create_business(p_name text) returns public.businesses
language plpgsql security definer set search_path = '' as $$
declare
  b public.businesses;
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Necesitas iniciar sesión'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Ponle un nombre al negocio'; end if;
  insert into public.businesses (name, invite_code, created_by)
  values (left(trim(p_name), 120), public.make_invite_code(), uid) returning * into b;
  insert into public.members (business_id, user_id, role, email)
  values (b.id, uid, 'owner', (select u.email from auth.users u where u.id = uid));
  return b;
end $$;

create function public.join_business(p_code text) returns public.businesses
language plpgsql security definer set search_path = '' as $$
declare
  b public.businesses;
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Necesitas iniciar sesión'; end if;
  select * into b from public.businesses where invite_code = upper(trim(p_code));
  if not found then raise exception 'Ese código no corresponde a ningún negocio'; end if;
  insert into public.members (business_id, user_id, role, email)
  values (b.id, uid, 'member', (select u.email from auth.users u where u.id = uid))
  on conflict (business_id, user_id) do nothing;
  return b;
end $$;

create function public.leave_business(p_business uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Necesitas iniciar sesión'; end if;
  delete from public.members where business_id = p_business and user_id = uid;
  -- Si se fue el dueño, el socio más antiguo pasa a ser dueño
  if not exists (select 1 from public.members where business_id = p_business and role = 'owner') then
    update public.members set role = 'owner'
    where (business_id, user_id) = (
      select m.business_id, m.user_id from public.members m where m.business_id = p_business order by m.joined_at limit 1
    );
  end if;
  -- Si no queda nadie, el negocio se borra
  delete from public.businesses b where b.id = p_business
    and not exists (select 1 from public.members m where m.business_id = p_business);
end $$;

create function public.remove_member(p_business uuid, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_owner(p_business) then raise exception 'Solo el dueño puede quitar socios'; end if;
  if p_user = auth.uid() then raise exception 'Para irte, usa Salir del negocio'; end if;
  delete from public.members where business_id = p_business and user_id = p_user;
end $$;

create function public.new_invite_code(p_business uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare
  code text;
begin
  if not public.is_owner(p_business) then raise exception 'Solo el dueño puede cambiar el código'; end if;
  code := public.make_invite_code();
  update public.businesses set invite_code = code where id = p_business;
  return code;
end $$;

revoke execute on function public.touch_record(), public.is_member(uuid), public.is_owner(uuid), public.make_invite_code(),
  public.create_business(text), public.join_business(text), public.leave_business(uuid),
  public.remove_member(uuid, uuid), public.new_invite_code(uuid) from public, anon;
grant execute on function public.is_member(uuid), public.is_owner(uuid),
  public.create_business(text), public.join_business(text), public.leave_business(uuid),
  public.remove_member(uuid, uuid), public.new_invite_code(uuid) to authenticated;
