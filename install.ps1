# Install the official Proofline Windows x64 CLI release for the current user.
# First-install milestone: upgrades are intentionally refused until recovery
# and rollback are integrated and tested. Requires no elevation or modules.
# .\install.ps1 [-Version 0.4.7] [-InstallDir C:\path\to\bin] [-NoModifyPath]
[CmdletBinding()]
param(
    [string]$Version,
    [string]$InstallDir,
    [switch]$NoModifyPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProoflineArchiveName = 'proofline-x86_64-pc-windows-msvc.tar.gz'
$script:ProoflineOrigin = 'https://proofline.sh'
$script:MaxArchiveBytes = 64 * 1024 * 1024
$script:MaxExecutableBytes = 128 * 1024 * 1024

function Assert-ProoflinePlatform {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'The Windows installer can run only on Windows.'
    }
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    if ($architecture -ne 'X64') {
        throw "No official Windows release is available for architecture '$architecture' (expected X64)."
    }
}

function Assert-ProoflineVersion([string]$Value) {
    if ($Value.Length -gt 32 -or $Value -cnotmatch '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z') {
        throw 'Expected a release version of the form X.Y.Z, containing only digits and dots.'
    }
    return $Value
}

function Get-ProoflineOfficialBytes([string]$RelativePath, [int]$MaximumLength) {
    # The relative path is assembled exclusively from constant strings and a
    # validated version. Do not expose arbitrary URLs to installer arguments.
    if ($RelativePath -notmatch '\A/cli/(latest|download/[0-9]+\.[0-9]+\.[0-9]+/(SHA256SUMS|proofline-x86_64-pc-windows-msvc\.tar\.gz))\z') {
        throw 'Invalid official release request.'
    }
    Add-Type -AssemblyName System.Net.Http
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    # PowerShell 5.1 uses .NET Framework, where HttpClientHandler.SslProtocols
    # may not be implemented. Scope TLS 1.2 to this download and restore the
    # process policy afterward. PowerShell 7 retains the system TLS defaults.
    $originalProtocol = $null
    if ($PSVersionTable.PSVersion.Major -eq 5) {
        $originalProtocol = [Net.ServicePointManager]::SecurityProtocol
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(120)
    $cancellation = [Threading.CancellationTokenSource]::new()
    $cancellation.CancelAfter(120000)
    try {
        $uri = [Uri]($script:ProoflineOrigin + $RelativePath)
        for ($redirect = 0; $redirect -le 3; $redirect++) {
            $response = $client.GetAsync($uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancellation.Token).GetAwaiter().GetResult()
            try {
                $status = [int]$response.StatusCode
                if ($status -in @(301, 302, 303, 307, 308)) {
                    if ($redirect -eq 3 -or $null -eq $response.Headers.Location) {
                        throw 'Too many redirects or a redirect without a Location header.'
                    }
                    $nextUri = [Uri]::new($uri, $response.Headers.Location)
                    if ($nextUri.Scheme -cne 'https' -or $nextUri.Host -cne 'proofline.sh' -or
                        -not $nextUri.IsDefaultPort -or $nextUri.UserInfo -ne '' -or
                        $nextUri.AbsolutePath -cne $uri.AbsolutePath -or $nextUri.Query -ne '') {
                        throw "The release endpoint redirected outside its approved HTTPS path: $nextUri"
                    }
                    $uri = $nextUri
                    continue
                }
                if ($status -ne 200) { throw "Official release download failed (HTTP $status): $uri" }
                if ($response.Content.Headers.ContentLength -gt $MaximumLength) {
                    throw 'Release download exceeds the permitted size.'
                }
                $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $outputStream = [IO.MemoryStream]::new()
                try {
                    $buffer = [byte[]]::new(65536)
                    while ($true) {
                        $count = $inputStream.ReadAsync($buffer, 0, $buffer.Length, $cancellation.Token).GetAwaiter().GetResult()
                        if ($count -eq 0) { break }
                        if ($outputStream.Length + $count -gt $MaximumLength) {
                            throw 'Release download exceeds the permitted size.'
                        }
                        $outputStream.Write($buffer, 0, $count)
                    }
                    return ,($outputStream.ToArray())
                }
                finally {
                    $inputStream.Dispose()
                    $outputStream.Dispose()
                }
            }
            finally { $response.Dispose() }
        }
        throw 'Release download exhausted the redirect limit.'
    }
    finally {
        $cancellation.Dispose()
        $client.Dispose()
        $handler.Dispose()
        if ($null -ne $originalProtocol) {
            [Net.ServicePointManager]::SecurityProtocol = $originalProtocol
        }
    }
}

function Get-ProoflineLatestVersion {
    $bytes = Get-ProoflineOfficialBytes '/cli/latest' 128
    $value = ([Text.UTF8Encoding]::new($false, $true)).GetString($bytes)
    if ($value -notmatch '\A([0-9]+\.[0-9]+\.[0-9]+)\r?\n?\z') {
        throw 'The official latest-version pointer is malformed.'
    }
    return (Assert-ProoflineVersion $Matches[1])
}

function Assert-ProoflineChecksum([byte[]]$ArchiveBytes, [byte[]]$ManifestBytes) {
    if ($ArchiveBytes.Length -eq 0 -or $ArchiveBytes.Length -gt $script:MaxArchiveBytes) {
        throw 'Release archive is empty or too large.'
    }
    if ($ManifestBytes.Length -eq 0 -or $ManifestBytes.Length -gt 8192) {
        throw 'Release checksum manifest is empty or too large.'
    }
    $manifest = ([Text.UTF8Encoding]::new($false, $true)).GetString($ManifestBytes)
    $expected = $null
    $seen = @{}
    foreach ($line in ($manifest -split "`n")) {
        $line = $line.TrimEnd("`r")
        if ($line.Length -eq 0) { continue }
        if ($line -cnotmatch '\A([0-9a-fA-F]{64}) [ *](proofline-[a-zA-Z0-9_.-]+\.tar\.gz)\z') {
            throw 'The checksum manifest contains a malformed line.'
        }
        $digest = $Matches[1]
        $name = $Matches[2]
        if ($seen.ContainsKey($name)) { throw "Duplicate checksum entry: $name" }
        $seen[$name] = $true
        if ($name -ceq $script:ProoflineArchiveName) { $expected = $digest }
    }
    if ($null -eq $expected) { throw "SHA256SUMS does not list $script:ProoflineArchiveName" }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $actual = [BitConverter]::ToString($hash.ComputeHash($ArchiveBytes)).Replace('-', '') }
    finally { $hash.Dispose() }
    if ($actual -cne $expected.ToUpperInvariant()) {
        throw 'Release checksum mismatch; no executable has been installed.'
    }
}

