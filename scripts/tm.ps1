# TaskManager wrapper — reads BPM_WORKSPACE_ID from .env and passes it explicitly.
# Usage:
#   . scripts/tm.ps1 claim          -> claim next item into task/current.json
#   . scripts/tm.ps1 release done   -> release current item as DONE
#   . scripts/tm.ps1 release deferred "reason"
#   . scripts/tm.ps1 status         -> show status for r-co
#   . scripts/tm.ps1 pull           -> refresh github mirror

param(
    [Parameter(Position=0, Mandatory=$true)]
    [ValidateSet("claim","release","status","pull")]
    [string]$Command,

    [Parameter(Position=1)]
    [string]$Arg1,       # for release: "done" | "deferred"

    [Parameter(Position=2)]
    [string]$Arg2        # for release deferred: reason string
)

$TM = "C:\Users\tvolo\dev\ai-dala\TaskManager\scripts"
$REPO = "r-co"

# Read BPM_WORKSPACE_ID directly from .env (never from DB local_path)
$WID = (Get-Content .env | Select-String "^BPM_WORKSPACE_ID=" | ForEach-Object { $_.Line.Split("=",2)[1].Trim() }) | Select-Object -First 1
if (-not $WID) { Write-Error "BPM_WORKSPACE_ID not found in .env"; exit 1 }

switch ($Command) {
    "claim" {
        python "$TM\github_pull.py" $REPO --exclude-label requirement
        python "$TM\claim.py" $REPO task/current.json --workspace-id $WID
    }
    "release" {
        $status = if ($Arg1 -eq "deferred") { "DEFERRED" } else { "DONE" }
        if ($status -eq "DEFERRED" -and $Arg2) {
            python "$TM\release.py" task/current.json --status $status --reason $Arg2 --workspace-id $WID
        } else {
            python "$TM\release.py" task/current.json --status $status --workspace-id $WID
        }
    }
    "status" {
        python "$TM\status.py" $REPO
    }
    "pull" {
        python "$TM\github_pull.py" $REPO --exclude-label requirement
    }
}
