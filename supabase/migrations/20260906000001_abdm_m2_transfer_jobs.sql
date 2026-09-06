-- ============================================================================
-- ABDM M2 HIP Data-Transfer Execution Columns
-- ----------------------------------------------------------------------------
-- Adds the columns needed by the V3 M2 health-information data-transfer job
-- executor (lease/claim, retry metadata, notification status, encrypted
-- transfer metadata) and the consent HI-types recorded by the V3 consent
-- notification.
--
-- Idempotent: safe to run more than once. NO destructive changes.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. abdm_data_transfer_jobs — execution metadata
-- ----------------------------------------------------------------------------
alter table public.abdm_data_transfer_jobs
    add column if not exists care_context_hi_types jsonb not null default '[]'::jsonb,
    add column if not exists lease_owner          text,
    add column if not exists lease_expires_at     timestamptz,
    add column if not exists last_attempt_at      timestamptz,
    add column if not exists notification_status  text,
    add column if not exists encrypted_entries    jsonb;

comment on column public.abdm_data_transfer_jobs.care_context_hi_types is
    'HI types of the care contexts covered by this transfer job.';
comment on column public.abdm_data_transfer_jobs.lease_owner is
    'Worker lease owner. NULL when the job is not being executed.';
comment on column public.abdm_data_transfer_jobs.lease_expires_at is
    'Worker lease expiry. A job whose lease is expired may be claimed again.';
comment on column public.abdm_data_transfer_jobs.last_attempt_at is
    'Timestamp of the last execution attempt.';
comment on column public.abdm_data_transfer_jobs.notification_status is
    'Status of the final ABDM health-information notify call.';
comment on column public.abdm_data_transfer_jobs.encrypted_entries is
    'Encrypted page entries produced for the HIU dataPushUrl.';

-- Partial index for atomic job claiming by status + retry/lease window.
create index if not exists idx_abdm_data_transfer_jobs_claim
    on public.abdm_data_transfer_jobs (hospital_id, created_at)
    where status in ('queued', 'preparing', 'encrypted', 'pushing', 'pushed', 'notifying');

-- ----------------------------------------------------------------------------
-- Atomic claim RPC (service-role only). Uses SELECT ... FOR UPDATE SKIP LOCKED
-- so two workers can never claim the same job simultaneously.
-- ----------------------------------------------------------------------------
create or replace function public.claim_abdm_data_transfer_job(
    p_hospital_id   uuid,
    p_lease_owner   text,
    p_lease_seconds integer,
    p_now           timestamptz
) returns public.abdm_data_transfer_jobs
language plpgsql
security definer
set search_path = public
as $$
declare
    v_job public.abdm_data_transfer_jobs;
begin
    update public.abdm_data_transfer_jobs
       set lease_owner      = p_lease_owner,
           lease_expires_at = p_now + make_interval(secs => p_lease_seconds),
           status           = 'preparing',
           last_attempt_at  = p_now
     where id = (
         select id
           from public.abdm_data_transfer_jobs
          where hospital_id = p_hospital_id
            and status in ('queued', 'preparing', 'encrypted', 'pushing', 'pushed', 'notifying')
            and (lease_owner is null or lease_expires_at < p_now)
            and (next_retry_at is null or next_retry_at <= p_now)
          order by created_at asc
          for update skip locked
          limit 1
     )
     returning * into v_job;

    return v_job;
end;
$$;

revoke all on function public.claim_abdm_data_transfer_job(uuid, text, integer, timestamptz) from public;
grant execute on function public.claim_abdm_data_transfer_job(uuid, text, integer, timestamptz) to service_role;

-- ----------------------------------------------------------------------------
-- 2. consent_artefacts — HI types from the V3 consent notification
-- ----------------------------------------------------------------------------
alter table public.consent_artefacts
    add column if not exists hi_types jsonb not null default '[]'::jsonb;

comment on column public.consent_artefacts.hi_types is
    'HI types authorized by the ABDM V3 consent artefact.';

commit;
