-- Presupuestos 3D: tienda de Macrotec (pegamentos, repuestos, pinturas y resinas).
-- La base de datos lee cada día los listados públicos de macrotec.com.uy y guarda los productos
-- en public.shop_items (lectura pública, nadie puede escribir desde la app).

create extension if not exists http with schema extensions;
create extension if not exists pg_cron;

-- La extensión http queda en el esquema extensions (como la instala Supabase). La API pública no expone ese
-- esquema, así que la app no puede usarla; solo la llama private.shop_refresh().
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p
    join pg_depend d on d.objid = p.oid and d.deptype = 'e'
    join pg_extension e on e.oid = d.refobjid and e.extname = 'http'
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists public.shop_items (
  id text primary key,                         -- ruta del producto en macrotec.com.uy
  k text not null check (k in ('peg', 'rep', 'pin', 'res')),
  g text not null,                             -- listado donde apareció primero (marca o línea)
  n text not null,                             -- nombre
  p numeric not null check (p > 0),            -- precio U$S
  o numeric not null default 0,                -- precio tachado
  f boolean not null default false,            -- "Desde" (precio según variante)
  img text,                                    -- foto en i.aw.uy/macrotec/
  pid integer,
  buy boolean not null default true,           -- el listado muestra "Comprar"
  active boolean not null default true,        -- apareció en la última revisión
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  changed_at timestamptz not null default now()
);
alter table public.shop_items enable row level security;
create policy "Lectura pública de la tienda" on public.shop_items for select to anon, authenticated using (true);
revoke insert, update, delete, truncate, references, trigger on public.shop_items from anon, authenticated;

create table if not exists private.shop_sources (
  path text primary key, k text not null, g text not null, ord int not null
);
insert into private.shop_sources (path, k, g, ord) values
  ('adhesivos-3dlac', 'peg', '3DLAC', 10),
  ('resinas', 'res', 'Resinas', 20),
  ('repuestos-impresoras3d-creality', 'rep', 'Creality', 30),
  ('bambu-lab-imporesora3d-repuestos-y-accesorios', 'rep', 'Bambu Lab', 31),
  ('flashforge-repuestos-y-accesorios', 'rep', 'Flashforge', 32),
  ('mingda-impresora3d-carteleria-repuestos-y-accesorios', 'rep', 'Mingda', 33),
  ('set-de-pinturas-vallejo', 'pin', 'Sets', 40),
  ('primers', 'pin', 'Imprimaciones', 41),
  ('auxiliares', 'pin', 'Auxiliares', 42),
  ('model-color-vallejo', 'pin', 'Model Color', 50),
  ('model-air-vallejo', 'pin', 'Model Air', 51),
  ('game-color-vallejo', 'pin', 'Game Color', 52),
  ('game-air-vallejo', 'pin', 'Game Air', 53),
  ('xpress-color-vallejo', 'pin', 'Xpress Color', 54),
  ('mecha-color-vallejo', 'pin', 'Mecha Color', 55),
  ('metal-color-vallejo', 'pin', 'Metal Color', 56),
  ('liquid-metal-vallejo', 'pin', 'Liquid Metal', 57),
  ('true-metallic-metal', 'pin', 'True Metallic Metal', 58),
  ('premium-color', 'pin', 'Premium Color', 59),
  ('weathering-fx-vallejo', 'pin', 'Weathering FX', 60),
  ('pigments-fx-vallejo', 'pin', 'Pigments FX', 61),
  ('wash-fx-vallejo', 'pin', 'Wash FX', 62),
  ('diorama-fx-vallejo', 'pin', 'Diorama FX', 63),
  ('hobby-paint-spray-vallejo', 'pin', 'Aerosoles', 64),
  ('panzer-aces', 'pin', 'Panzer Aces', 65),
  ('studio-acrylic', 'pin', 'Studio Acrylic', 66),
  ('pinturas-acrilicas-vallejo', 'pin', 'Otras pinturas', 90)
on conflict (path) do update set k = excluded.k, g = excluded.g, ord = excluded.ord;

create table if not exists private.shop_runs (
  id bigserial primary key, started_at timestamptz not null, finished_at timestamptz,
  pages int, seen int, new_items int, price_changes int, gone int, errors text[]
);

