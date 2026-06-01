param()

$logFile = 'C:\Users\tvolo\dev\ai-dala\My-Fab\zig-out\backend-trace-test.log'
$logErr = 'C:\Users\tvolo\dev\ai-dala\My-Fab\zig-out\backend-trace-test-err.log'

if (Test-Path $logFile) { Remove-Item $logFile -Force }
if (Test-Path $logErr) { Remove-Item $logErr -Force }

$env:BPM_DB_URL = 'postgres://bpm:bpm@localhost:5433/bpm_test'
$env:BPM_BOOTSTRAP_TOKEN = 'test-trace-token'
$env:BPM_ENV = 'development'
$env:BPM_LOG_LEVEL = 'DEBUG'
$env:BPM_PORT = '8080'
$env:BPM_IDP_PROVIDER_TYPE = 'keycloak'
$env:BPM_IDP_BASE_URL = 'http://127.0.0.1:8081'
$env:BPM_IDP_ADMIN_CREDENTIALS_REF = 'env:BPM_KEYCLOAK_SECRET'
$env:BPM_IDP_DEFAULT_REALM_OR_TENANT = 'bpm-default'
$env:BPM_KEYCLOAK_SECRET = 'admin'

Write-Host "Starting backend server..."
$proc = Start-Process `
    -FilePath 'C:\Users\tvolo\dev\ai-dala\My-Fab\zig-out\bin\bpm-platform.exe' `
    -RedirectStandardOutput $logFile `
    -RedirectStandardError $logErr `
    -NoNewWindow `
    -PassThru `
    -WorkingDirectory 'C:\Users\tvolo\dev\ai-dala\My-Fab'

Write-Host "Server started with PID: $($proc.Id)"
$proc.Id | Set-Content 'C:\Users\tvolo\dev\ai-dala\My-Fab\zig-out\server-proc.pid'

# Poll health endpoint
Write-Host "Polling health endpoint..."
$healthy = $false
for ($i = 1; $i -le 30; $i++) {
    Start-Sleep -Seconds 2
    try {
        $resp = Invoke-WebRequest -Uri 'http://127.0.0.1:8080/health/live' -TimeoutSec 3 -ErrorAction Stop
        if ($resp.StatusCode -eq 200) {
            Write-Host "Server healthy after $i attempts (status $($resp.StatusCode))"
            $healthy = $true
            break
        }
    } catch {
        $msg = $_.Exception.Message; Write-Host "Attempt $i`: not ready yet - $msg"
    }
    # Check if proc exited
    if ($proc.HasExited) {
        Write-Host "ERROR: Server process exited prematurely with code: $($proc.ExitCode)"
        Write-Host "--- stdout ---"
        if (Test-Path $logFile) { Get-Content $logFile | Select-Object -First 30 }
        Write-Host "--- stderr ---"
        if (Test-Path $logErr) { Get-Content $logErr | Select-Object -First 30 }
        exit 1
    }
}

if (-not $healthy) {
    Write-Host "ERROR: Server did not become healthy in 60s"
    if (Test-Path $logFile) { Get-Content $logFile | Select-Object -First 30 }
    if (Test-Path $logErr) { Get-Content $logErr | Select-Object -First 30 }
    exit 1
}

Write-Host "Server is healthy! Log file contents:"
if (Test-Path $logFile) { Get-Content $logFile | Select-Object -First 5 }

Write-Host "SERVER_READY"
Write-Host "PID=$($proc.Id)"
