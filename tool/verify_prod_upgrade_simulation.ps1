# ======================================================================
# Isolated production-upgrade simulation
# ----------------------------------------------------------------------
# Proves that an EXISTING hospital database can be upgraded in place without
# losing data, constraints, policies, triggers or identifiers.
#
# It uses the LOCAL isolated Supabase stack only (never production):
#
#   1. stash the two genuinely-new migrations -> `supabase db reset` builds a
#      representative PRE-UPGRADE schema;
#   2. simulate the production migration HISTORY (the three historical files
#      had duplicate version numbers, so their recorded versions differ);
#   3. seed synthetic data and snapshot every fact that must be preserved;
#   4. apply the incremental upgrade plan:
#        a. record the `doctors` version (the table already exists in this
#           production-representative database);
#        b. record the three renamed historical versions;
#        c. apply the two new migrations;
#   5. assert every pre-upgrade fact is unchanged;
#   6. pay a PRE-EXISTING visit through the new atomic endpoint (functional).
#
# NOTE: step 4.a/4.b DO change migration history. That is a deliberate,
# reviewed bookkeeping change (`supabase migration repair`), not a no-op, and
# it must only be done after the read-only inspection in
# docs/production_upgrade_plan.md confirms the schema effects already exist.
#
# Usage:  powershell -ExecutionPolicy Bypass -File tool/verify_prod_upgrade_simulation.ps1
# ======================================================================

$ErrorActionPreference = "Stop"

$root      = Split-Path -Parent $PSScriptRoot
$migDir    = Join-Path $root "supabase\migrations"
$verifySql = Join-Path $root "supabase\verify_upgrade_simulation.sql"
$stash     = Join-Path $root ".qwen\tmp\prod_upgrade_stash"
$db        = "supabase_db_abdm_hims"

# The migrations that do NOT exist in production yet.
$newMigrations = @(
    "20260911000000_offline_sync_outbox_v2.sql",
    "20260912000000_opd_payment_atomic_operation.sql"
)

function Invoke-PsqlSql {
    param([string]$Sql)
    & docker exec -i $db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -c $Sql
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $Sql" }
}

function Invoke-PsqlFile {
    param([string]$File, [string[]]$Vars = @())
    $args = @("exec", "-i", $db, "psql", "-U", "supabase_admin", "-d", "postgres",
              "-v", "ON_ERROR_STOP=1")
    foreach ($v in $Vars) { $args += "-v"; $args += $v }
    $args += @("-f", "-")
    Get-Content -Raw $File | & docker @args
    if ($LASTEXITCODE -ne 0) { throw "psql failed on $File" }
}

New-Item -ItemType Directory -Force -Path $stash | Out-Null

try {
    Write-Host "==> 1/6  Building the pre-upgrade schema (new migrations stashed)" -ForegroundColor Cyan
    foreach ($f in $newMigrations) {
        Move-Item -Force (Join-Path $migDir $f) (Join-Path $stash $f)
    }
    & supabase db reset
    if ($LASTEXITCODE -ne 0) { throw "supabase db reset failed" }

    Write-Host "==> 2/6  Simulating the production migration history" -ForegroundColor Cyan
    # Production recorded the ORIGINAL (duplicate) version numbers.
    Invoke-PsqlSql @"
DELETE FROM supabase_migrations.schema_migrations
 WHERE version IN ('20260827000002', '20260828000007', '20260828000008');
DELETE FROM supabase_migrations.schema_migrations WHERE version = '20260825000014';
INSERT INTO supabase_migrations.schema_migrations (version, name)
VALUES ('20260828000000', 'ipd_patient_dashboard_groups')
ON CONFLICT (version) DO NOTHING;
"@

    Write-Host "==> 3/6  Seeding synthetic data and snapshotting the pre-upgrade state" -ForegroundColor Cyan
    Invoke-PsqlFile -File $verifySql -Vars @("phase=seed", "is_seed=1", "is_assert=0", "is_functional=0")

    Write-Host "==> 4/6  Applying the incremental upgrade plan" -ForegroundColor Cyan
    # (a) doctors: idempotent reconstruction, already present here.
    Invoke-PsqlFile -File (Join-Path $migDir "20260825000014_create_doctors_table.sql")
    # (b) record the renamed historical versions as applied (history change).
    Invoke-PsqlSql @"
INSERT INTO supabase_migrations.schema_migrations (version, name) VALUES
    ('20260825000014', 'create_doctors_table'),
    ('20260827000002', 'voucher_attachments'),
    ('20260828000007', 'ipd_doctor_selection_charges'),
    ('20260828000008', 'ipd_patient_dashboard_groups')
ON CONFLICT (version) DO NOTHING;
"@
    # (c) apply the two genuinely-new migrations.
    foreach ($f in $newMigrations) {
        Move-Item -Force (Join-Path $stash $f) (Join-Path $migDir $f)
        Invoke-PsqlFile -File (Join-Path $migDir $f)
    }
    Invoke-PsqlSql @"
INSERT INTO supabase_migrations.schema_migrations (version, name) VALUES
    ('20260911000000', 'offline_sync_outbox_v2'),
    ('20260912000000', 'opd_payment_atomic_operation')
ON CONFLICT (version) DO NOTHING;
"@

    Write-Host "==> 5/6  Asserting preservation of data / policies / triggers / ids" -ForegroundColor Cyan
    Invoke-PsqlFile -File $verifySql -Vars @("phase=assert", "is_seed=0", "is_assert=1", "is_functional=0")

    Write-Host "==> 6/6  Paying a PRE-EXISTING visit through the new endpoint" -ForegroundColor Cyan
    Invoke-PsqlFile -File $verifySql -Vars @("phase=functional", "is_seed=0", "is_assert=0", "is_functional=1")

    Write-Host "==> Upgrade simulation finished." -ForegroundColor Green
}
finally {
    # Never leave the repository with a stashed migration.
    foreach ($f in $newMigrations) {
        $stashed = Join-Path $stash $f
        if (Test-Path $stashed) {
            Move-Item -Force $stashed (Join-Path $migDir $f)
        }
    }
}