function Get-ProoflineTarOctal([byte[]]$Bytes, [int]$Offset, [int]$Width) {
    $field = ([Text.Encoding]::ASCII).GetString($Bytes, $Offset, $Width)
    if ($field -cnotmatch '\A[ \x00]*([0-7]+)[ \x00]*\z') {
        throw 'Invalid tar numeric field.'
    }
    return [Convert]::ToInt64($Matches[1], 8)
}

function Get-ProoflineTarName([byte[]]$Bytes, [int]$Offset, [int]$Width) {
    $stop = $Offset
    while ($stop -lt ($Offset + $Width) -and $Bytes[$stop] -ne 0) {
        if ($Bytes[$stop] -lt 32 -or $Bytes[$stop] -gt 126) {
            throw 'Tar path contains non-printable or non-ASCII bytes.'
        }
        $stop++
    }
    for ($i = $stop; $i -lt ($Offset + $Width); $i++) {
        if ($Bytes[$i] -ne 0) { throw 'Tar string field has data after its terminator.' }
    }
    return [Text.Encoding]::ASCII.GetString($Bytes, $Offset, $stop - $Offset)
}

function Get-ProoflineTarExecutable([byte[]]$ArchiveBytes) {
    # Decode into bounded memory, then independently parse a minimal, strict
    # one-member ustar archive; never ask tar.exe to unpack arbitrary paths.
    $source = [IO.MemoryStream]::new($ArchiveBytes, $false)
    $gzip = [IO.Compression.GZipStream]::new($source, [IO.Compression.CompressionMode]::Decompress)
    $output = [IO.MemoryStream]::new()
    try {
        $buffer = [byte[]]::new(65536)
        $limit = $script:MaxExecutableBytes + 10240
        while (($count = $gzip.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($output.Length + $count -gt $limit) { throw 'Decompressed archive exceeds the permitted size.' }
            $output.Write($buffer, 0, $count)
        }
        $tar = $output.ToArray()
    }
    finally {
        $gzip.Dispose()
        $source.Dispose()
        $output.Dispose()
    }
    if ($tar.Length -lt 1536 -or $tar.Length % 512 -ne 0) {
        throw 'Release tar archive has invalid alignment or is truncated.'
    }
    $sum = 0L
    for ($i = 0; $i -lt 512; $i++) {
        if ($i -ge 148 -and $i -lt 156) { $sum += 32 }
        else { $sum += $tar[$i] }
    }
    if ((Get-ProoflineTarOctal $tar 148 8) -ne $sum) { throw 'Tar header checksum is invalid.' }
    if ((Get-ProoflineTarName $tar 0 100) -cne 'proofline.exe' -or
        (Get-ProoflineTarName $tar 345 155) -ne '' -or
        (Get-ProoflineTarName $tar 157 100) -ne '' -or
        $tar[156] -notin @(0, 48)) {
        throw 'Release archive must contain exactly one regular proofline.exe.'
    }
    $size = Get-ProoflineTarOctal $tar 124 12
    if ($size -lt 2 -or $size -gt $script:MaxExecutableBytes) {
        throw 'Release executable is empty or too large.'
    }
    $afterFile = [long]512 + $size
    $afterPadding = [long]([Math]::Ceiling($afterFile / 512.0) * 512)
    if ($afterPadding + 1024 -gt $tar.Length) { throw 'Release archive is truncated.' }
    for ($i = $afterFile; $i -lt $tar.Length; $i++) {
        if ($tar[$i] -ne 0) { throw 'Release archive has nonzero padding or an unexpected extra member.' }
    }
    $binary = [byte[]]::new([int]$size)
    [Array]::Copy($tar, 512, $binary, 0, [int]$size)
    if ($binary.Length -lt 256 -or $binary[0] -ne 77 -or $binary[1] -ne 90) {
        throw 'Release executable has no valid MZ header.'
    }
    $peOffset = [BitConverter]::ToInt32($binary, 0x3c)
    if ($peOffset -lt 64 -or $peOffset -gt ($binary.Length - 4) -or
        $binary[$peOffset] -ne 80 -or $binary[$peOffset + 1] -ne 69 -or
        $binary[$peOffset + 2] -ne 0 -or $binary[$peOffset + 3] -ne 0) {
        throw 'Release executable has no valid PE signature.'
    }
    return ,$binary
}

function Resolve-ProoflineInstallDir([string]$Requested) {
    if ([string]::IsNullOrWhiteSpace($Requested)) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is missing.' }
        $Requested = [IO.Path]::Combine($env:LOCALAPPDATA, 'Programs', 'Proofline', 'bin')
    }
    # Reject UNC/device paths and relative paths. An explicit path must be an
    # ordinary absolute drive path with no PATH delimiter.
    if ($Requested -notmatch '^[A-Za-z]:[\\/]' -or $Requested.Contains(';')) {
        throw 'InstallDir must be a local absolute drive path without semicolons.'
    }
    return [IO.Path]::GetFullPath($Requested)
}