create or replace function private.html_decode(t text) returns text
language plpgsql immutable set search_path = '' as $$
declare m text[]; c int;
begin
  if t is null then return null; end if;
  loop
    m := regexp_match(t, '&#([xX])([0-9A-Fa-f]{1,6});');
    exit when m is null;
    c := ('x' || lpad(m[2], 8, '0'))::bit(32)::int;
    t := replace(t, '&#' || m[1] || m[2] || ';', case when c between 1 and 1114111 then chr(c) else '' end);
  end loop;
  loop
    m := regexp_match(t, '&#([0-9]{1,7});');
    exit when m is null;
    c := m[1]::int;
    t := replace(t, '&#' || m[1] || ';', case when c between 1 and 1114111 then chr(c) else '' end);
  end loop;
  t := replace(replace(replace(replace(replace(t, '&quot;', '"'), '&#39;', ''''), '&lt;', '<'), '&gt;', '>'), '&nbsp;', ' ');
  return btrim(regexp_replace(replace(t, '&amp;', '&'), '\s+', ' ', 'g'));
end $$;

create or replace function private.parse_price(t text) returns numeric
language plpgsql immutable set search_path = '' as $$
declare s text;
begin
  if t is null then return null; end if;
  s := regexp_replace(t, '[^0-9.,]', '', 'g');
  s := btrim(s, '.,');
  if s = '' then return null; end if;
  if s like '%,%' then s := replace(replace(s, '.', ''), ',', '.');
  elsif s ~ '^\d{1,3}(\.\d{3})+$' then s := replace(s, '.', '');
  end if;
  return s::numeric;
exception when others then return null;
end $$;

create or replace function private.shop_parse(body text)
returns table (pid int, slug text, name text, price numeric, old numeric, fromp boolean, img text, buy boolean)
language sql immutable set search_path = '' as $$
  select (regexp_match(c, '^(\d+)"'))[1]::int,
         (regexp_match(c, '<h2 class="product-title">\s*<a href="/([^"?#]+)"'))[1],
         private.html_decode((regexp_match(c, '<h2 class="product-title">\s*<a href="[^"]*">([^<]*)</a>'))[1]),
         private.parse_price((regexp_match(c, 'class="price actual-price">([^<]*)<'))[1]),
         coalesce(private.parse_price((regexp_match(c, 'class="price old-price">([^<]*)<'))[1]), 0),
         coalesce((regexp_match(c, 'class="price actual-price">([^<]*)<'))[1] ~* 'desde', false),
         (regexp_match(c, 'data-lazyloadsrc="https://i\.aw\.uy/macrotec/([^"]+)"'))[1],
         c ~ 'product-box-add-to-cart-button'
  from unnest((string_to_array(body, '<div class="product-item" data-productid="'))[2:]) as c
$$;

-- Recorre todos los listados. only_path: revisar solo ese listado (pruebas); en ese caso no marca nada como retirado.
create or replace function private.shop_refresh(only_path text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  src record; r record; o record; resp record;
  pg int; n_page int; ids text; prev_ids text;
  n_pages int := 0; n_seen int := 0; prev_active int; run_id bigint;
  failed text[] := '{}'; changes text[] := '{}';
  n_new int := 0; n_price int := 0; n_gone int := 0;
  today text := to_char(now() at time zone 'America/Montevideo', 'DD/MM/YYYY');
  meta jsonb; counts jsonb;
  fmt constant text := 'FM999990.99';
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');
  select count(*) into prev_active from public.shop_items where active;
  insert into private.shop_runs (started_at) values (clock_timestamp()) returning id into run_id;

  for src in select * from private.shop_sources where only_path is null or path = only_path order by ord loop
    prev_ids := null;
    pg := 0;
    loop
      pg := pg + 1;
      exit when pg > 40;
      begin
        select status, content into resp
        from extensions.http_get('https://www.macrotec.com.uy/' || src.path || '?pagesize=36&orderby=5&pagenumber=' || pg);
      exception when others then
        failed := failed || (src.path || ' p' || pg || ': ' || sqlerrm);
        exit;
      end;
      if resp.status is distinct from 200 then
        failed := failed || (src.path || ' p' || pg || ': HTTP ' || coalesce(resp.status::text, '?'));
        exit;
      end if;
      n_pages := n_pages + 1;
      n_page := 0; ids := '';
      for r in select * from private.shop_parse(resp.content) x
               where x.slug is not null and x.name is not null and x.name <> '' and x.price > 0 loop
        n_page := n_page + 1;
        ids := ids || r.slug || ' ';
        select * into o from public.shop_items where id = r.slug;
        if not found then
          insert into public.shop_items (id, k, g, n, p, o, f, img, pid, buy)
          values (r.slug, src.k, src.g, r.name, r.price, r.old, r.fromp, r.img, r.pid, r.buy);
          n_new := n_new + 1;
          changes := changes || ('Nuevo: ' || r.name || ' (U$S ' || to_char(r.price, fmt) || ')');
        else
          if o.last_seen < now() then  -- primera vez que se ve en esta revisión
            if o.p <> r.price then
              n_price := n_price + 1;
              changes := changes || (r.name || ': U$S ' || to_char(o.p, fmt) || ' → U$S ' || to_char(r.price, fmt));
            end if;
            if not o.active then changes := changes || ('Volvió: ' || r.name); end if;
          end if;
          update public.shop_items s set
            n = r.name, p = r.price, o = r.old, f = r.fromp,
            img = coalesce(r.img, s.img), pid = coalesce(r.pid, s.pid), buy = r.buy,
            active = true, last_seen = now(),
            changed_at = case when (s.p, s.o, s.f, s.n, s.active) is distinct from (r.price, r.old, r.fromp, r.name, true) then now() else s.changed_at end
          where s.id = r.slug;
        end if;
      end loop;
      if pg = 1 and n_page = 0 then failed := failed || (src.path || ': sin productos'); end if;
      exit when n_page = 0 or ids = prev_ids or n_page < 36;
      prev_ids := ids;
      perform pg_sleep(0.3);
    end loop;
  end loop;

  select count(*) into n_seen from public.shop_items where last_seen = now();
  if only_path is null and coalesce(array_length(failed, 1), 0) = 0 and n_seen >= prev_active * 0.6 then
    for r in update public.shop_items set active = false, changed_at = now()
             where active and last_seen < now() returning n loop
      n_gone := n_gone + 1;
      changes := changes || ('Ya no aparece: ' || r.n);
    end loop;
  end if;

  select coalesce(jsonb_object_agg(k, c), '{}'::jsonb) into counts
  from (select k, count(*) as c from public.shop_items where active group by k) x;
  select data into meta from public.catalog where id = 'shop';
  meta := coalesce(meta, '{}'::jsonb) || jsonb_build_object('checked', today, 'counts', counts, 'errors', to_jsonb(failed));
  if prev_active = 0 then
    meta := meta || jsonb_build_object('updated', today, 'changes', '[]'::jsonb);
  elsif coalesce(array_length(changes, 1), 0) > 0 then
    meta := meta || jsonb_build_object('updated', today, 'changes', to_jsonb(changes[1:40]), 'more', greatest(array_length(changes, 1) - 40, 0));
  end if;
  if meta->>'updated' is null then meta := meta || jsonb_build_object('updated', today); end if;
  insert into public.catalog (id, data) values ('shop', meta)
  on conflict (id) do update set data = excluded.data, updated_at = now();

  update private.shop_runs set finished_at = clock_timestamp(), pages = n_pages, seen = n_seen,
    new_items = n_new, price_changes = n_price, gone = n_gone, errors = failed
  where id = run_id;
  return meta || jsonb_build_object('pages', n_pages, 'seen', n_seen, 'new', n_new, 'priceChanges', n_price, 'gone', n_gone);
end $$;

revoke all on function private.shop_refresh(text) from public, anon, authenticated;
revoke all on function private.shop_parse(text) from public, anon, authenticated;
revoke all on function private.html_decode(text) from public, anon, authenticated;
revoke all on function private.parse_price(text) from public, anon, authenticated;

-- Todos los días a las 3:17 de Uruguay (6:17 UTC)
select cron.schedule('tienda-macrotec', '17 6 * * *', $$set statement_timeout = '25min'; select private.shop_refresh();$$);
