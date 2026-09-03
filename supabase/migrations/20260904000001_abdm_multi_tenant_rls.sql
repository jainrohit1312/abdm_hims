-- ============================================================================
-- ABDM Multi-Tenant RLS Hardening
-- ----------------------------------------------------------------------------
-- Replaces the legacy `using (true) with check (true)` ABDM policies with
-- hospital-scoped policies based on the project's existing user-to-hospital
-- authorization model:
--
--   hospital_id = public.current_user_hospital_id()
--
-- Tables covered (ABDM module only — no unrelated module/policy is touched):
--   * abha_profiles
--   * care_contexts
--   * consent_artefacts
--   * data_flow_logs
--   * fhir_records
--   * abha_linking_logs
--
-- `abha_profiles` and `fhir_records` receive a `hospital_id` column so every
-- ABDM table carries tenant ownership. The other four tables already had the
-- column from earlier migrations.
--
-- Idempotent: safe to run more than once.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. hospital_id columns + backfill
-- ----------------------------------------------------------------------------
alter table public.abha_profiles
    add column if not exists hospital_id uuid references public.hospitals(id) on delete set null;

alter table public.fhir_records
    add column if not exists hospital_id uuid references public.hospitals(id) on delete set null;

-- Backfill tenant ownership from the linked patient's hospital so existing
-- rows stay visible after RLS is enabled. Rows without a patient remain NULL
-- and are hidden from authenticated users (service_role can still triage).
update public.abha_profiles ap
   set hospital_id = p.hospital_id
  from public.patients p
 where ap.patient_id = p.id
   and ap.hospital_id is null
   and p.hospital_id is not null;

update public.fhir_records fr
   set hospital_id = p.hospital_id
  from public.patients p
 where fr.patient_id = p.id
   and fr.hospital_id is null
   and p.hospital_id is not null;

update public.care_contexts cc
   set hospital_id = p.hospital_id
  from public.patients p
 where cc.patient_id = p.id
   and cc.hospital_id is null
   and p.hospital_id is not null;

update public.consent_artefacts ca
   set hospital_id = p.hospital_id
  from public.patients p
 where ca.patient_id = p.id
   and ca.hospital_id is null
   and p.hospital_id is not null;

update public.data_flow_logs dfl
   set hospital_id = p.hospital_id
  from public.patients p
 where dfl.patient_id = p.id
   and dfl.hospital_id is null
   and p.hospital_id is not null;

update public.abha_linking_logs all_logs
   set hospital_id = p.hospital_id
  from public.patients p
 where all_logs.patient_id = p.id
   and all_logs.hospital_id is null
   and p.hospital_id is not null;

-- ----------------------------------------------------------------------------
-- 2. Indexes for tenant-scoped lookups
-- ----------------------------------------------------------------------------
create index if not exists idx_abha_profiles_hospital
    on public.abha_profiles (hospital_id);
create index if not exists idx_fhir_records_hospital
    on public.fhir_records (hospital_id);
create index if not exists idx_care_contexts_hospital
    on public.care_contexts (hospital_id);
create index if not exists idx_consent_artefacts_hospital
    on public.consent_artefacts (hospital_id);
create index if not exists idx_data_flow_logs_hospital
    on public.data_flow_logs (hospital_id);
create index if not exists idx_abha_linking_logs_hospital
    on public.abha_linking_logs (hospital_id);

-- ----------------------------------------------------------------------------
-- 3. RLS: drop broad ABDM policies and create hospital-scoped replacements
-- ----------------------------------------------------------------------------

-- 3.1 abha_profiles
alter table public.abha_profiles enable row level security;

drop policy if exists "Enable all access for authenticated users on abha_profiles"
    on public.abha_profiles;
drop policy if exists "abha_profiles tenant select" on public.abha_profiles;
drop policy if exists "abha_profiles tenant insert" on public.abha_profiles;
drop policy if exists "abha_profiles tenant update" on public.abha_profiles;
drop policy if exists "abha_profiles tenant delete" on public.abha_profiles;

create policy "abha_profiles tenant select" on public.abha_profiles
    for select to authenticated
    using (hospital_id = public.current_user_hospital_id());

create policy "abha_profiles tenant insert" on public.abha_profiles
    for insert to authenticated
    with check (hospital_id = public.current_user_hospital_id());

create policy "abha_profiles tenant update" on public.abha_profiles
    for update to authenticated
    using (hospital_id = public.current_user_hospital_id())
    with check (hospital_id = public.current_user_hospital_id());

create policy "abha_profiles tenant delete" on public.abha_profiles
    for delete to authenticated
    using (hospital_id = public.current_user_hospital_id());

-- 3.2 care_contexts
alter table public.care_contexts enable row level security;

drop policy if exists "Enable all access for authenticated users on care_contexts"
    on public.care_contexts;
drop policy if exists "care_contexts tenant select" on public.care_contexts;
drop policy if exists "care_contexts tenant insert" on public.care_contexts;
drop policy if exists "care_contexts tenant update" on public.care_contexts;
drop policy if exists "care_contexts tenant delete" on public.care_contexts;

create policy "care_contexts tenant select" on public.care_contexts
    for select to authenticated
    using (hospital_id = public.current_user_hospital_id());

create policy "care_contexts tenant insert" on public.care_contexts
    for insert to authenticated
    with check (hospital_id = public.current_user_hospital_id());