function Assert-ProoflineNoReparse([string]$Path) {
    if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) {
        if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing an install path that is a symbolic link or reparse point: $Path"
        }
    }
}

function Get-ProoflineUpdatedUserPath([string]$Current, [string]$Directory) {
    if ($null -eq $Current) { $Current = '' }
    $normalized = $Directory.TrimEnd([char[]]@('\', '/'))
    foreach ($entry in ($Current -split ';')) {
        $expanded = [Environment]::ExpandEnvironmentVariables($entry.Trim())
        if ($expanded.TrimEnd([char[]]@('\', '/')) -ieq $normalized) {
            return $null # already present; no registry write needed
        }
    }
    $result = if ($Current.TrimEnd(';') -eq '') { $Directory } else { $Current.TrimEnd(';') + ';' + $Directory }
    if ($result.Length -gt 30000) { throw 'User PATH is too long; add the directory manually.' }
    return $result
}

function Add-ProoflineUserPath([string]$Directory) {
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $result = Get-ProoflineUpdatedUserPath $current $Directory
    if ($null -eq $result) {
        Write-Host 'User PATH already contains the Proofline directory.'
        return
    }
    [Environment]::SetEnvironmentVariable('Path', $result, 'User')
    Write-Host 'Added Proofline to your user PATH. Open a new terminal to use it.'
}


function Assert-ProoflinePathTree([string]$Directory) {
    # A pre-existing reparse-point ancestor can redirect writes outside the
    # requested directory. Check all existing ancestors and refuse such paths.
    $cursor = [IO.DirectoryInfo]::new($Directory)
    while ($null -ne $cursor) {
        if ($cursor.Exists -and
            ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing a directory that contains a reparse point: $($cursor.FullName)"
        }
        $cursor = $cursor.Parent
    }
}

function Get-ProoflineSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Assert-ProoflineExeVersion([string]$Path, [string]$Version) {
    # Run only a checksum-verified release, never a raw unverified download.
    # Process isolation and timeout avoid hanging this installer indefinitely.
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Path
    $startInfo.Arguments = '--version'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Candidate executable did not start.' }
        if (-not $process.WaitForExit(15000)) {
            try { $process.Kill() } catch { }
            throw 'Candidate executable did not exit within 15 seconds.'
        }
        $actual = $process.StandardOutput.ReadToEnd().Trim()
        $stderr = $process.StandardError.ReadToEnd().Trim()
        if ($process.ExitCode -ne 0 -or $actual -cne "proofline $Version" -or $stderr -ne '') {
            throw "Executable version check failed (expected 'proofline $Version', exit $($process.ExitCode), got '$actual' '$stderr')."
        }
    }
    finally { $process.Dispose() }
}

function Write-ProoflineAtomicRecord([string]$Path, [string]$Content) {
    # Only used for first install. Do not overwrite existing transaction files.
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $file = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Content)
        $file.Write($bytes, 0, $bytes.Length)
        $file.Flush($true)
    }
    finally { $file.Dispose() }
    try { [IO.File]::Move($temporary, $Path) }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Assert-ProoflineRecord([string]$Path, [string]$ExpectedVersion, [string]$ExpectedHash) {
    $record = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))
    if ($record.schema -ne 1 -or $record.version -cne $ExpectedVersion -or
        $record.sha256 -cne $ExpectedHash) {
        throw "An existing Proofline installation record does not match this release: $Path"
    }
}

