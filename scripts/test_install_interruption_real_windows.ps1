#requires -Version 5.1
<#
.SYNOPSIS
  End-to-end tests for forcibly interrupted Windows executable upgrades.
.DESCRIPTION
  Downloads two pinned official Proofline releases once, installs into
  disposable GUID-named TEMP directories, and generates INSTRUMENTED COPIES
  of install.ps1 in the test sandbox. A child PowerShell process runs actual
  Install-ProoflineArchive and terminates itself at a chosen checkpoint.
  Another fresh process calls the unmodified installer's recovery function.
  NEVER changes PATH or an existing Proofline installation.
  Does not simulate an OS crash, disk loss, or power failure.
#>
[CmdletBinding()]
param(
    [ValidateSet('Driver', 'Worker', 'Recover')]
    [string]$Mode = 'Driver',
    [string]$CaseDir,
    [string]$InstallerCopy,
    [string]$FixtureDir,
    [switch]$KeepFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Windows is required for the interruption integration test.'
}
$originalInstaller = Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'

function Require([bool]$Ok, [string]$Message) {
    if (-not $Ok) { throw $Message }
}
function Get-TestBytes([string]$Directory, [string]$Name) {
    return ,([IO.File]::ReadAllBytes((Join-Path $Directory $Name)))
}
function Assert-Sandbox([string]$Directory) {
    if ([string]::IsNullOrWhiteSpace($Directory)) { throw 'Missing test directory.' }
    $marker = Join-Path ([IO.Path]::GetFullPath($Directory)) '.proofline-test-only'
    if (-not [IO.File]::Exists($marker) -or
        [IO.File]::ReadAllText($marker) -cne 'DISPOSABLE_REAL_UPGRADE_TEST') {
        throw 'Missing disposable test marker; refusing to touch a real installation.'
    }
}
function Assert-Installed([string]$Directory, [string]$Version, [bool]$ExpectDamagedEvidence = $false) {
    $exe = Join-Path $Directory 'proofline.exe'
    $receipt = Join-Path $Directory '.proofline-install.receipt.json'
    $pending = Join-Path $Directory '.proofline-install.pending.json'
    Require ([IO.File]::Exists($exe)) 'Active executable missing.'
    Require ([IO.File]::Exists($receipt)) 'Installer receipt missing.'
    Require (-not [IO.File]::Exists($pending)) 'A recovery journal remains after recovery.'
    $data = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($receipt))
    $hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    Require ($data.schema -eq 1 -and $data.version -ceq $Version -and
        $data.sha256 -ceq $hash) 'Receipt does not match installed executable.'
    $output = @(& $exe --version)
    $exitCode = $LASTEXITCODE
    Require ($exitCode -eq 0 -and ($output -join '').Trim() -ceq "proofline $Version") "Executable version check failed for $Version."
    $debris = @(Get-ChildItem -LiteralPath $Directory -Force |
        Where-Object { $_.Name -match '\A\.proofline-(recovery|api-backup|staged|restore)-' })
    Require ($debris.Count -eq 0) 'A recovery or staging executable remains after successful repair.'
    # A corrupted active executable is intentionally kept in a quarantine
    # path following successful rollback. Don't conceal that evidence merely
    # to make this test green; verify exactly what was preserved.
    $damaged = @(Get-ChildItem -LiteralPath $Directory -Force |
        Where-Object { $_.Name -match '\A\.proofline-damaged-[0-9a-f]{32}\.exe\z' })
    if ($ExpectDamagedEvidence) {
        Require ($damaged.Count -eq 1) 'Expected one quarantined corrupted executable.'
        Require ([IO.File]::ReadAllText($damaged[0].FullName) -ceq 'INTENTIONALLY_CORRUPTED') 'Quarantined contents differ from injected corruption.'
    }
    else {
        Require ($damaged.Count -eq 0) 'Unexpected damaged executable remains.'
    }
    return $hash
}

if ($Mode -eq 'Worker' -or $Mode -eq 'Recover') {
    Assert-Sandbox $CaseDir
    if ([string]::IsNullOrWhiteSpace($InstallerCopy) -or
        -not [IO.File]::Exists($InstallerCopy)) {
        throw 'Child requires its installer file.'
    }
    . $InstallerCopy
    if ($Mode -eq 'Recover') {
        Invoke-ProoflinePendingRepair $CaseDir
        Write-Output 'RECOVERY_COMPLETED'
        exit 0
    }
    if ([string]::IsNullOrWhiteSpace($FixtureDir)) { throw 'Missing fixture directory.' }
    $newArchive = Get-TestBytes $FixtureDir 'new.tar.gz'
    $newManifest = Get-TestBytes $FixtureDir 'new-SHA256SUMS'
    # An instrumented installer will kill ONLY THIS worker at the checkpoint.
    [void](Install-ProoflineArchive $newArchive $newManifest '0.5.2' $CaseDir)
    throw 'Worker unexpectedly returned: checkpoint injection did not terminate it.'
}

