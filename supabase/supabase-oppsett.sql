-- =====================================================================
-- RaskBud: databaseoppsett for Supabase
-- Lim inn hele filen i Supabase > SQL Editor > New query, og trykk Run.
-- Filen kan kjøres flere ganger uten å ødelegge noe.
-- =====================================================================

-- ---------- Profiler (én per bruker) ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  name text,
  phone text,
  addr text,
  zip text,
  city text,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

-- Er innlogget bruker admin?
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

-- Lag profil automatisk når noen registrerer seg
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name) values (new.id, new.raw_user_meta_data->>'name')
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();
revoke execute on function public.handle_new_user() from public, anon, authenticated;

alter table public.profiles enable row level security;
drop policy if exists "profiles read" on public.profiles;
create policy "profiles read" on public.profiles for select using (id = auth.uid() or public.is_admin());
drop policy if exists "profiles update own" on public.profiles;
create policy "profiles update own" on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
-- Kunder kan bare endre disse feltene (ikke is_admin)
revoke update on public.profiles from anon, authenticated;
grant update (name, phone, addr, zip, city) on public.profiles to authenticated;

-- ---------- Innstillinger (kortpriser) ----------
create table if not exists public.settings (
  key text primary key,
  value jsonb not null
);
alter table public.settings enable row level security;
drop policy if exists "settings read" on public.settings;
create policy "settings read" on public.settings for select using (true);
drop policy if exists "settings admin write" on public.settings;
create policy "settings admin write" on public.settings for all using (public.is_admin()) with check (public.is_admin());

insert into public.settings (key, value) values ('bulk', '{
  "b-unsorted": 0.1, "b-common": 0.2, "b-rare": 0.3, "b-holo": 0.5, "b-gx": 6, "b-vmax": 6,
  "b-amazing": 5, "b-babyshiny": 5, "b-fullart": 7.5, "b-pika": 7.5, "b-gold": 10, "b-tg": 10,
  "b-rainbow": 20, "a-sleeves": 5, "a-coins": 0.1, "a-pins": 2.5
}'::jsonb) on conflict (key) do nothing;

-- ---------- Forespørsler / sendinger ----------
create sequence if not exists public.submission_seq start 100001;