function Install-ProoflineArchive(
    [byte[]]$ArchiveBytes,
    [byte[]]$ChecksumBytes,
    [string]$ReleaseVersion,
    [string]$Directory
) {
    $ReleaseVersion = Assert-ProoflineVersion $ReleaseVersion
    Assert-ProoflineChecksum $ArchiveBytes $ChecksumBytes
    $binary = Get-ProoflineTarExecutable $ArchiveBytes
    $destinationHash = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = [BitConverter]::ToString($destinationHash.ComputeHash($binary)).Replace('-', '')
    }
    finally { $destinationHash.Dispose() }

    $directory = Resolve-ProoflineInstallDir $Directory
    Assert-ProoflinePathTree $directory
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $destination = [IO.Path]::Combine($directory, 'proofline.exe')
    $receipt = [IO.Path]::Combine($directory, '.proofline-install.receipt.json')
    $pending = [IO.Path]::Combine($directory, '.proofline-install.pending.json')
    $lock = [IO.Path]::Combine($directory, '.proofline-install.lock')
    foreach ($path in @($destination, $receipt, $pending, $lock)) {
        Assert-ProoflineNoReparse $path
    }
    $lockStream = $null
    try {
        $lockStream = [IO.File]::Open($lock, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch { throw "Another installer may be running, or the lock file is unavailable: $($_.Exception.Message)" }
    try {
        # This first milestone only installs to a vacant target. A transaction
        # record lets the NEXT run recognize a move completed before receipt.
        if ([IO.File]::Exists($pending)) {
            Assert-ProoflineRecord $pending $ReleaseVersion $hash
            if ([IO.File]::Exists($destination)) {
                if ((Get-ProoflineSha256 $destination) -cne $hash) {
                    throw 'Pending installation has an unexpected executable; manual repair is required.'
                }
                Assert-ProoflineExeVersion $destination $ReleaseVersion
                if (-not [IO.File]::Exists($receipt)) {
                    Write-ProoflineAtomicRecord $receipt ([IO.File]::ReadAllText($pending))
                }
                else { Assert-ProoflineRecord $receipt $ReleaseVersion $hash }
                [IO.File]::Delete($pending)
                return $destination
            }
            if ([IO.File]::Exists($receipt)) {
                throw 'Pending installation has a receipt but no executable; manual repair is required.'
            }
            [IO.File]::Delete($pending)
        }
        if ([IO.File]::Exists($destination) -or [IO.File]::Exists($receipt)) {
            if (-not [IO.File]::Exists($destination) -or -not [IO.File]::Exists($receipt)) {
                throw 'Incomplete or unmanaged existing installation; refusing to overwrite it.'
            }
            Assert-ProoflineRecord $receipt $ReleaseVersion $hash
            if ((Get-ProoflineSha256 $destination) -cne $hash) {
                throw 'Existing Proofline file differs from the expected installer-managed release.'
            }
            Assert-ProoflineExeVersion $destination $ReleaseVersion
            Write-Host "Proofline $ReleaseVersion is already installed; nothing was changed."
            return $destination
        }
        $stage = [IO.Path]::Combine($directory, ('.proofline-staged-' + [guid]::NewGuid().ToString('N') + '.exe'))
        try {
            $stream = [IO.File]::Open($stage, [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $stream.Write($binary, 0, $binary.Length)
                $stream.Flush($true)
            }
            finally { $stream.Dispose() }
            Assert-ProoflineExeVersion $stage $ReleaseVersion
            $record = ConvertTo-Json -Compress -InputObject ([ordered]@{
                schema = 1
                version = $ReleaseVersion
                sha256 = $hash
            })
            Write-ProoflineAtomicRecord $pending $record
            # Same-directory rename; if interrupted after move, pending record
            # can be verified on the next installer invocation.
            [IO.File]::Move($stage, $destination)
            if ((Get-ProoflineSha256 $destination) -cne $hash) {
                throw 'Installed executable hash differs after relocation.'
            }
            Assert-ProoflineExeVersion $destination $ReleaseVersion
            Write-ProoflineAtomicRecord $receipt $record
            [IO.File]::Delete($pending)
            return $destination
        }
        finally {
            if ([IO.File]::Exists($stage)) {
                try { [IO.File]::Delete($stage) }
                catch { Write-Warning "Staged file remains at $stage" }
            }
        }
    }
    finally { $lockStream.Dispose() }
}

function Invoke-ProoflineInstaller([string]$RequestedVersion, [string]$RequestedDirectory, [bool]$ModifyPath) {
    Assert-ProoflinePlatform
    $release = if ([string]::IsNullOrWhiteSpace($RequestedVersion)) {
        Get-ProoflineLatestVersion
    } else { Assert-ProoflineVersion $RequestedVersion }
    $prefix = "/cli/download/$release"
    Write-Host "Downloading Proofline $release for Windows x64..."
    $archive = Get-ProoflineOfficialBytes "$prefix/$script:ProoflineArchiveName" $script:MaxArchiveBytes
    $sums = Get-ProoflineOfficialBytes "$prefix/SHA256SUMS" 8192
    $installed = Install-ProoflineArchive $archive $sums $release $RequestedDirectory
    Write-Host "Verified proofline $release at $installed"
    if ($ModifyPath) {
        try { Add-ProoflineUserPath ([IO.Path]::GetDirectoryName($installed)) }
        catch { Write-Warning "Proofline installed, but PATH update failed: $($_.Exception.Message)" }
    }
    else { Write-Host 'PATH unchanged (-NoModifyPath was selected).' }
    Write-Host 'Next: open a new terminal and run proofline login.'
}

# Dot-sourcing allows the non-mutating validator functions to be unit tested.
if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-ProoflineInstaller $Version $InstallDir (-not [bool]$NoModifyPath) }
    catch {
        [Console]::Error.WriteLine("proofline install: $($_.Exception.Message)")
        exit 1
    }
}
