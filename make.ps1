<#
.SYNOPSIS
    BPM Platform — single command surface (GH-294 / ISS-0079 / PI-04).

.DESCRIPTION
    Commands to run and validate the BPM Platform stack used to be duplicated
    across README.md, CLAUDE.md, and docs/guides/*.md, forked between bash and
    PowerShell, with every agent hand-assembling env vars plus a raw command.
    This script is the one place those commands live. Every doc now points
    here instead of restating the raw invocation.

    PowerShell 5.1 compatible: no && / || chaining, no ternary operator,
    explicit if/else blocks throughout.

.USAGE
    ./make.ps1 <command>

.COMMANDS
    up          docker compose up -d, then poll every service's health
                status (reusing the healthchecks already defined in
                docker-compose.yml / docker-compose.override.yml) up to
                10 times before failing clearly.
    migrate     zig build migrate, with BPM_DB_URL sourced from .env
                (no manual export required).
    test        zig build test — unit tests only, no services required.
    test-live   waits for Postgres + Keycloak (via the same readiness
                logic as `up`), then runs zig build test-integration with
                BPM_TEST_DB_URL sourced from .env.
    e2e         Playwright E2E tests against a running stack
                (cd web && npm run test:e2e).
    check       interim pre-PI-03 stand-in only — see GH-293. Runs the
                closest currently-real equivalent of the future
                `zig build check` gate: `zig build` + an error-set grep,
                exactly what CLAUDE.md's BACKEND-DEV self-review already
                mandates. NOT the real PI-03 gate.
    help        print this list (also runs with no args).

.NOTES
    Reads .env from the repo root for BPM_DB_URL / BPM_TEST_DB_URL /
    COMPOSE_PROJECT_NAME. Does not hardcode any workspace's ports — every
    parallel checkout of this repo has its own .env with its own port band
    (see docs/anti-patterns.md, parallel-workspace port isolation).
#>

param(
    [Parameter(Position = 0)]
    [string]$Command = "help"
)

# NOTE: deliberately NOT setting $ErrorActionPreference = "Stop" globally.
# Native tools invoked below (zig, npm, docker) routinely write normal
# progress/advisory text to stderr on a SUCCESSFUL run (e.g. `zig build test`
# always logs through stderr). Under PowerShell 5.1, "Stop" turns that into a
# terminating NativeCommandError even when the process's own exit code is 0.
# Every exit path in this script is judged by $LASTEXITCODE instead, which is
# the actual and correct success signal for a native command.
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $RepoRoot

# -----------------------------------------------------------------------------
# .env loader — makes BPM_DB_URL / BPM_TEST_DB_URL / COMPOSE_PROJECT_NAME
# available to this script and to child processes without requiring the
# caller to export them by hand first. This is the actual point of PI-04:
# "service not up" / "env not set" stops being an agent-visible failure.
# -----------------------------------------------------------------------------
function Import-DotEnv {
    param([string]$Path = ".env")

    if (-not (Test-Path $Path)) {
        Write-Host "[make.ps1] WARNING: $Path not found. Copy .env.example to .env and fill in values." -ForegroundColor Yellow
        return
    }

    $lines = Get-Content $Path
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "") {
            continue
        }
        if ($trimmed.StartsWith("#")) {
            continue
        }
        if ($trimmed -notmatch "^[A-Za-z_][A-Za-z0-9_]*=") {
            continue
        }
        $idx = $trimmed.IndexOf("=")
        $name = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim()
        # Strip a single layer of surrounding quotes, if present.
        if ($value.Length -ge 2) {
            $firstChar = $value.Substring(0, 1)
            $lastChar = $value.Substring($value.Length - 1, 1)
            if (($firstChar -eq '"' -and $lastChar -eq '"') -or ($firstChar -eq "'" -and $lastChar -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        Set-Item -Path "Env:$name" -Value $value
    }
}

Import-DotEnv

# -----------------------------------------------------------------------------
# Shared readiness polling — reuses the health status docker-compose.yml /
# docker-compose.override.yml already define for each service, rather than
# reinventing a TCP or HTTP probe. `up` and `test-live` both call this.
# -----------------------------------------------------------------------------
function Wait-ServicesHealthy {
    param(
        [string[]]$Services,
        [int]$MaxAttempts = 10,
        [int]$DelaySeconds = 3
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $statusJson = docker compose ps --format json 2>$null
        if (-not $statusJson) {
            $statusJson = @()
        }
        elseif ($statusJson -isnot [System.Array]) {
            $statusJson = @($statusJson)
        }

        $states = @{}
        foreach ($line in $statusJson) {
            if ($line.Trim() -eq "") {
                continue
            }
            $obj = $line | ConvertFrom-Json
            $states[$obj.Service] = $obj.Health
        }

        $allHealthy = $true
        $summary = @()
        foreach ($svc in $Services) {
            $health = $states[$svc]
            if (-not $health) {
                $health = "not-running"
            }
            $summary += "$svc=$health"
            if ($health -ne "healthy") {
                $allHealthy = $false
            }
        }

        Write-Host "[make.ps1] readiness attempt $attempt/$MaxAttempts : $($summary -join ', ')"

        if ($allHealthy) {
            return $true
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return $false
}

function Invoke-Up {
    Write-Host "[make.ps1] up: docker compose up -d" -ForegroundColor Cyan
    docker compose up -d
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[make.ps1] FAILED: docker compose up -d exited $LASTEXITCODE" -ForegroundColor Red
        exit 1
    }

    $services = @("db", "db_test", "keycloak", "keycloak_gateway")
    $healthy = Wait-ServicesHealthy -Services $services -MaxAttempts 10 -DelaySeconds 3

    if ($healthy) {
        Write-Host "[make.ps1] up: all services healthy" -ForegroundColor Green
        exit 0
    }
    else {
        Write-Host "[make.ps1] FAILED: services did not become healthy after 10 attempts." -ForegroundColor Red
        Write-Host "[make.ps1] Run 'docker compose ps' and 'docker compose logs <service>' to diagnose." -ForegroundColor Red
        exit 1
    }
}

function Invoke-Migrate {
    if (-not $env:BPM_DB_URL) {
        Write-Host "[make.ps1] FAILED: BPM_DB_URL not set. Check .env exists and defines BPM_DB_URL." -ForegroundColor Red
        exit 1
    }
    Write-Host "[make.ps1] migrate: zig build migrate (BPM_DB_URL from .env)" -ForegroundColor Cyan
    zig build migrate
    exit $LASTEXITCODE
}

function Invoke-Test {
    Write-Host "[make.ps1] test: zig build test (unit only)" -ForegroundColor Cyan
    zig build test
    exit $LASTEXITCODE
}

function Invoke-TestLive {
    if (-not $env:BPM_TEST_DB_URL) {
        Write-Host "[make.ps1] FAILED: BPM_TEST_DB_URL not set. Check .env exists and defines BPM_TEST_DB_URL." -ForegroundColor Red
        exit 1
    }

    Write-Host "[make.ps1] test-live: waiting for Postgres + Keycloak..." -ForegroundColor Cyan
    $services = @("db", "db_test", "keycloak", "keycloak_gateway")
    $healthy = Wait-ServicesHealthy -Services $services -MaxAttempts 10 -DelaySeconds 3

    if (-not $healthy) {
        Write-Host "[make.ps1] FAILED: services not healthy after 10 attempts. Run './make.ps1 up' first." -ForegroundColor Red
        exit 1
    }

    Write-Host "[make.ps1] test-live: services healthy, running zig build test-integration (BPM_TEST_DB_URL from .env)" -ForegroundColor Cyan
    zig build test-integration
    exit $LASTEXITCODE
}

function Invoke-E2E {
    Write-Host "[make.ps1] e2e: cd web && npm run test:e2e" -ForegroundColor Cyan
    Push-Location (Join-Path $RepoRoot "web")
    try {
        npm run test:e2e
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    exit $code
}

function Invoke-Check {
    # --- INTERIM STAND-IN, NOT PI-03 (GH-293) ---
    # PI-03 defines a real `zig build check` step (fmt --check + build +
    # error-set-grep, as a single build-graph step). GH-293 is a separate,
    # still-open issue (verified: `gh issue view 293 --json state` -> OPEN;
    # `grep -n 'b.step("check"' build.zig` -> no such step exists in build.zig
    # as of this script). Implementing that gate for real belongs to GH-293,
    # not here — this issue (GH-294/PI-04) is scoped to the command surface,
    # not to building PI-03's gate logic.
    #
    # This subcommand runs the closest currently-real equivalent, composed
    # from exactly the two commands CLAUDE.md's BACKEND-DEV section already
    # mandates before self-review: `zig build` and the "error set" grep on
    # its output. It is a convenience wrapper around existing steps, not a
    # new gate — do not treat a PASS here as equivalent to a future
    # `zig build check` PASS.
    #
    # `zig fmt --check src/` was deliberately tried and dropped from this
    # stand-in: as of this script, it reports 225 pre-existing files as
    # unformatted repo-wide (verified by running it directly against main).
    # `zig fmt` was never part of CLAUDE.md's mandated self-review checklist
    # in the first place, so folding it in here would make `check` fail for
    # reasons unrelated to whatever change is actually being validated —
    # exactly the kind of unrelated-failure noise PI-03 (GH-293) is meant to
    # design deliberately, not something this interim stand-in should
    # pre-empt by accident.
    Write-Host "[make.ps1] check: PRE-PI-03 INTERIM STAND-IN (see GH-293 for the real gate)" -ForegroundColor Yellow

    Write-Host "[make.ps1] check: zig build" -ForegroundColor Cyan
    $buildOutput = zig build 2>&1
    $buildExit = $LASTEXITCODE
    $buildOutput | ForEach-Object { Write-Host $_ }
    if ($buildExit -ne 0) {
        Write-Host "[make.ps1] check: zig build FAILED (exit $buildExit)" -ForegroundColor Red
    }

    $errorSetHits = $buildOutput | Select-String -Pattern "error set" -SimpleMatch:$false -CaseSensitive:$false
    $errorSetExit = 0
    if ($errorSetHits) {
        Write-Host "[make.ps1] check: 'error set' text found in zig build output — a function's return type does not cover all errors it propagates:" -ForegroundColor Red
        $errorSetHits | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        $errorSetExit = 1
    }

    if ($buildExit -ne 0 -or $errorSetExit -ne 0) {
        Write-Host "[make.ps1] check: FAILED (interim stand-in)" -ForegroundColor Red
        exit 1
    }
    else {
        Write-Host "[make.ps1] check: PASSED (interim stand-in — not the real PI-03 gate; see GH-293)" -ForegroundColor Green
        exit 0
    }
}

function Show-Help {
    Write-Host ""
    Write-Host "BPM Platform — make.ps1 (single command surface, GH-294 / ISS-0079 / PI-04)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: ./make.ps1 <command>"
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  up          docker compose up -d, then poll service health up to 10x"
    Write-Host "  migrate     zig build migrate (BPM_DB_URL sourced from .env)"
    Write-Host "  test        zig build test (unit only)"
    Write-Host "  test-live   wait for Postgres + Keycloak, then zig build test-integration"
    Write-Host "  e2e         Playwright E2E tests against a running stack (web/)"
    Write-Host "  check       INTERIM pre-PI-03 stand-in (zig build + error-set grep)"
    Write-Host "              — not the real 'zig build check' gate; see GH-293"
    Write-Host "  help        show this message"
    Write-Host ""
    exit 0
}

switch ($Command) {
    "up"        { Invoke-Up }
    "migrate"   { Invoke-Migrate }
    "test"      { Invoke-Test }
    "test-live" { Invoke-TestLive }
    "e2e"       { Invoke-E2E }
    "check"     { Invoke-Check }
    "help"      { Show-Help }
    "-h"        { Show-Help }
    "--help"    { Show-Help }
    default {
        Write-Host "[make.ps1] Unknown command: $Command" -ForegroundColor Red
        Show-Help
    }
}