function Make-InstrumentedInstaller([string]$Source, [string]$Destination, [string]$Checkpoint) {
    # Normalize line endings, then require the exact current production
    # statements. A changed installer should fail this test's setup rather
    # than silently disable fault injection.
    $text = [IO.File]::ReadAllText($Source).Replace("`r`n", "`n")
    # The marker proves this child reached the intentional termination point.
    $mark = '[IO.File]::WriteAllText(([IO.Path]::Combine($directory, ''.injected-stop'')), ''' +
        $Checkpoint + ''', [Text.Encoding]::ASCII)'
    $abort = $mark + "`n" + '                Stop-Process -Id $PID -Force -ErrorAction Stop'
    if ($Checkpoint -eq 'after-journal') {
        $target = '            Write-ProoflineAtomicRecord $pending $record' +
            "`n" + '            try {'
        $replacement = '            Write-ProoflineAtomicRecord $pending $record' +
            "`n" + '            ' + $abort + "`n" + '            try {'
    }
    elseif ($Checkpoint -eq 'after-switch' -or $Checkpoint -eq 'corrupt-after-switch') {
        $target = '                Invoke-ProoflineReplaceWithRetry $stage $destination $paths.api $hash $oldReceipt.sha256' +
            "`n" + '                if ('
        $damage = if ($Checkpoint -eq 'corrupt-after-switch') {
            '                [IO.File]::WriteAllText($destination, "INTENTIONALLY_CORRUPTED", [Text.Encoding]::ASCII)' + "`n"
        }
        else { '' }
        $replacement = '                Invoke-ProoflineReplaceWithRetry $stage $destination $paths.api $hash $oldReceipt.sha256' +
            "`n" + $damage + '                ' + $abort + "`n" + '                if ('
    }
    elseif ($Checkpoint -eq 'after-receipt') {
        $target = '                Write-ProoflineReceipt $receipt $ReleaseVersion $hash' +
            "`n" + '                Clear-ProoflineUpgradeFiles $paths $pending $hash'
        $replacement = '                Write-ProoflineReceipt $receipt $ReleaseVersion $hash' +
            "`n" + '                ' + $abort + "`n" + '                Clear-ProoflineUpgradeFiles $paths $pending $hash'
    }
    else { throw "Unsupported injection checkpoint $Checkpoint." }
    Require ($text.Contains($target)) "Production installer checkpoint '$Checkpoint' changed."
    Require (($text.Split([string[]]@($target), [StringSplitOptions]::None).Count) -eq 2) "Checkpoint '$Checkpoint' is not unique."
    $instrumented = $text.Replace($target, $replacement)
    [IO.File]::WriteAllText($Destination, $instrumented, [Text.UTF8Encoding]::new($false))
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('proofline-real-interruption-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$cache = Join-Path $root 'cache'
[IO.Directory]::CreateDirectory($cache) | Out-Null
$scenarios = @('after-journal', 'after-switch', 'corrupt-after-switch', 'after-receipt')
$expected = @{
    'after-journal' = '0.5.1'
    'after-switch' = '0.5.2'
    'corrupt-after-switch' = '0.5.1'
    'after-receipt' = '0.5.2'
}
$engine = (Get-Process -Id $PID).Path
$pathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
$results = @()
$passed = $false
$cleanup = $false

try {
    . $originalInstaller
    foreach ($pair in @(@('0.5.1', 'old'), @('0.5.2', 'new'))) {
        $v = $pair[0]
        $kind = $pair[1]
        $prefix = "/cli/download/$v"
        Write-Host "Downloading pinned official v$v fixture..."
        $archive = Get-ProoflineOfficialBytes "$prefix/$script:ProoflineArchiveName" $script:MaxArchiveBytes
        $manifest = Get-ProoflineOfficialBytes "$prefix/SHA256SUMS" 8192
        Assert-ProoflineChecksum $archive $manifest
        [void](Get-ProoflineTarExecutable $archive)
        [IO.File]::WriteAllBytes((Join-Path $cache "$kind.tar.gz"), $archive)
        [IO.File]::WriteAllBytes((Join-Path $cache "$kind-SHA256SUMS"), $manifest)
    }
    $oldArchive = Get-TestBytes $cache 'old.tar.gz'
    $oldManifest = Get-TestBytes $cache 'old-SHA256SUMS'

    foreach ($checkpoint in $scenarios) {
        $directory = Join-Path $root $checkpoint
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        [IO.File]::WriteAllText((Join-Path $directory '.proofline-test-only'), 'DISPOSABLE_REAL_UPGRADE_TEST')
        $oldExe = Install-ProoflineArchive $oldArchive $oldManifest '0.5.1' $directory
        $oldDigest = Assert-Installed $directory '0.5.1'
        Write-Host "Initial v0.5.1 installation validated for $checkpoint."

        $copy = Join-Path $root ("instrumented-$checkpoint.ps1")
        Make-InstrumentedInstaller $originalInstaller $copy $checkpoint
        $stdout = Join-Path $root ("worker-$checkpoint.stdout.txt")
        $stderr = Join-Path $root ("worker-$checkpoint.stderr.txt")
        $arguments = '-NoProfile -NonInteractive -File "' + $PSCommandPath +
            '" -Mode Worker -CaseDir "' + $directory +
            '" -FixtureDir "' + $cache + '" -InstallerCopy "' + $copy + '"'
        $worker = Start-Process -FilePath $engine -ArgumentList $arguments -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $workerExit = $worker.ExitCode
        $worker.Dispose()
        $workerOutput = [IO.File]::ReadAllText($stdout) + [IO.File]::ReadAllText($stderr)
        $marker = Join-Path $directory '.injected-stop'
        Require ([IO.File]::Exists($marker)) "Worker failed before reaching $checkpoint; exit $workerExit; output: $workerOutput"
        Require ([IO.File]::ReadAllText($marker) -ceq $checkpoint) "Wrong checkpoint marker for $checkpoint."
        Require ($workerExit -eq -1) "Worker did not terminate as expected at $checkpoint; exit $workerExit; output: $workerOutput"
        $journal = Join-Path $directory '.proofline-install.pending.json'
        Require ([IO.File]::Exists($journal)) "No pending journal existed after forced termination at $checkpoint."
        $activeFile = Join-Path $directory 'proofline.exe'
        $activeDigest = (Get-FileHash -LiteralPath $activeFile -Algorithm SHA256).Hash
        if ($checkpoint -eq 'after-journal') {
            Require ($activeDigest -ceq $oldDigest) 'Journal checkpoint unexpectedly changed old executable.'
        }
        elseif ($checkpoint -eq 'corrupt-after-switch') {
            Require ($activeDigest -cne $oldDigest) 'Corruption checkpoint did not change the active file.'
        }
        else {
            Require ($activeDigest -cne $oldDigest) 'Replacement checkpoint did not change executable.'
        }

        $recoverStdout = Join-Path $root ("recovery-$checkpoint.stdout.txt")
        $recoverStderr = Join-Path $root ("recovery-$checkpoint.stderr.txt")
        $recoverArgs = '-NoProfile -NonInteractive -File "' + $PSCommandPath +
            '" -Mode Recover -CaseDir "' + $directory +
            '" -InstallerCopy "' + $originalInstaller + '"'
        $recoverProc = Start-Process -FilePath $engine -ArgumentList $recoverArgs -Wait -PassThru -RedirectStandardOutput $recoverStdout -RedirectStandardError $recoverStderr
        $recoverExit = $recoverProc.ExitCode
        $recoverProc.Dispose()
        $recoverOutput = [IO.File]::ReadAllText($recoverStdout) +
            [IO.File]::ReadAllText($recoverStderr)
        Require ($recoverExit -eq 0) "Fresh recovery process failed for $checkpoint; output: $recoverOutput"
        $digest = Assert-Installed $directory $expected[$checkpoint] ($checkpoint -eq 'corrupt-after-switch')
        if ($expected[$checkpoint] -eq '0.5.1') {
            Require ($digest -ceq $oldDigest) 'Rollback did not preserve the original executable bytes.'
        }
        else {
            Require ($digest -cne $oldDigest) 'Recovery did not install the different new executable.'
        }
        Write-Host "PASS $checkpoint; fresh process recovered to v$($expected[$checkpoint])."
        $results += [pscustomobject]@{
            checkpoint = $checkpoint
            workerExitCode = $workerExit
            recoveryExitCode = $recoverExit
            recoveredVersion = $expected[$checkpoint]
            recoveredSha256 = $digest
        }
    }

    Require ([Environment]::GetEnvironmentVariable('Path', 'User') -ceq $pathBefore) 'User PATH was modified.'
    $passed = $true
}
catch {
    Write-Warning "FAIL real installer interruption test: $($_.Exception.ToString())"
}
finally {
    if ($passed -and -not $KeepFiles) {
        try {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
            $cleanup = $true
        }
        catch {
            Write-Warning "Could not delete disposable test directory: $($_.Exception.Message)"
            $passed = $false
        }
    }
}
Write-Host "Completed $($results.Count) of $($scenarios.Count) interruption scenarios."
if ($passed) {
    Write-Host 'Real Windows installer interruption integration: PASS'
    if ($KeepFiles) { Write-Host "Retained test evidence at $root" }
    else { Write-Host "Cleaned isolated test directory: $cleanup" }
}
else {
    Write-Warning "Failure evidence preserved at: $root"
    exit 1
}
