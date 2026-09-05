-- ============================================================================
-- ABDM M1 Secure Linking, Transaction Binding and Consent Evidence
-- ----------------------------------------------------------------------------
-- Forward-only, idempotent migration. Do NOT edit already-applied migrations;
-- do NOT run this automatically — the operator applies it during deployment.
--
-- 1. `abdm_m1_transactions`
--      Server-side binding of ABDM M1 continuation transactions (txnId) to the
--      current HIMS user + hospital + operation with an expiry. The Edge
--      Function writes/reads with the service-role key only (no authenticated
--      policies) so a browser-supplied transaction id can never be replayed by
--      another operator. OTP and raw Aadhaar are NEVER stored here.
--
-- 2. `abha_m1_consent_evidence`
--      Non-sensitive consent evidence for M1 operations (consent given,
--      purpose, text/version, timestamp, operator, hospital, patient where
--      known, safe ABDM transaction correlation id). No Aadhaar / OTP.
--
-- 3. `abha_profiles` verification metadata + duplicate-ABHA guard
--      Adds verification_source / verified_at / status and a partial unique
--      index so one ABHA number cannot be linked to two different patients in
--      the same hospital.
--
-- 4. `link_abha_profile` RPC
--      Atomically upserts `abha_profiles`, updates the patient's ABHA fields
--      and writes an `abha_linking_logs` entry in one transaction, enforcing
--      hospital isolation via `public.current_user_hospital_id()`.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. M1 transaction binding (service-role only)
-- ----------------------------------------------------------------------------
create table if not exists public.abdm_m1_transactions (
    id              uuid primary key default uuid_generate_v4(),
    user_id         uuid not null references public.users(id) on delete cascade,
    hospital_id     uuid not null references public.hospitals(id) on delete cascade,
    operation       text not null,
    transaction_id  text not null unique,
    expires_at      timestamptz not null,
    consumed_at     timestamptz,
    created_at      timestamptz not null default now()
);

create index if not exists idx_abdm_m1_transactions_owner
    on public.abdm_m1_transactions (user_id, hospital_id);
create index if not exists idx_abdm_m1_transactions_expires
    on public.abdm_m1_transactions (expires_at);

alter table public.abdm_m1_transactions enable row level security;

-- No policies for `authenticated`/`anon`: only the Edge Function (service_role)
-- may read/consume these rows. Grants for newer Supabase default-deny.
grant select, insert, update, delete on public.abdm_m1_transactions to service_role;

-- ----------------------------------------------------------------------------
-- 2. Consent evidence (hospital-scoped, authenticated insert)
-- ----------------------------------------------------------------------------
create table if not exists public.abha_m1_consent_evidence (
    id                  uuid primary key default uuid_generate_v4(),
    hospital_id         uuid not null references public.hospitals(id) on delete cascade,
    user_id             uuid not null references public.users(id) on delete set null,
    patient_id          uuid references public.patients(id) on delete set null,
    consent_given       boolean not null default true,
    consent_purpose     text not null,
    consent_text        text not null,
    consent_version     text not null,
    abdm_transaction_id text,
    recorded_at         timestamptz not null default now()
);

create index if not exists idx_abha_m1_consent_hospital
    on public.abha_m1_consent_evidence (hospital_id);
create index if not exists idx_abha_m1_consent_patient
    on public.abha_m1_consent_evidence (patient_id);

alter table public.abha_m1_consent_evidence enable row level security;

drop policy if exists "abha m1 consent tenant select" on public.abha_m1_consent_evidence;
create policy "abha m1 consent tenant select"
    on public.abha_m1_consent_evidence
    for select to authenticated
    using (hospital_id = public.current_user_hospital_id());

drop policy if exists "abha m1 consent tenant insert" on public.abha_m1_consent_evidence;
create policy "abha m1 consent tenant insert"
    on public.abha_m1_consent_evidence
    for insert to authenticated
    with check (hospital_id = public.current_user_hospital_id());

grant select, insert on public.abha_m1_consent_evidence to authenticated;
grant select, insert, update, delete on public.abha_m1_consent_evidence to service_role;

-- ----------------------------------------------------------------------------
-- 3. abha_profiles verification metadata + duplicate-ABHA guard
-- ----------------------------------------------------------------------------
alter table public.abha_profiles
    add column if not exists verification_source text,
    add column if not exists verified_at timestamptz,
    add column if not exists status text not null default 'active';

-- Prevent the same ABHA number from being linked to two different patients in
-- the same hospital. The same ABHA may still be linked by different hospitals
-- to their own patient records (each hospital has its own patient identity).
create unique index if not exists uq_abha_profiles_hospital_abha
    on public.abha_profiles (hospital_id, abha_id)
    where abha_id is not null and btrim(abha_id) <> '';

-- ----------------------------------------------------------------------------
-- 4. Atomic ABHA profile upsert + patient linkage (hospital-scoped RPC)
-- ----------------------------------------------------------------------------
create or replace function public.link_abha_profile(
    p_patient_id          uuid,
    p_abha_id             text,
    p_abha_address        text default null,
    p_is_verified         boolean default true,
    p_verification_source text default 'abdm_m1',
    p_transaction_id      text default null
) returns public.abha_profiles
language plpgsql
security definer
set search_path = public
as $$
declare
    v_patient_hospital uuid;
    v_profile         public.abha_profiles;
    v_abha_id         text;
begin
    if p_abha_id is null or btrim(p_abha_id) = '' then
        raise exception 'ABHA id is required';
    end if;
    v_abha_id := upper(btrim(p_abha_id));

    select p.hospital_id
      into v_patient_hospital
      from public.patients p
     where p.id = p_patient_id;

    if v_patient_hospital is null then
        raise exception 'Patient not found';
    end if;

    -- Hospital isolation: the caller's JWT hospital must match the patient's
    -- hospital. `current_user_hospital_id()` reads auth.uid() and is evaluated
    -- with the caller's JWT even inside this SECURITY DEFINER function.
    if v_patient_hospital is distinct from public.current_user_hospital_id() then
        raise exception 'Patient does not belong to the current hospital';
    end if;

    insert into public.abha_profiles (
        patient_id,
        hospital_id,
        abha_id,
        abha_address,
        is_verified,
        verification_source,
        verified_at,
        status
    )
    values (
        p_patient_id,
        v_patient_hospital,
        v_abha_id,
        p_abha_address,
        p_is_verified,
        p_verification_source,
        case when p_is_verified then now() else null end,
        'active'
    )
    on conflict (patient_id) do update
        set abha_id             = excluded.abha_id,
            abha_address        = excluded.abha_address,
            is_verified         = excluded.is_verified,
            verification_source = excluded.verification_source,
            verified_at         = excluded.verified_at,
            status              = 'active',
            updated_at          = now()
    returning * into v_profile;

    update public.patients
       set abha_id      = v_abha_id,
           abha_address = coalesce(p_abha_address, abha_address),
           abha_linked  = true
     where id = p_patient_id;

    insert into public.abha_linking_logs (
        hospital_id,
        patient_id,
        abha_id,
        request_type,
        request_payload,
        response_payload,
        status,
        transaction_id
    )
    values (
        v_patient_hospital,
        p_patient_id,
        v_abha_id,
        'link',
        jsonb_build_object('verificationSource', p_verification_source),
        jsonb_build_object('abhaAddress', coalesce(p_abha_address, '')),
        'success',
        p_transaction_id
    );

    return v_profile;
end;
$$;

revoke all on function public.link_abha_profile(uuid, text, text, boolean, text, text) from public;
grant execute on function public.link_abha_profile(uuid, text, text, boolean, text, text) to authenticated;

commit;
