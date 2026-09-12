# Runs the Windows app against the ISOLATED local Supabase stack for the
# offline-OPD end-to-end test. Refuses any non-local URL so it can never
# accidentally target production.
#
# Usage:  powershell -File tool/run_local_e2e.ps1

$ErrorActionPreference = "Stop"

$url = "http://127.0.0.1:54321"

# Safety guard: only loopback URLs are allowed.
if ($url -notmatch '^(http://)?(127\.0\.0\.1|localhost)(:\d+)?$') {
    throw "Refusing to run E2E against a non-local URL: $url"
}

Write-Host "Starting Windows app against isolated backend: $url" -ForegroundColor Green
Write-Host "Ensure 'supabase start' + 'supabase db reset' have been run first." -ForegroundColor Yellow

# Publishable (anon) key from `supabase status` for the local stack. This is a
# local-only key, not a production secret.
$anon = "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"

flutter run -d windows `
    --dart-define=SUPABASE_URL=$url `
    --dart-define=SUPABASE_ANON_KEY=$anon `
    --dart-define=ABDM_REAL_MODE=false
