# Load environment variables from .env and run the NFR benchmark suite.
# Usage: .vscode\run-zig-bench.ps1 [-Precheck]
# This ensures BPM_DB_URL (and BPM_TEST_DB_URL as fallback) are set
# before executing `zig build bench`, so the benchmark process finds
# them directly in its environment rather than relying on .env file
# parsing logic inside the Zig binary.

param(
    [switch]$Precheck
)

$ErrorActionPreference = 'Continue'

$projectRoot = Resolve-Path "$PSScriptRoot\.."
$envFile = Join-Path $projectRoot ".env"

if (-not (Test-Path $envFile)) {
    Write-Error ".env file not found at $envFile"
    exit 1
}

# Read .env and set each variable in the process environment.
Get-Content $envFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { return }
    $eqIdx = $line.IndexOf('=')
    if ($eqIdx -gt 0) {
        $name  = $line.Substring(0, $eqIdx).Trim()
        $value = $line.Substring($eqIdx + 1).Trim().Trim("'").Trim('"')
        Set-Item -Path "Env:$name" -Value $value
    }
}

# Ensure the test DB URL is set if not already present — bench may fall
# back to it when the primary dev DB is unreachable (e.g. port 5432 down).
if (-not $env:BPM_TEST_DB_URL -or [string]::IsNullOrWhiteSpace($env:BPM_TEST_DB_URL)) {
    $env:BPM_TEST_DB_URL = 'postgres://bpm:bpm@localhost:5433/bpm_test'
}

Write-Host "Environment loaded from .env — running NFR benchmark suite..."
Push-Location $projectRoot
$benchOutput = & zig build bench --summary all 2>&1
$exitCode = $LASTEXITCODE
Pop-Location

if ($Precheck) {
    # Step 04 gate needs a short precheck snapshot while preserving
    # the benchmark process exit code.
    $benchOutput | Select-Object -First 5 | ForEach-Object { Write-Output $_ }
} else {
    $benchOutput | ForEach-Object { Write-Output $_ }
}

if ($exitCode -eq 0) {
    Write-Host "NFR benchmark suite PASSED (exit code 0)"
} else {
    Write-Host "NFR benchmark suite FAILED (exit code $exitCode)"
}
exit $exitCode
