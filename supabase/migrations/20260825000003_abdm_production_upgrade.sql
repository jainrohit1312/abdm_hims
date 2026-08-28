-- ============================================================================
-- ABDM Production Upgrade (M1 + M2 + M3)
-- ----------------------------------------------------------------------------
-- Run this in the Supabase SQL Editor (or via `supabase db push`).
--
-- 1. Creates `abha_profiles`     (ABHA identity linked to a patient)
-- 2. Creates `fhir_records`      (ABDM-standard FHIR bundles)
-- 3. Upgrades existing ABDM tables to the new production column names:
--      * care_contexts      (+ care_context_id, record_type, record_id)
--      * consent_artefacts  (+ abha_id)
--      * data_flow_logs     (index on transaction_id)
-- 4. Adds `patients.abha_address`
-- 5. RLS policies for the new tables
--
-- The script is idempotent: safe to run more than once.
-- ============================================================================

begin;

-- ============================================================================
-- 1. abha_profiles
-- ============================================================================
create table if not exists public.abha_profiles (
    id           uuid primary key default uuid_generate_v4(),
    patient_id   uuid not null unique references public.patients(id) on delete cascade,
    abha_id      varchar(50),
    abha_address varchar(100),
    is_verified  boolean not null default false,
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now()
);

create index if not exists idx_abha_profiles_abha_id
    on public.abha_profiles (abha_id);
create index if not exists idx_abha_profiles_abha_address
    on public.abha_profiles (abha_address);

-- ============================================================================
-- 2. fhir_records (ABDM FHIR R4 bundles stored locally for HIU/HIP flows)
-- ============================================================================
create table if not exists public.fhir_records (
    id           uuid primary key default uuid_generate_v4(),
    patient_id   uuid not null references public.patients(id) on delete cascade,
    abha_id      varchar(50),
    record_type  varchar(50),
    record_id    varchar(100),
    fhir_bundle  jsonb not null default '{}'::jsonb,
    created_at   timestamptz not null default now()
);

create unique index if not exists uq_fhir_records_patient_type_record
    on public.fhir_records (patient_id, record_type, record_id);
create index if not exists idx_fhir_records_patient
    on public.fhir_records (patient_id);
create index if not exists idx_fhir_records_abha
    on public.fhir_records (abha_id);

-- ============================================================================
-- 3. patients: add abha_address (ABHA Address is the 14-char address @abdm)
-- ============================================================================
alter table public.patients
    add column if not exists abha_address varchar(100);

create index if not exists idx_patients_abha_address
    on public.patients (abha_address);

-- ============================================================================
-- 4. care_contexts: add production columns + backfill from legacy columns
-- ============================================================================
alter table public.care_contexts
    add column if not exists care_context_id varchar(255),
    add column if not exists record_type varchar(50),
    add column if not exists record_id varchar(100);

-- Backfill from the old ABDM-module columns so existing rows are not lost.
update public.care_contexts
   set care_context_id = abdm_care_context_id
 where care_context_id is null
   and abdm_care_context_id is not null;

update public.care_contexts
   set record_type = care_context_type
 where record_type is null
   and care_context_type is not null;

update public.care_contexts
   set record_id = care_context_reference_id::text
 where record_id is null
   and care_context_reference_id is not null;

create unique index if not exists uq_care_contexts_patient_cc
    on public.care_contexts (patient_id, care_context_id);
create index if not exists idx_care_contexts_patient
    on public.care_contexts (patient_id);
create index if not exists idx_care_contexts_abha
    on public.care_contexts (abha_id);

-- ============================================================================
-- 5. consent_artefacts: add abha_id
-- ============================================================================
alter table public.consent_artefacts
    add column if not exists abha_id varchar(50);

create index if not exists idx_consent_artefacts_patient
    on public.consent_artefacts (patient_id);
create index if not exists idx_consent_artefacts_abha
    on public.consent_artefacts (abha_id);

-- ============================================================================
-- 6. data_flow_logs: index transaction_id for audit lookups
-- ============================================================================
create index if not exists idx_data_flow_logs_transaction
    on public.data_flow_logs (transaction_id);
create index if not exists idx_data_flow_logs_patient
    on public.data_flow_logs (patient_id);

-- ============================================================================
-- 7. RLS: new tables follow the existing "authenticated users can access"
--         convention used by the rest of the HIMS schema.
-- ============================================================================
alter table public.abha_profiles enable row level security;
alter table public.fhir_records enable row level security;

drop policy if exists "Enable all access for authenticated users on abha_profiles"
    on public.abha_profiles;
create policy "Enable all access for authenticated users on abha_profiles"
    on public.abha_profiles for all to authenticated
    using (true) with check (true);

drop policy if exists "Enable all access for authenticated users on fhir_records"
    on public.fhir_records;
create policy "Enable all access for authenticated users on fhir_records"
    on public.fhir_records for all to authenticated
    using (true) with check (true);

-- ============================================================================
-- 8. updated_at trigger for abha_profiles (kept in sync by the app too, but
--    this guarantees correctness for manual SQL updates).
-- ============================================================================
create or replace function public.set_updated_at()
returns trigger as $$
begin
    new.updated_at = now();
    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_abha_profiles_updated_at on public.abha_profiles;
create trigger trg_abha_profiles_updated_at
    before update on public.abha_profiles
    for each row execute function public.set_updated_at();

commit;
