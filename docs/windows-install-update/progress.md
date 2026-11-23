# Windows installer — implementation progress

> Internal development notes. This file and other working notes under `docs/windows-install-update/` are not intended for the upstream PR.
>
> Updated 2026-11-23. Branch: `feat/windows-install-update`.

## Milestone M1 — Secure *first* installation foundation

Implemented in `install.ps1` (PowerShell 5.1-compatible syntax, **Windows runtime validation pending**):

- Windows x64-only platform check.
- Explicit `-Version X.Y.Z` or official `/cli/latest` version pointer.
- Bounded HTTPS downloads from `proofline.sh`, with constrained redirect policy and no arbitrary caller-supplied URL.
- Strict `SHA256SUMS` validation, including duplicate, absent, invalid, and incorrect digests.
- Bounded gzip decompression and exact single-regular-member tar parsing; rejects unexpected members, links and traversal.
- Validates Windows PE signature; stages executable on destination volume; runs `--version` with a timeout *after* download verification.
- User-scoped install directory by default, with a reparse-point ancestor check and fixed exclusive lock file.
- For a fresh install, a pending JSON record is written before moving the verified executable. A retry checks the published archive's hash and can finish creating a missing receipt if interrupted after the move.
- Existing matching receipt and binary are a verified no-op (idempotent re-run).
- Existing unmanaged files or a different installed version are **refused**, not overwritten. Safe **upgrade** and recovery of a previously working installed version are explicitly **M2**, not yet delivered.
- User PATH modified only after verified installation, with `-NoModifyPath` opt-out. Does not change execution policy or machine PATH.

### Trust caveat

A SHA-256 checksum downloaded from the same origin as its archive establishes consistency, not independent publisher identity if the origin is compromised. This milestone is not a complete software provenance solution.

### Offline tests

- `scripts/generate_windows_installer_fixtures.py`: creates local artificial PE/tar archives and SHA256SUMS variants for good and hostile input. The fake executable is **never run**.
- `scripts/test_install_windows.ps1`: tests checksum validation, archive acceptance/rejections, version parsing, and PATH idempotency without touching a real installation or contacting the network.

**Authoring-time verification:** Python syntax compilation of fixture generator passed; fixture generator ran on Linux and independently produced a valid deterministic tar/checksum fixture, with a valid header checksum and one `proofline.exe` member. This is **not** PowerShell test execution.

**Windows validation (contributor-reported, 2026-11-23):** Windows PowerShell 5.1 executed `scripts/test_install_windows.ps1` on Windows NT 10.0.26200.0. **12 passed, 0 failed**: official-style valid tar/checksum, missing/duplicate/malformed/mismatched manifests, traversal/unexpected-member/symlink/non-PE archives, tampered archive bytes, strict version syntax and idempotent PATH helper. This is evidence for offline validator functions, **not** a successful download or real installation.

**M1 end-to-end verified in contributor-provided Windows PowerShell 5.1 output (2026-11-23):** real `v0.5.2` official release downloaded, verified and installed into a fresh temporary directory using `-NoModifyPath`. The installed executable returned `proofline 0.5.2`. A second run with the same version and directory said `already installed; nothing was changed`. Final directory listing: `.proofline-install.lock` (0 bytes), `.proofline-install.receipt.json` (106 bytes), `proofline.exe` (8,342,016 bytes). No pending record appeared in the listing. **PATH was explicitly left unchanged.** This is the first live installation of M1, not a test of upgrades or default PATH modification.

**Still pending:** Network failure injection and corrupted real-release cases; PowerShell 7; actual PATH write; real concurrency; interrupted first installation and upgrades.

### Safe contributor test sequence

1. `git pull --ff-only origin feat/windows-install-update`
2. `powershell.exe -NoProfile -File .\scripts\test_install_windows.ps1`
3. Inspect the results before attempting any download/installation.
4. Real installer test later, in an isolated directory with an actual published release, preferably a disposable Windows account/VM. The default path changes user PATH; use `-NoModifyPath` for isolation. Never test upgrades on a valuable installed executable until M2 is delivered.

## M2 — Installer-managed upgrade/recovery (next implementation)

- Reuse prior research's observed `File.Replace` behavior, but with a verified old-executable copy and recoverable pending transaction.
- Validate old version, new candidate and receipt across success and injected failures.
- Handle hard locks, concurrent installers, and retry after process termination.
- Verify the old version is actually runnable after rollback.

## M3 — Windows integration (not started)

- Published release installation and real-binary tests; PS 5.1 and 7 CI; safe user PATH behavior; README usage.
- Coordinate any official script hosting or workflow updates with maintainers rather than inventing a release endpoint.

## Future milestone (not part of M1)

Windows `proofline update`: requires a separately tested process-handoff strategy. It should use the same lock, trust and recovery rules as the PowerShell installer.


## Next integration checkpoint — isolated published Windows release

GitHub's latest published CLI release observed on 2026-11-23 was **v0.5.2** (published 2026-11-22 21:58 UTC), with `proofline-x86_64-pc-windows-msvc.tar.gz` and `SHA256SUMS` assets. This comes from the GitHub release API. It does **not** independently establish that the Proofline CDN endpoint and installer redirect policy will work; that is part of the next Windows test.

From the repository root in a normal non-admin Windows PowerShell session:

```powershell
$probeDir = Join-Path $env:TEMP ("proofline-m1-" + [guid]::NewGuid().ToString("N"))
powershell.exe -NoProfile -File .\install.ps1 -Version 0.5.2 -InstallDir $probeDir -NoModifyPath
& (Join-Path $probeDir 'proofline.exe') --version
powershell.exe -NoProfile -File .\install.ps1 -Version 0.5.2 -InstallDir $probeDir -NoModifyPath
Get-ChildItem -LiteralPath $probeDir -Force | Select-Object Name,Length
```

Record the full installer output, version command result, no-op reinstall output, and folder listing. Do not delete the test folder before we review any failure; a failed first installation may leave recovery evidence. Do **not** test over an existing real Proofline installation at M1. If an error occurs, capture it rather than editing the script manually.


## M1 live integration evidence — 2026-11-23 (contributor run)

The contributor successfully executed:

```powershell
$probeDir = Join-Path $env:TEMP ("proofline-m1-" + [guid]::NewGuid().ToString("N"))
powershell.exe -NoProfile -File .\install.ps1 -Version 0.5.2 -InstallDir $probeDir -NoModifyPath
& (Join-Path $probeDir 'proofline.exe') --version
powershell.exe -NoProfile -File .\install.ps1 -Version 0.5.2 -InstallDir $probeDir -NoModifyPath
Get-ChildItem -LiteralPath $probeDir -Force | Select-Object Name, Length
```

**Observed:** installer printed `Verified proofline 0.5.2`; direct version check returned `proofline 0.5.2`; repeated invocation printed `Proofline 0.5.2 is already installed; nothing was changed.`; folder contained only the expected executable, receipt and lock. Executable length `8342016` bytes. This evidence is from the user's PowerShell transcript, not a separate reproduction by the assistant.

**Remaining M1 caveat:** A successful run does not independently establish resistance to all malicious release-server responses, execution races, crash consistency, nor absence of external compromise. PowerShell 7 and user PATH persistence are untested.

**M2 scope gate:** Implement upgrade in a separate logical milestone without expanding the PR to native Windows self-update. Preserve a known-good installed binary and receipt, keep a pending journal over the replacement window, detect interrupted swaps, verify the result and restore the previous verified executable on ordinary failures. Test upgrade from **two distinct authentic release versions** in a disposable directory before touching a normal installation. Make unexpected file/receipt states fail closed and leave evidence.
