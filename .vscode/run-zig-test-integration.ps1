$ErrorActionPreference = 'Stop'
$env:BPM_TEST_DB_URL = 'postgres://bpm:bpm@localhost:5433/bpm_test'
zig build test-integration
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
