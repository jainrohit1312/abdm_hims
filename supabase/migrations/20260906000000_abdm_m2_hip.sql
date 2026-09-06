-- ============================================================================
-- ABDM M2 HIP Persistence (V3-only)
-- ----------------------------------------------------------------------------
-- Adds the persistence needed by the M2 HIP callback pipeline in the
-- `abdm-gateway` Edge Function. All M2 gateway traffic uses the official V3
-- contracts only; no legacy v1/v2 fallback is implemented.
--
--   1. `abdm_m2_requests`
--      Idempotent event/audit store for inbound V3 HIP callbacks
--      (discover, link init/confirm, consent notify, health-information
--      request and ack-only callbacks). The Edge Function writes with the
--      service-role key. Link-confirm tokens are NEVER stored raw — only
--      `token_hash` (SHA-256).
--
--   2. `abdm_data_transfer_jobs`
--      Data-transfer jobs created from valid health-information requests.
--      FHIR bundles are built server-side from real Mediflux data; live
--      transfer stays gated until HIP linkage, consent and encryption
--      prerequisites are satisfied.
--
--   3. `consent_artefacts.care_context_references`
--      Care-context references carried by the V3 consent notification, used
--      later by health-information request handling.
--
-- Idempotent: safe to run more than once. NO destructive changes.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. M2 request/event store
-- ----------------------------------------------------------------------------
create table if not exists public.abdm_m2_requests (
    id                 uuid primary key default uuid_generate_v4(),
    hospital_id        uuid references public.hospitals(id) on delete set null,
    request_id         text,
    transaction_id     text,
    request_type       text not null,
    callback_path      text not null,
    status             text not null default 'received',
    payload            jsonb not null default '{}'::jsonb,
    response_payload   jsonb,
    link_ref_number    text,
    token_hash         text,
    expires_at         timestamptz,
    error_code         text,
    error_message      text,
    received_at        timestamptz not null default now(),
    processed_at       timestamptz,
    created_at         timestamptz not null default now()
);

-- ABDM retries callbacks; a duplicate (request_id, request_type) must never
-- produce a duplicate event row. NULL request_id rows are still recorded.
create unique index if not exists uq_abdm_m2_requests_request_type
    on public.abdm_m2_requests (request_id, request_type)
    where request_id is not null;

create index if not exists idx_abdm_m2_requests_transaction
    on public.abdm_m2_requests (transaction_id);
create index if not exists idx_abdm_m2_requests_hospital
    on public.abdm_m2_requests (hospital_id);
create index if not exists idx_abdm_m2_requests_status
    on public.abdm_m2_requests (status);
create index if not exists idx_abdm_m2_requests_link_ref
    on public.abdm_m2_requests (link_ref_number)
    where link_ref_number is not null;

alter table public.abdm_m2_requests enable row level security;

-- Hospital staff can only see their own hospital's M2 events.
drop policy if exists "abdm m2 requests tenant select" on public.abdm_m2_requests;
create policy "abdm m2 requests tenant select"
    on public.abdm_m2_requests
    for select to authenticated
    using (hospital_id = public.current_user_hospital_id());

-- Only the Edge Function (service_role) writes M2 events.
grant select on public.abdm_m2_requests to authenticated;
grant select, insert, update, delete on public.abdm_m2_requests to service_role;

-- ----------------------------------------------------------------------------
-- 2. Data-transfer jobs
-- ----------------------------------------------------------------------------
create table if not exists public.abdm_data_transfer_jobs (
    id                        uuid primary key default uuid_generate_v4(),
    hospital_id               uuid references public.hospitals(id) on delete set null,
    consent_id                text not null,
    transaction_id            text not null unique,
    status                    text not null default 'pending',
    care_context_references   jsonb not null default '[]'::jsonb,
    fhir_bundle               jsonb,
    key_material              jsonb not null default '{}'::jsonb,
    data_push_url             text,
    attempts                  integer not null default 0,
    error_code                text,
    error_message             text,
    next_retry_at             timestamptz,
    created_at                timestamptz not null default now(),
    updated_at                timestamptz not null default now()
);

create index if not exists idx_abdm_data_transfer_jobs_consent
    on public.abdm_data_transfer_jobs (consent_id);
create index if not exists idx_abdm_data_transfer_jobs_hospital
    on public.abdm_data_transfer_jobs (hospital_id);
create index if not exists idx_abdm_data_transfer_jobs_status
    on public.abdm_data_transfer_jobs (status);

alter table public.abdm_data_transfer_jobs enable row level security;

drop policy if exists "abdm data transfer jobs tenant select" on public.abdm_data_transfer_jobs;
create policy "abdm data transfer jobs tenant select"
    on public.abdm_data_transfer_jobs
    for select to authenticated
    using (hospital_id = public.current_user_hospital_id());

grant select on public.abdm_data_transfer_jobs to authenticated;
grant select, insert, update, delete on public.abdm_data_transfer_jobs to service_role;

-- ----------------------------------------------------------------------------
-- 3. consent_artefacts: care-context references from V3 consent notification
-- ----------------------------------------------------------------------------
alter table public.consent_artefacts
    add column if not exists care_context_references jsonb not null default '[]'::jsonb;

comment on column public.consent_artefacts.care_context_references is
    'Care-context references from the ABDM V3 HIP consent notification.';

commit;
