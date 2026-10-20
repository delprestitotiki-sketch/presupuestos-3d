-- Presupuestos 3D: aprobación de socios
-- Quien se une con el código queda pendiente hasta que el dueño lo apruebe desde la app.
-- Pega todo este texto en el SQL Editor de Supabase y toca "Run".

alter table public.members add column approved boolean not null default true;

create or replace function public.is_member(b uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.members m where m.business_id = b and m.user_id = (select auth.uid()) and m.approved);
$$;

create policy "Cada uno ve su propia solicitud" on public.members for select to authenticated using (user_id = (select auth.uid()));

create or replace function public.join_business(p_code text) returns public.businesses
language plpgsql security definer set search_path = '' as $$
declare
  b public.businesses;
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Necesitas iniciar sesión'; end if;
  select * into b from public.businesses where invite_code = upper(trim(p_code));
  if not found then raise exception 'Ese código no corresponde a ningún negocio'; end if;
  insert into public.members (business_id, user_id, role, email, approved)
  values (b.id, uid, 'member', (select u.email from auth.users u where u.id = uid), false)
  on conflict (business_id, user_id) do nothing;
  return b;
end $$;

create function public.approve_member(p_business uuid, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_owner(p_business) then raise exception 'Solo el dueño puede aprobar socios'; end if;
  update public.members set approved = true where business_id = p_business and user_id = p_user;
end $$;

create or replace function public.leave_business(p_business uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Necesitas iniciar sesión'; end if;
  delete from public.members where business_id = p_business and user_id = uid;
  -- Si se fue el dueño, el socio aprobado más antiguo pasa a ser dueño
  if not exists (select 1 from public.members where business_id = p_business and role = 'owner') then
    update public.members set role = 'owner'
    where (business_id, user_id) = (
      select m.business_id, m.user_id from public.members m
      where m.business_id = p_business and m.approved order by m.joined_at limit 1
    );
  end if;
  -- Si no queda ningún socio aprobado, el negocio se borra (con sus solicitudes pendientes)
  delete from public.businesses b where b.id = p_business
    and not exists (select 1 from public.members m where m.business_id = p_business and m.approved);
end $$;

revoke execute on function public.approve_member(uuid, uuid) from public, anon;
grant execute on function public.approve_member(uuid, uuid) to authenticated;