create policy "care_contexts tenant update" on public.care_contexts
    for update to authenticated
    using (hospital_id = public.current_user_hospital_id())
    with check (hospital_id = public.current_user_hospital_id());

create policy "care_contexts tenant delete" on public.care_contexts
    for delete to authenticated
    using (hospital_id = public.current_user_hospital_id());

-- 3.3 consent_artefacts
alter table public.consent_artefacts enable row level security;

drop policy if exists "Enable all access for authenticated users on consent_artefacts"
    on public.consent_artefacts;
drop policy if exists "consent_artefacts tenant select" on public.consent_artefacts;
drop policy if exists "consent_artefacts tenant insert" on public.consent_artefacts;
drop policy if exists "consent_artefacts tenant update" on public.consent_artefacts;
drop policy if exists "consent_artefacts tenant delete" on public.consent_artefacts;

create policy "consent_artefacts tenant select" on public.consent_artefacts
    for select to authenticated
    using (hospital_id = public.current_user_hospital_id());

create policy "consent_artefacts tenant insert" on public.consent_artefacts
    for insert to authenticated
    with check (hospital_id = public.current_user_hospital_id());

create policy "consent_artefacts tenant update" on public.consent_artefacts
    for update to authenticated
    using (hospital_id = public.current_user_hospital_id())
    with check (hospital_id = public.current_user_hospital_id());

create policy "consent_artefacts tenant delete" on public.consent_artefacts
    for delete to authenticated
    using (hospital_id = public.current_user_hospital_id());

-- 3.4 data_flow_logs
alter table public.data_flow_logs enable row level security;

drop policy if exists "Enable all access for authenticated users on data_flow_logs"
    on public.data_flow_logs;
drop policy if exists "data_flow_logs tenant select" on public.data_flow_logs;
drop policy if exists "data_flow_logs tenant insert" on public.data_flow_logs;
drop policy if exists "data_flow_logs tenant update" on public.data_flow_logs;
drop policy if exists "data_flow_logs tenant delete" on public.data_flow_logs;

create policy "data_flow_logs tenant select" on public.data_flow_logs
    for select to authenticated
    using (hospital_id = public.current_user_hospital_id());

create policy "data_flow_logs tenant insert" on public.data_flow_logs
    for insert to authenticated
    with check (hospital_id = public.current_user_hospital_id());

create policy "data_flow_logs tenant update" on public.data_flow_logs
    for update to authenticated
    using (hospital_id = public.current_user_hospital_id())
    with check (hospital_id = public.current_user_hospital_id());

create policy "data_flow_logs tenant delete" on public.data_flow_logs
    for delete to authenticated
    using (hospital_id = public.current_user_hospital_id());

-- 3.5 fhir_records
alter table public.fhir_records enable row level security;

drop policy if exists "Enable all access for authenticated users on fhir_records"
    on public.fhir_records;
drop policy if exists "fhir_records tenant select" on public.fhir_records;
drop policy if exists "fhir_records tenant insert" on public.fhir_records;
drop policy if exists "fhir_records tenant update" on public.fhir_records;
drop policy if exists "fhir_records tenant delete" on public.fhir_records;

create policy "fhir_records tenant select" on public.fhir_records
    for select to authenticated
    using (hospital_id = public.current_user_hospital_id());

create policy "fhir_records tenant insert" on public.fhir_records
    for insert to authenticated
    with check (hospital_id = public.current_user_hospital_id());

create policy "fhir_records tenant update" on public.fhir_records
    for update to authenticated
    using (hospital_id = public.current_user_hospital_id())
    with check (hospital_id = public.current_user_hospital_id());

create policy "fhir_records tenant delete" on public.fhir_records
    for delete to authenticated
    using (hospital_id = public.current_user_hospital_id());

-- 3.6 abha_linking_logs
alter table public.abha_linking_logs enable row level security;

drop policy if exists "Enable all access for authenticated users on abha_linking_logs"
    on public.abha_linking_logs;
drop policy if exists "abha_linking_logs tenant select" on public.abha_linking_logs;
drop policy if exists "abha_linking_logs tenant insert" on public.abha_linking_logs;
drop policy if exists "abha_linking_logs tenant update" on public.abha_linking_logs;
drop policy if exists "abha_linking_logs tenant delete" on public.abha_linking_logs;

create policy "abha_linking_logs tenant select" on public.abha_linking_logs
    for select to authenticated
    using (hospital_id = public.current_user_hospital_id());

create policy "abha_linking_logs tenant insert" on public.abha_linking_logs
    for insert to authenticated
    with check (hospital_id = public.current_user_hospital_id());

create policy "abha_linking_logs tenant update" on public.abha_linking_logs
    for update to authenticated
    using (hospital_id = public.current_user_hospital_id())
    with check (hospital_id = public.current_user_hospital_id());

create policy "abha_linking_logs tenant delete" on public.abha_linking_logs
    for delete to authenticated
    using (hospital_id = public.current_user_hospital_id());

-- ----------------------------------------------------------------------------
-- 4. Grants for newer Supabase versions (default-deny public tables)
-- ----------------------------------------------------------------------------
grant select, insert, update, delete on public.abha_profiles to authenticated;
grant select, insert, update, delete on public.care_contexts to authenticated;
grant select, insert, update, delete on public.consent_artefacts to authenticated;
grant select, insert, update, delete on public.data_flow_logs to authenticated;
grant select, insert, update, delete on public.fhir_records to authenticated;
grant select, insert, update, delete on public.abha_linking_logs to authenticated;

commit;
