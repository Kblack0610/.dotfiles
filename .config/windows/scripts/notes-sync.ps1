# notes-sync.ps1 — PowerShell port of git-sync-notes.sh.
# Mirrors the bash semantics: lock file, fetch, auto-commit, ff-only/rebase,
# push primary, push backup, optional mirror. Logs to %LOCALAPPDATA%\notes-sync\sync.log.

[CmdletBinding()]
param(
    [string]$NotesDir,
    [string]$PrimaryRemote,
    [string]$BackupRemote,
    [string]$MirrorRemote,
    [string]$Branch,
    [string]$HostTag
)

$ErrorActionPreference = 'Stop'

if (-not $NotesDir)      { $NotesDir      = Join-Path $env:USERPROFILE '.notes' }
if (-not $PrimaryRemote) { $PrimaryRemote = if ($env:NOTES_SYNC_PRIMARY_REMOTE) { $env:NOTES_SYNC_PRIMARY_REMOTE } else { 'origin' } }
if (-not $BackupRemote)  { $BackupRemote  = if ($env:NOTES_SYNC_BACKUP_REMOTE)  { $env:NOTES_SYNC_BACKUP_REMOTE  } else { 'backup' } }
if (-not $MirrorRemote)  { $MirrorRemote  = $env:NOTES_SYNC_MIRROR_REMOTE }
if (-not $Branch)        { $Branch        = $env:NOTES_SYNC_BRANCH }
if (-not $HostTag)       { $HostTag       = $env:COMPUTERNAME }

$StateDir = Join-Path $env:LOCALAPPDATA 'notes-sync'
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
$LogFile  = Join-Path $StateDir 'sync.log'
$LockFile = Join-Path $StateDir 'lock'

function Write-Log($msg) {
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $HostTag, $msg
    Add-Content -Path $LogFile -Value $line
}

# Cheap exclusive lock via FileStream. If another sync is running, exit cleanly.
try {
    $lock = [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'Write', 'None')
} catch {
    Write-Log 'SKIP: Another notes sync is already running'
    exit 0
}

try {
    if (-not (Test-Path (Join-Path $NotesDir '.git'))) {
        Write-Log "ERROR: $NotesDir is not a git repository"
        exit 1
    }

    Push-Location $NotesDir
    try {
        function Git { & git @args }
        function Remote-Exists($name) { Git remote get-url $name *> $null; return $LASTEXITCODE -eq 0 }

        if (-not (Remote-Exists $PrimaryRemote)) {
            Write-Log "ERROR: Primary remote '$PrimaryRemote' is not configured"
            exit 1
        }

        if (-not $Branch) {
            $Branch = (Git symbolic-ref --quiet --short HEAD).Trim()
            if (-not $Branch -or $Branch -eq 'HEAD') {
                Write-Log 'ERROR: Unable to determine the current branch'
                exit 1
            }
        }

        $backupEnabled = (Remote-Exists $BackupRemote)

        Write-Log "START: Syncing $NotesDir on branch $Branch"

        Git ls-remote --exit-code --heads $PrimaryRemote $Branch *> $null
        $remoteBranchExists = ($LASTEXITCODE -eq 0)

        if ($remoteBranchExists) {
            Git fetch $PrimaryRemote $Branch
            if ($LASTEXITCODE -ne 0) {
                Write-Log "ERROR: Fetch failed for $PrimaryRemote/$Branch"
                exit 1
            }
        } else {
            Write-Log "INFO: Remote branch $PrimaryRemote/$Branch does not exist yet"
        }

        Git add -A
        Git diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            Git commit -m ("Auto-commit {0} {1}" -f $HostTag, (Get-Date -Format 'yyyy-MM-dd_HH:mm:ss'))
            Write-Log 'COMMIT: Captured local note changes'
        }

        if (-not $remoteBranchExists) {
            Git push -u $PrimaryRemote $Branch
            Write-Log "PUSH: Created $PrimaryRemote/$Branch"
        } else {
            $local  = (Git rev-parse HEAD).Trim()
            $remote = (Git rev-parse "$PrimaryRemote/$Branch").Trim()
            $base   = (Git merge-base HEAD "$PrimaryRemote/$Branch").Trim()

            if ($local -eq $remote) {
                Write-Log "SYNC: Already up to date with $PrimaryRemote/$Branch"
            } elseif ($local -eq $base) {
                Git merge --ff-only "$PrimaryRemote/$Branch"
                Write-Log "SYNC: Fast-forwarded from $PrimaryRemote/$Branch"
            } elseif ($remote -eq $base) {
                Write-Log "SYNC: Local branch is ahead of $PrimaryRemote/$Branch"
            } else {
                Write-Log "SYNC: Diverged from $PrimaryRemote/$Branch, attempting rebase"
                Git rebase "$PrimaryRemote/$Branch"
                if ($LASTEXITCODE -ne 0) {
                    Git rebase --abort *> $null
                    Write-Log "ERROR: Rebase conflict detected; resolve manually in $NotesDir"
                    exit 1
                }
                Write-Log "SYNC: Rebased local commits on top of $PrimaryRemote/$Branch"
            }

            $local  = (Git rev-parse HEAD).Trim()
            $remote = (Git rev-parse "$PrimaryRemote/$Branch").Trim()
            if ($local -ne $remote) {
                Git push $PrimaryRemote $Branch
                Write-Log "PUSH: Updated $PrimaryRemote/$Branch"
            }
        }

        if ($backupEnabled) {
            Git push $BackupRemote $Branch
            Write-Log "BACKUP: Updated $BackupRemote/$Branch"
        } else {
            Write-Log "SKIP: Backup remote '$BackupRemote' is not configured"
        }

        if ($MirrorRemote) {
            if (Remote-Exists $MirrorRemote) {
                try {
                    Git push $MirrorRemote $Branch
                    Write-Log "MIRROR: Updated $MirrorRemote/$Branch"
                } catch {
                    Write-Log "WARN: Mirror push to '$MirrorRemote' failed (non-fatal): $_"
                }
            } else {
                Write-Log "SKIP: Mirror remote '$MirrorRemote' is set but not configured"
            }
        }

        Write-Log 'COMPLETE: Notes sync finished'
    } finally {
        Pop-Location
    }
} finally {
    $lock.Close()
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}
