# Load environment variables from .env and start the backend.
# Usage: .\start-backend.ps1

$envFile = Join-Path $PSScriptRoot ".env"

if (-not (Test-Path $envFile)) {
    Write-Error ".env file not found at $envFile"
    exit 1
}

Get-Content $envFile | ForEach-Object {
    $line = $_.Trim()
    # Skip blank lines and comments
    if ($line -eq '' -or $line.StartsWith('#')) { return }
    $eqIdx = $line.IndexOf('=')
    if ($eqIdx -gt 0) {
        $name  = $line.Substring(0, $eqIdx).Trim()
        $value = $line.Substring($eqIdx + 1).Trim().Trim("'").Trim('"')
        Set-Item -Path "Env:$name" -Value $value
    }
}

Write-Host "Environment loaded from .env — starting backend..."
zig build run
