#requires -Version 5.1
<#
.SYNOPSIS
    Run `zig build test-integration` with the `-j` cap from
    BPM_TEST_INTEGRATION_JOB_CAP applied. Required because Zig 0.16 removed
    Step.setJobs() — the build-runner's -j flag is the only mechanism that
    actually constrains concurrency.

.DESCRIPTION
    Reads BPM_TEST_INTEGRATION_JOB_CAP (default 8) and constructs the
    matching `zig build test-integration -j$N` invocation.

    Usage:
        pwsh scripts/run-test-integration.ps1                  # default cap = 8
        $env:BPM_TEST_INTEGRATION_JOB_CAP = "4"; scripts/run-test-integration.ps1

    Override at the call site with -Jobs <N> (env var wins if both are set):
        scripts/run-test-integration.ps1 -Jobs 4

    The -j flag is also accepted by `zig build` itself; if you invoke
    `zig build test-integration` directly without this wrapper, supply
    -j8 (or your preferred cap) explicitly. This wrapper exists to make
    the env-var knob actually take effect by default.

.NOTES
    ISS-0692 / GH-752 (REWORK 1). Authoritative reference:
    docs/guides/test_developer_guide.md §10.2.
#>

[CmdletBinding()]
param(
    [int]$Jobs = 0
)

$ErrorActionPreference = 'Continue'

# Resolve cap: -Jobs flag > BPM_TEST_INTEGRATION_JOB_CAP > 8 (default).
if ($Jobs -le 0) {
    $envCap = $env:BPM_TEST_INTEGRATION_JOB_CAP
    if ([string]::IsNullOrWhiteSpace($envCap)) {
        $cap = 8
    } else {
        $trimmed = $envCap.Trim()
        # Windows PowerShell 5.1 does not support [ref] overloads of TryParse
        # without an awkward boxing step. Use a try/catch + Out-Null pattern
        # that works on both 5.1 and 7+.
        $parsed = 0
        $ok = $false
        try {
            $parsed = [int]::Parse($trimmed, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture)
            $ok = $true
        } catch {
            $ok = $false
        }
        if (-not $ok -or $parsed -le 0) {
            Write-Warning "BPM_TEST_INTEGRATION_JOB_CAP=$envCap is not a positive integer; falling back to default 8."
            $cap = 8
        } else {
            $cap = $parsed
        }
    }
} else {
    $cap = $Jobs
}

# Sanity: cap must be at least 1.
if ($cap -lt 1) { $cap = 1 }

Write-Output "[run-test-integration] using -j$cap (BPM_TEST_INTEGRATION_JOB_CAP=$($env:BPM_TEST_INTEGRATION_JOB_CAP))"

# Run the build with -j applied. Capture exit code so the caller can chain.
& zig build test-integration --summary all "-j$cap"
exit $LASTEXITCODE