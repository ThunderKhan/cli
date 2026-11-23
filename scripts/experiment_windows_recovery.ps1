#requires -Version 5.1
<#
.SYNOPSIS
  Simulates abrupt termination and recovery of a staged Windows replacement.
.DESCRIPTION
  Research probe only. Uses plain text fixtures under a random TEMP directory.
  No Proofline files, PATH, registry, network, or privileged operations.
  The Driver launches child PowerShell processes. Worker deliberately terminates
  ITS OWN CHILD process at a fault boundary; the Driver remains running.
.EXAMPLE
  powershell.exe -NoProfile -File .\scripts\experiment_windows_recovery.ps1 -ReportPath "$env:TEMP\proofline-recovery.json"
#>
[CmdletBinding()]
param(
    [ValidateSet('Driver', 'Worker', 'Recover')]
    [string]$Mode = 'Driver',
    [string]$CaseDir,
    [ValidateSet('before-backup', 'after-backup', 'after-replace',
        'corrupt-after-replace', 'after-receipt', 'ambiguous')]
    [string]$Fault = 'before-backup',
    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This experiment requires Windows.'
}

function Put-Text([string]$Path, [string]$Value) {
    [IO.File]::WriteAllText($Path, $Value, [Text.Encoding]::ASCII)
}
function Hash-Of([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
function Get-Paths([string]$Directory) {
    return @{
        marker = Join-Path $Directory '.probe-only'
        active = Join-Path $Directory 'active.txt'
        candidate = Join-Path $Directory 'candidate.txt'
        recovery = Join-Path $Directory 'verified-old.txt'
        apiBackup = Join-Path $Directory 'api-old.txt'
        failedActive = Join-Path $Directory 'failed-active.txt'
        pending = Join-Path $Directory 'pending.json'
        lock = Join-Path $Directory 'install.lock'
        receipt = Join-Path $Directory 'receipt.txt'
    }
}
function Assert-ProbeOnly([hashtable]$Paths) {
    if ([IO.File]::ReadAllText($Paths.marker) -cne 'PROOFLINE_DISPOSABLE_PROBE') {
        throw 'Missing disposable probe marker. Refusing to operate.'
    }
}
function Lock-Probe([hashtable]$Paths) {
    return [IO.File]::Open($Paths.lock, [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}
function Remove-KnownArtifacts([hashtable]$Paths) {
    foreach ($key in @('candidate', 'recovery', 'apiBackup', 'failedActive', 'pending')) {
        if ([IO.File]::Exists($Paths[$key])) {
            [IO.File]::Delete($Paths[$key])
        }
    }
}
function Write-Pending([hashtable]$Paths, [string]$OldHash, [string]$NewHash) {
    $pendingData = [ordered]@{
        schema = 1
        oldSha = $OldHash
        newSha = $NewHash
    }
    $tmp = $Paths.pending + '.tmp'
    Put-Text $tmp (ConvertTo-Json -InputObject $pendingData -Compress)
    [IO.File]::Move($tmp, $Paths.pending)
}
function Inject-Stop() {
    # Force-terminate the CHILD PowerShell process only. This does not model power loss.
    Stop-Process -Id $PID -Force
    throw 'Fault injection should have terminated this child process.'
}

if ($Mode -eq 'Worker' -or $Mode -eq 'Recover') {
    if ([string]::IsNullOrWhiteSpace($CaseDir)) {
        throw 'CaseDir is required for child mode.'
    }
    $p = Get-Paths ([IO.Path]::GetFullPath($CaseDir))
    Assert-ProbeOnly $p
    $lockHandle = Lock-Probe $p
    try {
        if ($Mode -eq 'Worker') {
            if ([IO.File]::Exists($p.pending)) { throw 'Pending transaction already exists.' }
            $oldHash = Hash-Of $p.active
            $newHash = Hash-Of $p.candidate
            if (!$oldHash -or !$newHash -or $oldHash -eq $newHash) {
                throw 'Expected two distinct valid staged fixture hashes.'
            }
            Write-Pending $p $oldHash $newHash
            if ($Fault -eq 'before-backup') { Inject-Stop }

            [IO.File]::Copy($p.active, $p.recovery, $false)
            if ((Hash-Of $p.recovery) -ne $oldHash) {
                throw 'Verified old copy does not match.'
            }
            if ($Fault -eq 'after-backup') { Inject-Stop }

            [IO.File]::Replace($p.candidate, $p.active, $p.apiBackup)
            if ($Fault -eq 'after-replace') { Inject-Stop }

            if ($Fault -eq 'corrupt-after-replace') {
                Put-Text $p.active 'BROKEN'
                Inject-Stop
            }
            if ($Fault -eq 'ambiguous') {
                Put-Text $p.active 'BROKEN'
                Put-Text $p.recovery 'DAMAGED'
                Put-Text $p.apiBackup 'DAMAGED'
                Inject-Stop
            }
            if ($Fault -eq 'after-receipt') {
                Put-Text $p.receipt 'NEW'
                Inject-Stop
            }
            throw 'Unknown fault point.'
        }

        # Separate recovery process: inspect file hashes, not the last phase label.
        if (-not [IO.File]::Exists($p.pending)) {
            throw 'Recovery record does not exist.'
        }
        $record = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($p.pending))
        if ($record.schema -ne 1 -or
            $record.oldSha -cnotmatch '^[A-F0-9]{64}$' -or
            $record.newSha -cnotmatch '^[A-F0-9]{64}$' -or
            $record.oldSha -eq $record.newSha) {
            throw 'Invalid pending transaction record.'
        }
        $activeHash = Hash-Of $p.active
        $outcome = $null

        if ($activeHash -eq $record.newSha) {
            Put-Text $p.receipt 'NEW'
            $outcome = 'FINALIZED_NEW'
        }
        elseif ($activeHash -eq $record.oldSha) {
            Put-Text $p.receipt 'OLD'
            $outcome = 'KEPT_OLD'
        }
        else {
            $source = $null
            if ((Hash-Of $p.recovery) -eq $record.oldSha) {
                $source = $p.recovery
            }
            elseif ((Hash-Of $p.apiBackup) -eq $record.oldSha) {
                $source = $p.apiBackup
            }
            if ($null -eq $source) {
                Write-Output 'AMBIGUOUS_PRESERVED'
                exit 9
            }

            $restore = Join-Path ([IO.Path]::GetDirectoryName($p.active)) 'restore-candidate.txt'
            [IO.File]::Copy($source, $restore, $false)
            if ([IO.File]::Exists($p.active)) {
                # An extra backup may be left after recovery; only remove it once validated.
                [IO.File]::Replace($restore, $p.active, $p.failedActive)
            }
            else {
                [IO.File]::Move($restore, $p.active)
            }
            if ((Hash-Of $p.active) -ne $record.oldSha) {
                throw 'Restored executable hash does not match verified previous hash.'
            }
            Put-Text $p.receipt 'OLD'
            $outcome = 'RESTORED_OLD'
        }

        Remove-KnownArtifacts $p
        Write-Output $outcome
    }
    finally {
        $lockHandle.Dispose()
    }
    exit 0
}

# Driver: no destructive operations outside a fresh, GUID-named TEMP folder.
$root = Join-Path ([IO.Path]::GetTempPath()) ('proofline-recovery-probe-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$cases = @()
$scenarioNames = @('before-backup', 'after-backup', 'after-replace',
    'corrupt-after-replace', 'after-receipt', 'ambiguous')
$expected = @{
    'before-backup' = 'KEPT_OLD'
    'after-backup' = 'KEPT_OLD'
    'after-replace' = 'FINALIZED_NEW'
    'corrupt-after-replace' = 'RESTORED_OLD'
    'after-receipt' = 'FINALIZED_NEW'
    'ambiguous' = 'AMBIGUOUS_PRESERVED'
}
$engine = (Get-Process -Id $PID).Path
$allPassed = $true
$cleanupSucceeded = $false
try {
    foreach ($fault in $scenarioNames) {
        $directory = Join-Path $root $fault
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $p = Get-Paths $directory
        Put-Text $p.marker 'PROOFLINE_DISPOSABLE_PROBE'
        Put-Text $p.active 'OLD'
        Put-Text $p.candidate 'NEW'
        Put-Text $p.receipt 'OLD'
        $oldHash = Hash-Of $p.active
        $newHash = Hash-Of $p.candidate

        # This child deliberately terminates itself; it never kills the driver.
        $workerLog = @(& $engine -NoProfile -NonInteractive -File $PSCommandPath -Mode Worker -CaseDir $directory -Fault $fault)
        $workerExit = $LASTEXITCODE
        $recoveryLog = @(& $engine -NoProfile -NonInteractive -File $PSCommandPath -Mode Recover -CaseDir $directory)
        $recoveryExit = $LASTEXITCODE
        $observed = if ($recoveryLog.Count -gt 0) { [string]$recoveryLog[-1] } else { 'NO_OUTPUT' }
        $activeHash = Hash-Of $p.active
        $pendingPresent = [IO.File]::Exists($p.pending)
        $receipt = [IO.File]::ReadAllText($p.receipt)
        $isAmbiguous = ($fault -eq 'ambiguous')
        $ok = ($workerExit -ne 0) -and ($observed -eq $expected[$fault]) -and
            ($pendingPresent -eq $isAmbiguous)
        if ($isAmbiguous) {
            $ok = $ok -and $recoveryExit -eq 9 -and
                $activeHash -ne $oldHash -and $activeHash -ne $newHash -and
                $receipt -eq 'OLD'
        }
        elseif ($expected[$fault] -eq 'FINALIZED_NEW') {
            $ok = $ok -and $recoveryExit -eq 0 -and
                $activeHash -eq $newHash -and $receipt -eq 'NEW'
        }
        else {
            $ok = $ok -and $recoveryExit -eq 0 -and
                $activeHash -eq $oldHash -and $receipt -eq 'OLD'
        }
        if (-not $ok) { $allPassed = $false }
        $cases += [pscustomobject]@{
            scenario = $fault
            status = if ($ok) { 'PASS' } else { 'FAIL' }
            workerExitCode = $workerExit
            recoveryExitCode = $recoveryExit
            expected = $expected[$fault]
            observed = $observed
            activeSha256 = $activeHash
            expectedOldSha256 = $oldHash
            expectedNewSha256 = $newHash
            pendingPreserved = $pendingPresent
            receipt = $receipt
        }
    }
}
finally {
    if ($allPassed) {
        try {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
            $cleanupSucceeded = $true
        }
        catch {
            $cleanupSucceeded = $false
            $allPassed = $false
        }
    }
}

$report = [pscustomobject]@{
    utc = [DateTime]::UtcNow.ToString('o')
    windows = [Environment]::OSVersion.VersionString
    powershell = $PSVersionTable.PSVersion.ToString()
    scenarioCount = $scenarioNames.Count
    allPassed = $allPassed
    tempDirectory = if ($allPassed) { $null } else { $root }
    sandboxCleaned = $cleanupSucceeded
    cases = @($cases)
}
$json = ConvertTo-Json -InputObject $report -Depth 6
if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath), $json, [Text.Encoding]::UTF8)
    Write-Host "Saved recovery report: $ReportPath"
}
Write-Output $json
if (-not $allPassed) { exit 1 }
