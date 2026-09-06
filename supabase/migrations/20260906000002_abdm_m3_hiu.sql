-- ============================================================================
-- ABDM M3 HIU Persistence (V3-only)
-- ----------------------------------------------------------------------------
-- Adds the persistence needed by the M3 HIU pipeline in the `abdm-gateway`
-- Edge Function. All M3 gateway traffic uses the official V3 contracts only;
-- no legacy v1/v2 fallback is implemented.
--
--   1. `abdm_m3_consent_requests`
--      Outgoing HIU consent requests (idempotent on request_id, correlated to
--      the gateway consent_request_id once the on-init callback arrives).
--
--   2. `abdm_m3_hi_requests`
--      HIU health-information requests and their transfer lifecycle
--      (request_created -> request_submitted -> waiting_for_data -> receiving
--       -> ... -> completed / failed_safe). Only PUBLIC key-material is stored;
--      private keys are never persisted by this schema.
--
--   3. `abdm_m3_data_pages`
--      Encrypted data pages received from the HIP dataPushUrl. Idempotent on
--      (transaction_id, page_number). Entries remain encrypted at rest.
--
--   4. `abdm_m3_imported_records`
--      Tenant-scoped FHIR R4 resources imported from decrypted HIP transfers.
--      Unique on (transaction_id, care_context_reference, record_id) so
--      callback retries can never duplicate a clinical record.
--
-- Consent artefacts themselves continue to live in the existing
-- `consent_artefacts` table (reused by both the M2 HIP and M3 HIU paths).
--
-- Idempotent: safe to run more than once. NO destructive changes.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. M3 consent requests (HIU -> gateway)
-- ----------------------------------------------------------------------------
create table if not exists public.abdm_m3_consent_requests (
    id                  uuid primary key default uuid_generate_v4(),
    hospital_id         uuid references public.hospitals(id) on delete set null,
    patient_id          uuid references public.patients(id) on delete set null,
    request_id          text not null,
    consent_request_id  text,
    abha_address        text,
    status              text not null default 'created',
    purpose_text        text,
    purpose_code        text,
    hi_types            jsonb not null default '[]'::jsonb,
    date_from           timestamptz,
    date_to             timestamptz,
    data_erase_at       timestamptz,
    frequency           jsonb not null default '{}'::jsonb,
    hip_id              text,
    hiu_id              text,
    error_code          text,
    error_message       text,
    submitted_at        timestamptz,
    responded_at        timestamptz,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);

create unique index if not exists uq_abdm_m3_consent_requests_request
    on public.abdm_m3_consent_requests (request_id);
create unique index if not exists uq_abdm_m3_consent_requests_gateway
    on public.abdm_m3_consent_requests (consent_request_id)
    where consent_request_id is not null;
create index if not exists idx_abdm_m3_consent_requests_hospital
    on public.abdm_m3_consent_requests (hospital_id);
create index if not exists idx_abdm_m3_consent_requests_patient
    on public.abdm_m3_consent_requests (patient_id);
create index if not exists idx_abdm_m3_consent_requests_status
    on public.abdm_m3_consent_requests (status);

alter table public.abdm_m3_consent_requests enable row level security;

drop policy if exists "abdm m3 consent requests tenant select" on public.abdm_m3_consent_requests;
create policy "abdm m3 consent requests tenant select"
    on public.abdm_m3_consent_requests
    for select to authenticated
    using (hospital_id = public.current_user_hospital_id());

grant select on public.abdm_m3_consent_requests to authenticated;
grant select, insert, update, delete on public.abdm_m3_consent_requests to service_role;

-- ----------------------------------------------------------------------------
-- 2. M3 health-information requests (HIU -> gateway -> HIP)
-- ----------------------------------------------------------------------------
create table if not exists public.abdm_m3_hi_requests (
    id                        uuid primary key default uuid_generate_v4(),
    hospital_id               uuid references public.hospitals(id) on delete set null,
    patient_id                uuid references public.patients(id) on delete set null,
    consent_id                text not null,
    request_id                text not null,
    transaction_id            text,
    hip_id                    text,
    hiu_id                    text,
    status                    text not null default 'request_created',
    requested_from            timestamptz,
    requested_to              timestamptz,
    hi_types                  jsonb not null default '[]'::jsonb,
    care_context_references   jsonb not null default '[]'::jsonb,
    key_material              jsonb not null default '{}'::jsonb,
    expected_pages            integer,
    received_pages            integer not null default 0,
    error_code                text,
    error_message             text,
    submitted_at              timestamptz,
    completed_at              timestamptz,
    created_at                timestamptz not null default now(),
    updated_at                timestamptz not null default now()
);

create unique index if not exists uq_abdm_m3_hi_requests_request
    on public.abdm_m3_hi_requests (request_id);
