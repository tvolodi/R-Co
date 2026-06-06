$ErrorActionPreference = 'Continue'
$env:BPM_TEST_DB_URL = 'postgres://bpm:bpm@localhost:5433/bpm_test'

$logPath = 'tests/reports/zig-test-integration-supervised-latest.log'

# Prevent overlapping integration runners from prior aborted sessions.
Get-Process -Name zig,test -ErrorAction SilentlyContinue | Stop-Process -Force

if (-not $env:BPM_TEST_URL -or [string]::IsNullOrWhiteSpace($env:BPM_TEST_URL)) {
    $env:BPM_TEST_URL = 'http://127.0.0.1:8080'
}

if (-not $env:BPM_IDP_BASE_URL -or [string]::IsNullOrWhiteSpace($env:BPM_IDP_BASE_URL)) {
    $env:BPM_IDP_BASE_URL = 'http://localhost:8081'
}

& zig build test-integration --summary all *> $logPath
$exitCode = $LASTEXITCODE
Get-Content -Path $logPath
Add-Content -Path $logPath -Value "INTEGRATION_EXIT_CODE=$exitCode"
exit $exitCode
