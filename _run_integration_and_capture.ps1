$env:BPM_TEST_DB_URL = 'postgres://bpm:bpm@localhost:5433/bpm_test'
$output = zig build test-integration 2>&1 | Out-String
$lines = $output -split "`n"
$failures = @()
$inFailure = $false
foreach ($l in $lines) {
    if ($l -match '^error:') {
        $inFailure = $true
        $failures += $l
    }
    elseif ($inFailure -and ($l -match 'DefinitionNotFound|PersistenceFailed|InstanceInError|snapshot|rows\.rows')) {
        $failures += $l
    }
}
$failures -join "`n"
Write-Host "`n--- SUMMARY ---"
if ($output -match '\d+ passed.*\d+ failed') { Write-Host $Matches[0] }
if ($output -match 'tests passed') { Write-Host ($output | Select-String 'tests passed') }
