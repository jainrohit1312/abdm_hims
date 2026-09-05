-- ============================================================================
-- ABDM HFR Facility/HIP Linkage
-- ----------------------------------------------------------------------------
-- Adds the smallest necessary hospital-scoped fields for the official HFR
-- Multiple HRP AddUpdateServices flow:
--
--   hospitals.hfr_facility_id  HFR facility id, used as the ABDM V3
--                              bridge-service service-id.
--   hospitals.abdm_hip_name    Short, unique ABDM HIP name for this facility.
--
-- facilityName is NOT stored separately: the official facility name is already
-- `hospitals.name`. bridgeId continues to come from the ABDM_BRIDGE_ID Edge
-- Function secret and is never stored in the database.
--
-- Idempotent: safe to run more than once.
-- ============================================================================

begin;

alter table public.hospitals
    add column if not exists hfr_facility_id varchar(64),
    add column if not exists abdm_hip_name varchar(15);

-- HIP name must be unique across facilities (one facility per hospital row).
create unique index if not exists uq_hospitals_abdm_hip_name
    on public.hospitals (abdm_hip_name)
    where abdm_hip_name is not null;

comment on column public.hospitals.hfr_facility_id is
    'HFR facility id used as the ABDM V3 bridge-service service-id.';
comment on column public.hospitals.abdm_hip_name is
    'Short unique ABDM HIP name for this facility (max 15 chars).';

commit;