create unique index if not exists uq_abdm_m3_hi_requests_transaction
    on public.abdm_m3_hi_requests (transaction_id)
    where transaction_id is not null;
create index if not exists idx_abdm_m3_hi_requests_consent
    on public.abdm_m3_hi_requests (consent_id);
create index if not exists idx_abdm_m3_hi_requests_hospital
    on public.abdm_m3_hi_requests (hospital_id);
create index if not exists idx_abdm_m3_hi_requests_patient
    on public.abdm_m3_hi_requests (patient_id);
create index if not exists idx_abdm_m3_hi_requests_status
    on public.abdm_m3_hi_requests (status);

alter table public.abdm_m3_hi_requests enable row level security;

drop policy if exists "abdm m3 hi requests tenant select" on public.abdm_m3_hi_requests;
create policy "abdm m3 hi requests tenant select"
    on public.abdm_m3_hi_requests
    for select to authenticated
    using (hospital_id = public.current_user_hospital_id());

grant select on public.abdm_m3_hi_requests to authenticated;
grant select, insert, update, delete on public.abdm_m3_hi_requests to service_role;

-- ----------------------------------------------------------------------------
-- 3. M3 encrypted data pages (HIP -> HIU dataPushUrl)
-- ----------------------------------------------------------------------------
create table if not exists public.abdm_m3_data_pages (
    id                  uuid primary key default uuid_generate_v4(),
    hospital_id         uuid references public.hospitals(id) on delete set null,
    transaction_id      text not null,
    page_number         integer not null,
    page_count          integer not null,
    status              text not null default 'received',
    entry_count         integer not null default 0,
    entries             jsonb not null default '[]'::jsonb,
    key_material        jsonb not null default '{}'::jsonb,
    checksum_metadata   jsonb not null default '[]'::jsonb,
    received_at         timestamptz not null default now(),
    processing_status   text,
    error_code          text,
    error_message       text,
    created_at          timestamptz not null default now()
);

create unique index if not exists uq_abdm_m3_data_pages_transaction_page
    on public.abdm_m3_data_pages (transaction_id, page_number);
create index if not exists idx_abdm_m3_data_pages_hospital
    on public.abdm_m3_data_pages (hospital_id);
create index if not exists idx_abdm_m3_data_pages_status
    on public.abdm_m3_data_pages (status);

alter table public.abdm_m3_data_pages enable row level security;

drop policy if exists "abdm m3 data pages tenant select" on public.abdm_m3_data_pages;
create policy "abdm m3 data pages tenant select"
    on public.abdm_m3_data_pages
    for select to authenticated
    using (hospital_id = public.current_user_hospital_id());

grant select on public.abdm_m3_data_pages to authenticated;
grant select, insert, update, delete on public.abdm_m3_data_pages to service_role;

-- ----------------------------------------------------------------------------
-- 4. M3 imported FHIR records (decrypted + validated)
-- ----------------------------------------------------------------------------
create table if not exists public.abdm_m3_imported_records (
    id                        uuid primary key default uuid_generate_v4(),
    hospital_id               uuid references public.hospitals(id) on delete set null,
    patient_id                uuid references public.patients(id) on delete cascade,
    abha_id                   varchar(50),
    consent_id                text,
    transaction_id            text not null,
    care_context_reference     text,
    hi_type                   varchar(50),
    resource_type             varchar(50),
    record_id                 varchar(150),
    source_hip_id             text,
    fhir_resource             jsonb not null default '{}'::jsonb,
    received_at               timestamptz not null default now(),
    checksum                  text,
    verification_status       varchar(20) not null default 'unverified',
    created_at                timestamptz not null default now()
);

-- Idempotency: a retried transfer can never duplicate a clinical record.
create unique index if not exists uq_abdm_m3_imported_records_txn_cc_record
    on public.abdm_m3_imported_records (transaction_id, care_context_reference, record_id);
create index if not exists idx_abdm_m3_imported_records_consent
    on public.abdm_m3_imported_records (consent_id);
create index if not exists idx_abdm_m3_imported_records_transaction
    on public.abdm_m3_imported_records (transaction_id);
create index if not exists idx_abdm_m3_imported_records_hospital
    on public.abdm_m3_imported_records (hospital_id);
create index if not exists idx_abdm_m3_imported_records_patient
    on public.abdm_m3_imported_records (patient_id);
create index if not exists idx_abdm_m3_imported_records_abha
    on public.abdm_m3_imported_records (abha_id);

alter table public.abdm_m3_imported_records enable row level security;

drop policy if exists "abdm m3 imported records tenant select" on public.abdm_m3_imported_records;
create policy "abdm m3 imported records tenant select"
    on public.abdm_m3_imported_records
    for select to authenticated
    using (hospital_id = public.current_user_hospital_id());

grant select on public.abdm_m3_imported_records to authenticated;
grant select, insert, update, delete on public.abdm_m3_imported_records to service_role;

commit;
