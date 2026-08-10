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
    check       zig build check — the PI-03 gate (GH-293/ISS-0078): build
                (error-set mismatches fail via the normal compile exit code)
                + `zig fmt --check` scoped to this branch's changed .zig
                files (tools/check_fmt_scope.py).
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
    # PI-03 (GH-293 / ISS-0078): `zig build check` is now a real build-graph
    # step (see build.zig) — build + error-set exit code + `zig fmt --check`
    # scoped to this branch's changed .zig files (tools/check_fmt_scope.py).
    # This subcommand is a thin wrapper; it no longer implements its own
    # interim logic (the former PRE-PI-03 stand-in composed of a raw
    # `zig build` plus an "error set" text grep has been retired now that the
    # real gate exists — see build.zig and CLAUDE.md for the reasoning on why
    # the grep was redundant with the exit code, and why fmt is scoped rather
    # than whole-tree).
    Write-Host "[make.ps1] check: zig build check" -ForegroundColor Cyan
    zig build check
    $checkExit = $LASTEXITCODE
    if ($checkExit -ne 0) {
        Write-Host "[make.ps1] check: FAILED (exit $checkExit)" -ForegroundColor Red
        exit $checkExit
    }
    else {
        Write-Host "[make.ps1] check: PASSED" -ForegroundColor Green
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
    Write-Host "  check       zig build check (build + scoped zig fmt --check) — see GH-293/ISS-0078"
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
