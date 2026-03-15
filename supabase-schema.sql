-- =============================================
-- BelForce Ready - Supabase Schema
-- Force Readiness Tracker - Belgian Defense
-- =============================================

create extension if not exists "uuid-ossp";

-- =============================================
-- TABLES
-- =============================================

-- Profiles (extends Supabase auth.users)
create table profiles (
  id uuid references auth.users on delete cascade primary key,
  email text,
  full_name text,
  role text check (role in ('admin','commander','operator','viewer')) default 'operator',
  lang text check (lang in ('fr','nl')) default 'fr',
  unit_id uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- Units (hierarchical military structure)
create table units (
  id uuid default uuid_generate_v4() primary key,
  name text not null,
  abbreviation text,
  parent_unit_id uuid references units(id) on delete set null,
  type text check (type in ('composante','brigade','bataillon','compagnie','peloton','section','autre')) default 'compagnie',
  commander_name text,
  location text,
  owner_id uuid references auth.users on delete cascade not null,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- Personnel
create table personnel (
  id uuid default uuid_generate_v4() primary key,
  unit_id uuid references units(id) on delete set null,
  rank text not null,
  last_name text not null,
  first_name text not null,
  matricule text,
  function text,
  status text check (status in ('apte','inapte_temp','inapte_def','en_mission','en_conge','en_formation','mute')) default 'apte',
  status_note text,
  medical_expiry date,
  phone text,
  email text,
  photo_url text,
  birth_date date,
  incorporation_date date,
  blood_type text check (blood_type in ('A+','A-','B+','B-','AB+','AB-','O+','O-',null)),
  owner_id uuid references auth.users on delete cascade not null,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- Certification types
create table cert_types (
  id uuid default uuid_generate_v4() primary key,
  name_fr text not null,
  name_nl text not null,
  category text check (category in ('combat','medical','physical','driving','security','other')) default 'other',
  validity_months integer not null default 12,
  mandatory boolean default false,
  owner_id uuid references auth.users on delete cascade not null,
  created_at timestamptz default now()
);

-- Certifications (personnel x cert_type)
create table certifications (
  id uuid default uuid_generate_v4() primary key,
  personnel_id uuid references personnel(id) on delete cascade not null,
  cert_type_id uuid references cert_types(id) on delete cascade not null,
  obtained_date date not null,
  expiry_date date not null,
  status text check (status in ('valid','expiring','expired')) default 'valid',
  notes text,
  document_url text,
  owner_id uuid references auth.users on delete cascade not null,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- Deployments / Missions
create table deployments (
  id uuid default uuid_generate_v4() primary key,
  personnel_id uuid references personnel(id) on delete cascade not null,
  mission_name text not null,
  operation text,
  location text,
  start_date date not null,
  end_date date,
  status text check (status in ('planned','active','completed','cancelled')) default 'planned',
  notes text,
  owner_id uuid references auth.users on delete cascade not null,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- Audit log
create table audit_log (
  id uuid default uuid_generate_v4() primary key,
  user_id uuid references auth.users on delete set null,
  action text not null,
  entity text not null,
  entity_id uuid,
  details jsonb,
  created_at timestamptz default now()
);

-- =============================================
-- FOREIGN KEYS
-- =============================================
alter table profiles add constraint profiles_unit_id_fkey
  foreign key (unit_id) references units(id) on delete set null;

-- =============================================
-- INDEXES
-- =============================================
create index idx_personnel_unit on personnel(unit_id);
create index idx_personnel_status on personnel(status);
create index idx_personnel_owner on personnel(owner_id);
create index idx_personnel_name on personnel(last_name, first_name);
create index idx_certifications_personnel on certifications(personnel_id);
create index idx_certifications_cert_type on certifications(cert_type_id);
create index idx_certifications_expiry on certifications(expiry_date);
create index idx_certifications_owner on certifications(owner_id);
create index idx_cert_types_owner on cert_types(owner_id);
create index idx_units_owner on units(owner_id);
create index idx_units_parent on units(parent_unit_id);
create index idx_deployments_personnel on deployments(personnel_id);
create index idx_deployments_owner on deployments(owner_id);
create index idx_audit_log_entity on audit_log(entity, entity_id);
create index idx_audit_log_user on audit_log(user_id);

-- =============================================
-- ROW LEVEL SECURITY
-- =============================================
alter table profiles enable row level security;
alter table units enable row level security;
alter table personnel enable row level security;
alter table cert_types enable row level security;
alter table certifications enable row level security;
alter table deployments enable row level security;
alter table audit_log enable row level security;

-- Profiles
create policy "profiles_select" on profiles for select using (auth.uid() = id);
create policy "profiles_update" on profiles for update using (auth.uid() = id);
create policy "profiles_insert" on profiles for insert with check (auth.uid() = id);

-- Units
create policy "units_all" on units for all using (auth.uid() = owner_id);

-- Personnel
create policy "personnel_all" on personnel for all using (auth.uid() = owner_id);

-- Cert types
create policy "cert_types_all" on cert_types for all using (auth.uid() = owner_id);

-- Certifications
create policy "certifications_all" on certifications for all using (auth.uid() = owner_id);

-- Deployments
create policy "deployments_all" on deployments for all using (auth.uid() = owner_id);

-- Audit log
create policy "audit_log_select" on audit_log for select using (auth.uid() = user_id);
create policy "audit_log_insert" on audit_log for insert with check (true);

-- =============================================
-- FUNCTIONS
-- =============================================

-- Auto-create profile on signup
create or replace function handle_new_user()
returns trigger as $$
begin
  insert into profiles (id, email, full_name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', '')
  );
  return new;
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function public.handle_new_user() to supabase_auth_admin;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Update certification statuses based on dates
create or replace function update_cert_statuses()
returns void as $$
begin
  update certifications set status = 'expired'
    where expiry_date < current_date and status != 'expired';
  update certifications set status = 'expiring'
    where expiry_date >= current_date
      and expiry_date < current_date + interval '30 days'
      and status != 'expiring';
  update certifications set status = 'valid'
    where expiry_date >= current_date + interval '30 days'
      and status != 'valid';
end;
$$ language plpgsql security definer;

-- Get readiness stats (callable via RPC)
create or replace function get_readiness_stats()
returns json as $$
declare
  result json;
begin
  select json_build_object(
    'total', (select count(*) from personnel where owner_id = auth.uid()),
    'apte', (select count(*) from personnel where owner_id = auth.uid() and status = 'apte'),
    'inapte_temp', (select count(*) from personnel where owner_id = auth.uid() and status = 'inapte_temp'),
    'inapte_def', (select count(*) from personnel where owner_id = auth.uid() and status = 'inapte_def'),
    'en_mission', (select count(*) from personnel where owner_id = auth.uid() and status = 'en_mission'),
    'en_conge', (select count(*) from personnel where owner_id = auth.uid() and status = 'en_conge'),
    'en_formation', (select count(*) from personnel where owner_id = auth.uid() and status = 'en_formation'),
    'certs_valid', (select count(*) from certifications where owner_id = auth.uid() and status = 'valid'),
    'certs_expiring', (select count(*) from certifications where owner_id = auth.uid() and status = 'expiring'),
    'certs_expired', (select count(*) from certifications where owner_id = auth.uid() and status = 'expired')
  ) into result;
  return result;
end;
$$ language plpgsql security definer;