create table if not exists public.submissions (
  id uuid primary key default gen_random_uuid(),
  ref text unique not null,
  user_id uuid not null references auth.users on delete cascade,
  email text,
  name text,
  status text not null,
  items jsonb not null,
  ship jsonb not null default '{}'::jsonb,
  payout jsonb not null default '{}'::jsonb,
  total numeric not null default 0,
  paid_amount numeric,
  messages jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- Sendingskode fra Posten/PostNord som admin legger inn etter at kunden har godtatt budet
alter table public.submissions add column if not exists ship_code text;
-- Når varene er mottatt (et nytt bud etter dette er et «justert bud etter sjekk»)
alter table public.submissions add column if not exists received_at timestamptz;
alter table public.submissions drop constraint if exists submissions_status_check;
alter table public.submissions add constraint submissions_status_check
  check (status in ('venter_bud','bud_sendt','godtatt','mottatt','utbetalt','avslatt','kansellert','retur','returnert'));
create index if not exists submissions_user_idx on public.submissions (user_id);
create index if not exists submissions_status_idx on public.submissions (status);

alter table public.submissions enable row level security;
drop policy if exists "submissions read" on public.submissions;
create policy "submissions read" on public.submissions for select using (user_id = auth.uid() or public.is_admin());
drop policy if exists "submissions admin update" on public.submissions;
create policy "submissions admin update" on public.submissions for update using (public.is_admin()) with check (public.is_admin());
drop policy if exists "submissions admin delete" on public.submissions;
create policy "submissions admin delete" on public.submissions for delete using (public.is_admin());
-- Ingen insert-policy: kunder oppretter bare via create_submission() under,
-- slik at kortprisene alltid regnes ut på serveren.

-- Interne notater (bare admin)
create table if not exists public.admin_notes (
  ref text primary key references public.submissions (ref) on delete cascade,
  note text not null default ''
);
alter table public.admin_notes enable row level security;
drop policy if exists "notes admin" on public.admin_notes;
create policy "notes admin" on public.admin_notes for all using (public.is_admin()) with check (public.is_admin());

-- ---------- Funksjoner kundene bruker ----------

-- Send inn en forespørsel. Kortpriser regnes ut her, ikke i nettleseren.
create or replace function public.create_submission(p_items jsonb, p_ship jsonb, p_payout jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_email text;
  v_rates jsonb;
  v_items jsonb;
  v_has_quote boolean;
  v_ref text;
begin
  if v_uid is null then raise exception 'Du må være logget inn.'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 100 then
    raise exception 'Ugyldig forespørsel.';
  end if;
  select email into v_email from auth.users where id = v_uid;
  select value into v_rates from settings where key = 'bulk';

  select jsonb_agg(
    case when it->>'kind' = 'bulk' then
      it || jsonb_build_object(
        'qty', greatest(1, least(1000000, coalesce((it->>'qty')::int, 1))),
        'price', round((v_rates->>(it->>'bulkId'))::numeric * greatest(1, least(1000000, coalesce((it->>'qty')::int, 1))), 2),
        'accepted', null)
    else
      it || jsonb_build_object('kind', 'quote', 'price', null, 'adminNote', '', 'accepted', null)
    end)
  into v_items
  from jsonb_array_elements(p_items) it;

  if exists (select 1 from jsonb_array_elements(v_items) it where it->>'kind' = 'bulk' and jsonb_typeof(it->'price') = 'null') then
    raise exception 'Ukjent kortkategori.';
  end if;

  v_has_quote := exists (select 1 from jsonb_array_elements(v_items) it where it->>'kind' <> 'bulk');
  v_ref := 'RB' || nextval('submission_seq');

  insert into submissions (ref, user_id, email, name, status, items, ship, payout, total, messages)
  values (
    v_ref, v_uid, v_email, left(p_ship->>'name', 200),
    case when v_has_quote then 'venter_bud' else 'godtatt' end,
    v_items, p_ship, p_payout,
    (select coalesce(sum((it->>'price')::numeric), 0) from jsonb_array_elements(v_items) it where it->>'kind' = 'bulk'),
    jsonb_build_array(jsonb_build_object('by', 'system', 'text',
      case when v_has_quote then 'Forespørselen er sendt inn.' else 'Sendingen er registrert.' end,
      'photos', '[]'::jsonb, 'at', now()))
  );
  return v_ref;
end $$;

-- Kunden svarer på et bud: p_accepted er listen over linjer (lid) kunden selger.
-- Etter at varene er mottatt gjelder et justert bud bare ting med endret pris (revised=true);
-- uendrede ting er allerede avtalt, og ting som aldri ble sendt forblir «beholdes».
create or replace function public.respond_offer(p_ref text, p_accepted text[]) returns void
language plpgsql security definer set search_path = public as $$
declare s submissions; v_items jsonb; v_total numeric; v_any boolean; v_after boolean; v_back boolean; v_status text; v_text text;
begin
  select * into s from submissions where ref = p_ref and user_id = auth.uid() for update;
  if not found then raise exception 'Fant ikke forespørselen.'; end if;
  if s.status <> 'bud_sendt' then raise exception 'Budet er ikke lenger åpent.'; end if;
  v_after := s.received_at is not null;
  select jsonb_agg(case
      when v_after and (it->>'shipped') = 'false' then it || '{"accepted": false}'::jsonb
      when v_after and (it->>'revised') is distinct from 'true' then it || '{"accepted": true}'::jsonb
      else it || jsonb_build_object('accepted', (it->>'lid') = any(coalesce(p_accepted, '{}')) and coalesce((it->>'price')::numeric, 0) > 0)
    end)
  into v_items from jsonb_array_elements(s.items) it;
  select coalesce(sum((it->>'price')::numeric), 0), bool_or((it->>'accepted')::boolean)
  into v_total, v_any from jsonb_array_elements(v_items) it where (it->>'accepted')::boolean;
  v_any := coalesce(v_any, false);
  if v_after then
    v_back := exists (select 1 from jsonb_array_elements(v_items) it where (it->>'shipped') is distinct from 'false' and not (it->>'accepted')::boolean);
    v_status := case when v_any then 'mottatt' else 'retur' end;
    v_text := case
      when not v_any then 'Kunden takket nei til det justerte budet. Tingene skal sendes tilbake.'
      when v_back then 'Kunden takket nei til de justerte prisene. De tingene skal sendes tilbake. Resten betales ut: ' || round(v_total)::text || ' kr.'
      else 'Kunden godtok det justerte budet. Totalt ' || round(v_total)::text || ' kr.' end;
  else
    v_status := case when v_any then 'godtatt' else 'avslatt' end;
    v_text := case when v_any then 'Kunden godtok budet på ' || round(v_total)::text || ' kr.' else 'Kunden takket nei til budet.' end;
  end if;
  update submissions set items = v_items, total = v_total, status = v_status,
    messages = messages || jsonb_build_array(jsonb_build_object('by', 'system', 'photos', '[]'::jsonb, 'at', now(), 'text', v_text)),
    updated_at = now()
  where id = s.id;
end $$;

-- Legg til en melding (kunde eller admin)
create or replace function public.add_message(p_ref text, p_text text, p_photos jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_owner uuid;
begin
  select user_id into v_owner from submissions where ref = p_ref;
  if v_owner is null or (v_owner <> auth.uid() and not public.is_admin()) then
    raise exception 'Fant ikke forespørselen.';
  end if;
  update submissions set
    messages = messages || jsonb_build_array(jsonb_build_object(
      'by', case when public.is_admin() and v_owner <> auth.uid() then 'admin' else 'kunde' end,
      'text', left(coalesce(p_text, ''), 4000),
      'photos', coalesce(p_photos, '[]'::jsonb),
      'at', now())),
    updated_at = now()
  where ref = p_ref;
end $$;

revoke all on function public.create_submission(jsonb, jsonb, jsonb) from public, anon;
revoke all on function public.respond_offer(text, text[]) from public, anon;
revoke all on function public.add_message(text, text, jsonb) from public, anon;
grant execute on function public.create_submission(jsonb, jsonb, jsonb) to authenticated;
grant execute on function public.respond_offer(text, text[]) to authenticated;
grant execute on function public.add_message(text, text, jsonb) to authenticated;

-- ---------- Bilder ----------
insert into storage.buckets (id, name, public) values ('photos', 'photos', true)
on conflict (id) do nothing;
update storage.buckets set file_size_limit = 8388608, allowed_mime_types = array['image/jpeg','image/png','image/webp']
where id = 'photos';
drop policy if exists "photos upload own folder" on storage.objects;
create policy "photos upload own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "photos admin delete" on storage.objects;
create policy "photos admin delete" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and public.is_admin());


-- ---------- Strekkoder og spilldatabase (fyller seg selv) ----------
-- Hver strekkode som blir slått opp eller lært opp i Admin lagres her.
create table if not exists public.barcodes (
  code text primary key,
  item jsonb not null,           -- { name, platform, image, kind }
  source text,                   -- UPCitemdb, admin ...
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.barcodes enable row level security;
drop policy if exists "barcodes read" on public.barcodes;
create policy "barcodes read" on public.barcodes for select using (true);
drop policy if exists "barcodes admin write" on public.barcodes;
create policy "barcodes admin write" on public.barcodes for all using (public.is_admin()) with check (public.is_admin());

-- Mellomlager for søk mot TheGamesDB/RAWG/UPCitemdb (bare funksjonen "lookup" bruker den)
create table if not exists public.lookup_cache (
  key text primary key,
  value jsonb,
  created_at timestamptz not null default now()
);
alter table public.lookup_cache enable row level security;

-- ---------- Rate-limit for lookup-funksjonen ----------
-- Maks N kall per nøkkel (IP) per tidsvindu, håndhevet i databasen slik at
-- det ikke kan omgås ved å kalle funksjonen på andre måter.
create table if not exists public.rate_limit (
  bucket_key text not null,
  window_start timestamptz not null,
  count int not null default 1,
  primary key (bucket_key, window_start)
);
alter table public.rate_limit enable row level security;
-- Ingen policies: bare service_role (funksjonen) skal røre denne.

create or replace function public.check_rate_limit(p_key text, p_limit int, p_window_seconds int)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_window timestamptz := date_trunc('minute', now()) - (extract(epoch from now() - date_trunc('minute', now()))::int / p_window_seconds * p_window_seconds) * interval '1 second';
  v_count int;
begin
  insert into public.rate_limit (bucket_key, window_start, count)
  values (p_key, v_window, 1)
  on conflict (bucket_key, window_start) do update set count = rate_limit.count + 1
  returning count into v_count;
  if random() < 0.02 then
    delete from public.rate_limit where window_start < now() - interval '1 hour';
  end if;
  return v_count <= p_limit;
end $$;
revoke all on function public.check_rate_limit(text, int, int) from public, anon, authenticated;

-- ---------- Spillkatalog (38 000+ spill med boksbilder) ----------
-- Kilde: libretro-database + libretro-thumbnails på GitHub. Data: data/games.json i repoet.
create extension if not exists pg_trgm with schema extensions;
create extension if not exists unaccent with schema extensions;
create table if not exists public.games (
  id bigint generated always as identity primary key,
  system text not null, title text not null, region text,
  repo text not null, file text not null, title_norm text not null
);
create index if not exists games_title_trgm on public.games using gin (title_norm extensions.gin_trgm_ops);
create index if not exists games_system_idx on public.games (system);
alter table public.games enable row level security;
drop policy if exists "games read" on public.games;
create policy "games read" on public.games for select using (true);
drop policy if exists "games admin write" on public.games;
create policy "games admin write" on public.games for all using (public.is_admin()) with check (public.is_admin());

create or replace function public.norm_text(t text) returns text
language sql stable set search_path = public, extensions as $$
  select trim(regexp_replace(lower(extensions.unaccent(coalesce(t, ''))), '[^a-z0-9]+', ' ', 'g'));
$$;
-- Ekstra felter fra TheGamesDB (nyere spill, bilder og produktkoder)
alter table public.games
  add column if not exists image text, add column if not exists source text not null default 'libretro',
  add column if not exists tgdb_id int, add column if not exists uids text[], add column if not exists uids_norm text,
  add column if not exists year text;
alter table public.games alter column repo drop not null, alter column file drop not null;
create index if not exists games_uids_trgm on public.games using gin (uids_norm extensions.gin_trgm_ops);
create unique index if not exists games_tgdb_id_uq on public.games (tgdb_id) where tgdb_id is not null;
create or replace function public.html_unescape(t text) returns text language sql immutable as $$
  select replace(replace(replace(replace(replace(replace(coalesce(t, ''), '&#039;', ''''), '&quot;', '"'), '&amp;', '&'), '&lt;', '<'), '&gt;', '>'), '&#39;', '''');
$$;

-- Søk (tittel eller produktkode) med sider og totalt antall. Tomt søk + konsoll = bla i alle spill for konsollen.
drop function if exists public.search_games(text, text, int);
drop function if exists public.search_games(text, text, int, int);
create function public.search_games(q text, sys text default null, lim int default 20, off int default 0)
returns table (system text, title text, region text, repo text, file text, image text, year text, uids text[], total bigint)
language sql stable set search_path = public, extensions as $$
  with w as (select public.norm_text(coalesce(q, '')) as nq, regexp_replace(lower(coalesce(q, '')), '[^a-z0-9]', '', 'g') as code),
  hits as (
    select g.*, w.nq, w.code from public.games g, w
    where (sys is null or g.system = sys)
      and (
        (length(w.nq) < 2 and sys is not null)
        or (length(w.nq) >= 2 and g.title_norm like all (array(select '%' || x || '%' from regexp_split_to_table(w.nq, ' ') x where x <> '')))
        or (length(w.code) >= 6 and w.code ~ '[a-z]' and w.code ~ '[0-9]' and g.uids_norm like '%' || w.code || '%')
      )
  )
  select h.system, h.title, h.region, h.repo, h.file, h.image, h.year, h.uids, count(*) over () as total
  from hits h
  order by
    (length(h.code) >= 6 and coalesce(h.uids_norm, '') like '%' || h.code || '%') desc,
    (length(h.nq) >= 2 and h.title_norm = h.nq) desc,
    case when length(h.nq) < 2 then 0 else (h.source = 'libretro')::int end desc,
    (length(h.nq) >= 2 and h.title_norm like h.nq || '%') desc,
    case when length(h.nq) >= 2 then extensions.similarity(h.title_norm, h.nq) else 0 end desc,
    case when length(h.nq) < 2 then h.title_norm end,
    case when h.region in ('Norway','Scandinavia','Sweden','Denmark','Finland','Europe','World','UK') then 0 else 1 end,
    (h.image is not null or h.file is not null) desc,
    length(h.title)
  limit least(greatest(lim, 1), 60) offset greatest(off, 0);
$$;
grant execute on function public.search_games(text, text, int, int) to anon, authenticated;
create or replace function public.game_systems()
returns table (system text, n bigint)
language sql stable set search_path = public as $$
  select system, count(*) from public.games group by system order by count(*) desc;
$$;
grant execute on function public.game_systems() to anon, authenticated;

grant execute on function public.norm_text(text) to anon, authenticated;

-- Last inn katalogen (databasen henter filen selv fra GitHub; repoet må være offentlig mens dette kjøres):
-- create extension if not exists http with schema extensions;
-- set http.timeout_msec = 60000;
-- truncate public.games;
-- insert into public.games (system, title, region, repo, file, title_norm)
-- select x->>'s', x->>'t', x->>'r', x->>'p', x->>'f', public.norm_text(x->>'t')
-- from jsonb_array_elements((select content::jsonb from extensions.http_get('https://raw.githubusercontent.com/b3cpot/kjopalt/main/data/games.json'))) x;

-- ---------- Hemmeligheter (bare serverfunksjoner kan lese) ----------
create table if not exists public.app_secrets (key text primary key, value text not null);
alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from anon, authenticated;
-- Legg inn nøkkelen for hånd (aldri i denne filen):
-- insert into public.app_secrets values ('TGDB_KEY', 'din-nøkkel') on conflict (key) do update set value = excluded.value;

-- ---------- Import fra TheGamesDB ----------
-- Hentes fra den gratis databasefilen https://cdn.thegamesdb.net/json/database-latest.json (bruker ingen API-kvote).
create table if not exists public.tgdb_platforms (id int primary key, system text not null);
alter table public.tgdb_platforms enable row level security;
insert into public.tgdb_platforms (id, system) values
 (10,'PS1'),(11,'PS2'),(12,'PS3'),(4919,'PS4'),(4980,'PS5'),(13,'PSP'),(39,'PS Vita'),
 (7,'NES'),(6,'SNES'),(3,'N64'),(2,'GameCube'),(9,'Wii'),(38,'Wii U'),(4971,'Switch'),(5021,'Switch 2'),
 (4,'Game Boy'),(41,'GBC'),(5,'GBA'),(8,'DS'),(4912,'3DS'),(4918,'Virtual Boy'),
 (14,'Xbox'),(15,'Xbox 360'),(4920,'Xbox One'),(4981,'Xbox Series'),
 (35,'Master System'),(36,'Mega Drive'),(18,'Mega Drive'),(21,'Mega-CD'),(33,'32X'),(17,'Saturn'),(16,'Dreamcast'),(20,'Game Gear')
on conflict (id) do update set system = excluded.system;

-- ---------- «Ser etter» (styres fra Admin > Ser etter) ----------
create table if not exists public.wanted (
  id bigint generated always as identity primary key,
  catalog_id text, name text not null, system text, cat text not null default 'Spill',
  image text, note text, sort int not null default 0, created_at timestamptz not null default now()
);
alter table public.wanted enable row level security;
drop policy if exists "wanted read" on public.wanted;
create policy "wanted read" on public.wanted for select using (true);
drop policy if exists "wanted admin write" on public.wanted;
create policy "wanted admin write" on public.wanted for all using (public.is_admin()) with check (public.is_admin());

-- =====================================================================
-- GJØR DEG SELV TIL ADMIN
-- 1. Registrer deg på nettsiden med din egen e-post.
-- 2. Bytt ut e-posten under med din, og kjør bare denne linjen:
--
-- update public.profiles set is_admin = true
--   where id = (select id from auth.users where email = 'din@epost.no');
-- =====================================================================
