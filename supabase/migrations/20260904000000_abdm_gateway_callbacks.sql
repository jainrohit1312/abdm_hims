-- ============================================================================
-- ABDM Gateway Callbacks (secure backend foundation)
-- ----------------------------------------------------------------------------
-- Stores raw ABDM gateway callback metadata for asynchronous processing.
-- Inserts are performed by the `abdm-gateway` Edge Function using the
-- service-role key (which bypasses RLS). Payloads are sanitized by the Edge
-- Function before insert — authorization headers and access tokens are never
-- stored here.
--
-- Idempotent: safe to run more than once.
-- ============================================================================

begin;

create table if not exists public.abdm_gateway_callbacks (
    id                 uuid primary key default uuid_generate_v4(),
    hospital_id        uuid references public.hospitals(id) on delete set null,
    callback_path      text not null,
    request_id         text,
    transaction_id     text,
    callback_type      text,
    payload            jsonb not null default '{}'::jsonb,
    processing_status  text not null default 'pending',
    retry_count        integer not null default 0,
    error_message      text,
    gateway_timestamp  timestamptz,
    received_at        timestamptz not null default now(),
    processed_at       timestamptz,
    created_at         timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- Indexes + duplicate protection.
-- ABDM callbacks are retried by the gateway, so (request_id, callback_path)
-- must be unique when request_id is present. NULL request_id rows (callbacks
-- without an id header) are allowed to accumulate — they are rare and are
-- still visible for triage.
-- ----------------------------------------------------------------------------
create unique index if not exists uq_abdm_gateway_callbacks_request_path
    on public.abdm_gateway_callbacks (request_id, callback_path)
    where request_id is not null;

create index if not exists idx_abdm_gateway_callbacks_path
    on public.abdm_gateway_callbacks (callback_path);

create index if not exists idx_abdm_gateway_callbacks_status
    on public.abdm_gateway_callbacks (processing_status);

create index if not exists idx_abdm_gateway_callbacks_received_at
    on public.abdm_gateway_callbacks (received_at desc);

create index if not exists idx_abdm_gateway_callbacks_hospital
    on public.abdm_gateway_callbacks (hospital_id);

-- ----------------------------------------------------------------------------
-- Strict Row Level Security.
--   * Authenticated hospital users may only read callbacks for their own
--     hospital (hospital_id = current user's hospital).
--   * Only hospital admins may write/update/delete callback rows; normal
--     authenticated users can never read another hospital's callbacks.
--   * The Edge Function writes with service-role (bypasses RLS) so ABDM
--     callbacks are still recorded while the table is locked down.
-- ----------------------------------------------------------------------------
alter table public.abdm_gateway_callbacks enable row level security;

drop policy if exists "abdm callbacks tenant select" on public.abdm_gateway_callbacks;
create policy "abdm callbacks tenant select"
    on public.abdm_gateway_callbacks
    for select to authenticated
    using (hospital_id = public.current_user_hospital_id());

drop policy if exists "abdm callbacks admin insert" on public.abdm_gateway_callbacks;
create policy "abdm callbacks admin insert"
    on public.abdm_gateway_callbacks
    for insert to authenticated
    with check (
        public.is_current_user_hospital_admin()
        and hospital_id = public.current_user_hospital_id()
    );

drop policy if exists "abdm callbacks admin update" on public.abdm_gateway_callbacks;
create policy "abdm callbacks admin update"
    on public.abdm_gateway_callbacks
    for update to authenticated
    using (
        public.is_current_user_hospital_admin()
        and hospital_id = public.current_user_hospital_id()
    )
    with check (
        public.is_current_user_hospital_admin()
        and hospital_id = public.current_user_hospital_id()
    );

drop policy if exists "abdm callbacks admin delete" on public.abdm_gateway_callbacks;
create policy "abdm callbacks admin delete"
    on public.abdm_gateway_callbacks
    for delete to authenticated
    using (
        public.is_current_user_hospital_admin()
        and hospital_id = public.current_user_hospital_id()
    );

-- Newer Supabase versions default-deny public tables.
grant select, insert, update, delete on public.abdm_gateway_callbacks to authenticated;
grant select, insert, update, delete on public.abdm_gateway_callbacks to service_role;

commit;
