#requires -Version 5.1
<#
.SYNOPSIS
  Probe Windows file replacement using disposable local files only.
.DESCRIPTION
  Not an installer or a crash-recovery test. Never touches Proofline.
#>
[CmdletBinding()]
param([string]$ReportPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Windows is required.'
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('proofline-fs-probe-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$script:observations = @()
$cleanupError = $null

function New-CaseFolder([string]$Name) {
    $dir = Join-Path $root $Name
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    return $dir
}
function Put-Text([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, [Text.Encoding]::UTF8)
}
function File-State([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return @{ exists = $false } }
    return @{
        exists = $true
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        length = ([IO.FileInfo]$Path).Length
    }
}
function Record([string]$Name, [string]$Status, [string]$Detail, [object]$Files) {
    $script:observations += [pscustomobject]@{
        name = $Name
        status = $Status
        detail = $Detail
        files = $Files
    }
}

try {
    # Normal replacement: old contents should be preserved in backup.
    try {
        $dir = New-CaseFolder 'normal'
        $active = Join-Path $dir 'active.txt'
        $next = Join-Path $dir 'next.txt'
        $backup = Join-Path $dir 'backup.txt'
        Put-Text $active 'OLD'
        Put-Text $next 'NEW'
        [IO.File]::Replace($next, $active, $backup)
        $ok = ([IO.File]::ReadAllText($active) -eq 'NEW') -and
            ([IO.File]::ReadAllText($backup) -eq 'OLD') -and
            (-not [IO.File]::Exists($next))
        $status = if ($ok) { 'PASS' } else { 'FAIL' }
        Record 'normal-replacement' $status 'Expected NEW active and OLD backup.' @{
            active = File-State $active
            backup = File-State $backup
            next = File-State $next
        }
    } catch {
        Record 'normal-replacement' 'FAIL' $_.Exception.ToString() @{}
    }

    # Invalid candidate: no changes should occur.
    try {
        $dir = New-CaseFolder 'missing'
        $active = Join-Path $dir 'active.txt'
        $next = Join-Path $dir 'missing.txt'
        $backup = Join-Path $dir 'backup.txt'
        Put-Text $active 'OLD'
        $refused = $false
        try { [IO.File]::Replace($next, $active, $backup) } catch { $refused = $true }
        $ok = $refused -and ([IO.File]::ReadAllText($active) -eq 'OLD') -and
            (-not [IO.File]::Exists($backup))
        $status = if ($ok) { 'PASS' } else { 'FAIL' }
        Record 'missing-candidate' $status 'Expected refusal and OLD active.' @{
            active = File-State $active
            backup = File-State $backup
        }
    } catch {
        Record 'missing-candidate' 'FAIL' $_.Exception.ToString() @{}
    }

    # Hold a handle with no sharing and attempt replacement.
    try {
        $dir = New-CaseFolder 'locked'
        $active = Join-Path $dir 'active.txt'
        $next = Join-Path $dir 'next.txt'
        $backup = Join-Path $dir 'backup.txt'
        Put-Text $active 'OLD'
        Put-Text $next 'NEW'
        $handle = $null
        $refused = $false
        try {
            $handle = [IO.File]::Open($active, [IO.FileMode]::Open,
                [IO.FileAccess]::Read, [IO.FileShare]::None)
            try { [IO.File]::Replace($next, $active, $backup) } catch { $refused = $true }
        } finally {
            if ($null -ne $handle) { $handle.Dispose() }
        }
        $ok = $refused -and ([IO.File]::ReadAllText($active) -eq 'OLD') -and
            (-not [IO.File]::Exists($backup))
        $status = if ($ok) { 'PASS' } else { 'FAIL' }
        Record 'locked-target' $status 'Expected refusal with OLD unchanged.' @{
            active = File-State $active
            next = File-State $next
            backup = File-State $backup
        }
    } catch {
        Record 'locked-target' 'FAIL' $_.Exception.ToString() @{}
    }

    # Exclusive lock sanity check; real multi-process contention is a later test.
    try {
        $dir = New-CaseFolder 'mutex'
        $path = Join-Path $dir 'installer.lock'
        $one = $null
        $two = $null
        $refused = $false
        try {
            $one = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try {
                $two = [IO.File]::Open($path, [IO.FileMode]::Open,
                    [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            } catch { $refused = $true }
        } finally {
            if ($null -ne $two) { $two.Dispose() }
            if ($null -ne $one) { $one.Dispose() }
        }
        $status = if ($refused) { 'PASS' } else { 'FAIL' }
        Record 'exclusive-lock' $status 'Second same-process open should be refused.' @{}
    } catch {
        Record 'exclusive-lock' 'FAIL' $_.Exception.ToString() @{}
    }

    # A running COPY of cmd.exe. Observational: either outcome may be valid.
    $child = $null
    try {
        if ([string]::IsNullOrEmpty($env:ComSpec) -or -not [IO.File]::Exists($env:ComSpec)) {
            throw 'ComSpec unavailable.'
        }
        $dir = New-CaseFolder 'running'
        $active = Join-Path $dir 'probe-cmd.exe'
        $next = Join-Path $dir 'next.exe'
        $backup = Join-Path $dir 'backup.exe'
        # Use two DIFFERENT valid Windows binaries; the original probe copied cmd twice.
        # This tests the on-disk version change, not the running process's mapped image.
        $candidateSystemExe = Join-Path $env:windir 'System32\whoami.exe'
        if (-not [IO.File]::Exists($candidateSystemExe)) {
            throw 'Windows whoami.exe unavailable for distinct-binary comparison.'
        }
        [IO.File]::Copy($env:ComSpec, $active)
        [IO.File]::Copy($candidateSystemExe, $next)
        $oldHash = (Get-FileHash -LiteralPath $active -Algorithm SHA256).Hash
        $newHash = (Get-FileHash -LiteralPath $next -Algorithm SHA256).Hash
        if ($oldHash -eq $newHash) {
            throw 'Unexpected identical candidate and original hashes.'
        }
        $child = Start-Process -FilePath $active -ArgumentList '/k' -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 700
        if ($child.HasExited) { throw 'Copied cmd.exe exited early.' }
        $outcome = 'replacement-succeeded'
        try { [IO.File]::Replace($next, $active, $backup) }
        catch { $outcome = 'replacement-refused: ' + $_.Exception.Message }
        $activeState = File-State $active
        $backupState = File-State $backup
        $nextState = File-State $next
        $stateVerified = $activeState.exists -and $backupState.exists -and
            (-not $nextState.exists) -and $activeState.sha256 -eq $newHash -and
            $backupState.sha256 -eq $oldHash
        $status = 'OBSERVED'
        if ($outcome -eq 'replacement-succeeded' -and -not $stateVerified) {
            $status = 'FAIL'
            $outcome += '; expected new active digest and old backup digest, but observed something else'
        }
        if ($outcome -eq 'replacement-succeeded' -and $stateVerified) {
            $outcome += '; distinct on-disk executable hashes verified'
        }
        Record 'running-executable' $status $outcome @{
            oldHash = $oldHash
            candidateHash = $newHash
            stateVerified = $stateVerified
            active = $activeState
            next = $nextState
            backup = $backupState
        }
    } catch {
        Record 'running-executable' 'INCONCLUSIVE' $_.Exception.ToString() @{}
    } finally {
        if ($null -ne $child) {
            try {
                if (-not $child.HasExited) {
                    Stop-Process -Id $child.Id -Force -ErrorAction Stop
                    $child.WaitForExit(5000) | Out-Null
                }
            } catch {
                Record 'child-cleanup' 'FAIL' $_.Exception.ToString() @{}
            }
            $child.Dispose()
        }
    }
} finally {
    try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop }
    catch {
        $cleanupError = $_.Exception.Message
        Record 'sandbox-cleanup' 'FAIL' $cleanupError @{}
    }
}

$report = [pscustomobject]@{
    utc = [DateTime]::UtcNow.ToString('o')
    windows = [Environment]::OSVersion.VersionString
    powershell = $PSVersionTable.PSVersion.ToString()
    is64BitOS = [Environment]::Is64BitOperatingSystem
    sandboxCleaned = ($null -eq $cleanupError)
    observations = @($script:observations)
}
$json = ConvertTo-Json -InputObject $report -Depth 8
if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $path = [IO.Path]::GetFullPath($ReportPath)
    [IO.File]::WriteAllText($path, $json, [Text.Encoding]::UTF8)
    Write-Host "Saved: $path"
}
Write-Output $json
if (@($script:observations | Where-Object { $_.status -eq 'FAIL' }).Count -gt 0) {
    exit 1
}
