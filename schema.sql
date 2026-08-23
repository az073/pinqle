-- OSHIMAP database schema
-- Target: PostgreSQL 15+ / Supabase

create extension if not exists pgcrypto;

create type verification_status as enum ('pending', 'verified', 'rejected');
create type source_type as enum ('official_sns', 'video', 'tv', 'article', 'other');

create table groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  country_code char(2),
  official_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references groups(id) on delete cascade,
  name text not null,
  slug text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (group_id, slug)
);

create table cities (
  id uuid primary key default gen_random_uuid(),
  country_code char(2) not null,
  prefecture text,
  name text not null,
  slug text not null,
  center_lat double precision,
  center_lng double precision,
  timezone text not null default 'Asia/Tokyo',
  unique (country_code, slug),
  check (center_lat is null or center_lat between -90 and 90),
  check (center_lng is null or center_lng between -180 and 180)
);

create table categories (
  id smallint generated always as identity primary key,
  name text not null unique,
  slug text not null unique
);

create table places (
  id uuid primary key default gen_random_uuid(),
  city_id uuid not null references cities(id),
  category_id smallint references categories(id),
  name text not null,
  address text,
  latitude double precision not null,
  longitude double precision not null,
  google_place_id text unique,
  google_maps_url text,
  website_url text,
  phone text,
  permanently_closed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (latitude between -90 and 90),
  check (longitude between -180 and 180)
);

-- Weekly schedule. day_of_week: 0=Sunday ... 6=Saturday.
-- A business open past midnight is stored as two rows.
create table opening_hours (
  id bigint generated always as identity primary key,
  place_id uuid not null references places(id) on delete cascade,
  day_of_week smallint not null check (day_of_week between 0 and 6),
  opens_at time,
  closes_at time,
  closed boolean not null default false,
  check (closed or (opens_at is not null and closes_at is not null))
);

-- One visit/appearance fact can involve multiple members and sources.
create table pilgrimages (
  id uuid primary key default gen_random_uuid(),
  place_id uuid not null references places(id) on delete cascade,
  title text,
  description text,
  visited_on date,
  verification_status verification_status not null default 'pending',
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (verification_status <> 'verified' or verified_at is not null)
);

create table pilgrimage_members (
  pilgrimage_id uuid not null references pilgrimages(id) on delete cascade,
  member_id uuid not null references members(id) on delete cascade,
  primary key (pilgrimage_id, member_id)
);

create table sources (
  id uuid primary key default gen_random_uuid(),
  source_type source_type not null default 'other',
  title text,
  url text not null unique,
  publisher text,
  published_at timestamptz,
  accessed_at timestamptz not null default now(),
  archived_url text,
  notes text,
  created_at timestamptz not null default now()
);

create table pilgrimage_sources (
  pilgrimage_id uuid not null references pilgrimages(id) on delete cascade,
  source_id uuid not null references sources(id) on delete cascade,
  quote text,
  primary key (pilgrimage_id, source_id)
);

create index members_group_id_idx on members(group_id);
create index places_city_id_idx on places(city_id);
create index places_category_id_idx on places(category_id);
create index places_lat_lng_idx on places(latitude, longitude);
create index opening_hours_place_day_idx on opening_hours(place_id, day_of_week);
create index pilgrimages_place_status_idx on pilgrimages(place_id, verification_status);
create index pilgrimage_members_member_id_idx on pilgrimage_members(member_id);

-- Read model for the current front end. Multiple members are returned together.
create view public_spots as
select
  p.id,
  p.name,
  p.latitude as lat,
  p.longitude as lng,
  p.address,
  p.google_place_id,
  p.google_maps_url,
  p.permanently_closed,
  c.name as city,
  c.prefecture,
  c.country_code,
  cat.name as category,
  pg.description,
  pg.visited_on,
  pg.verification_status,
  g.id as group_id,
  g.name as group_name,
  array_agg(distinct m.name order by m.name) as members
from pilgrimages pg
join places p on p.id = pg.place_id
join cities c on c.id = p.city_id
left join categories cat on cat.id = p.category_id
join pilgrimage_members pm on pm.pilgrimage_id = pg.id
join members m on m.id = pm.member_id
join groups g on g.id = m.group_id
where pg.verification_status <> 'rejected'
group by p.id, c.id, cat.id, pg.id, g.id;

-- Security baseline for Supabase. Public users can read verified facts only
-- through the security-invoker view; all writes require a trusted backend.
alter table groups enable row level security;
alter table members enable row level security;
alter table cities enable row level security;
alter table categories enable row level security;
alter table places enable row level security;
alter table opening_hours enable row level security;
alter table pilgrimages enable row level security;
alter table pilgrimage_members enable row level security;
alter table sources enable row level security;
alter table pilgrimage_sources enable row level security;

alter view public_spots set (security_invoker = true);

create policy "public read groups" on groups for select to anon, authenticated using (true);
create policy "public read members" on members for select to anon, authenticated using (true);
create policy "public read cities" on cities for select to anon, authenticated using (true);
create policy "public read categories" on categories for select to anon, authenticated using (true);
create policy "public read places" on places for select to anon, authenticated using (
  exists (select 1 from pilgrimages pg where pg.place_id = places.id and pg.verification_status = 'verified')
);
create policy "public read verified pilgrimages" on pilgrimages for select to anon, authenticated using (verification_status = 'verified');
create policy "public read verified member links" on pilgrimage_members for select to anon, authenticated using (
  exists (select 1 from pilgrimages pg where pg.id = pilgrimage_members.pilgrimage_id and pg.verification_status = 'verified')
);

grant usage on schema public to anon, authenticated;
grant select on public_spots to anon, authenticated;
