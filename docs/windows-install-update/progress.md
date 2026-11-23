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

## M2 — Installer-managed upgrade/recovery (candidate committed, Windows verification pending)

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


## M2 implementation checkpoint — 2026-11-23

Code is present on `feat/windows-install-update` in `install.ps1`:

- A managed existing installation must have a receipt whose exact SHA-256 digest matches the active file. An unrecognized or incomplete installation is not overwritten.
- The new verified release is staged and smoke-checked **before** modifying the old file.
- The old executable is copied into a verified recovery file, then a versioned pending record is persisted before `File.Replace` attempts an upgrade.
- The installed file is hash-checked and run with `--version` before the receipt is committed; known recovery artifacts are cleaned with the pending journal removed last.
- The next installer run checks for a pending operation **before networking**, so recovery is not blocked by an unavailable release server.
- Recovery classifies actual file state: verified new → finalize; verified old → keep; invalid active + verified recovery copy → restore; no verified copy → refuse and retain journal.
- The installer uses the same stable exclusive lock for upgrades and recovery.

New offline tests in `scripts/test_install_upgrade_windows.ps1` use **fake, never-executed** PE archives. The tests deliberately replace the executable smoke-check only within the test process. Cases: normal old → new upgrade, repeat no-op, finish interrupted upgrade, rollback from corrupted active, ambiguous state refusal, and exclusive-lock failure.

**Status: code authored and committed but NOT executed on Windows.** The M2 installer is not approved for production installation. First run these offline tests; fix any failures. Only afterward exercise two real signed-over-HTTPS releases (pinned `0.5.1` → `0.5.2`) in a fresh disposable installation folder with `-NoModifyPath`.

Command to run from repository root:

```powershell
git pull --ff-only origin feat/windows-install-update
powershell.exe -NoProfile -File .\scripts\test_install_windows.ps1
powershell.exe -NoProfile -File .\scripts\test_install_upgrade_windows.ps1
```

**Not yet tested:** actual two-release executable upgrade, injected failure in production installer, real concurrent installer processes, Windows process-handle failure, true power-loss durability, PS7, or PATH writes. Avoid claiming these have passed.


## M2 Windows validation failure and focused fix — 2026-11-23

Contributor ran both suites on Windows PowerShell 5.1. The original validator suite **passed 12/12**. The new M2 upgrade suite **passed 2/6 and failed 4/6**:

- Failed: normal upgrade, repeat upgrade, finalize interrupted new version, restore old from backup.
- Passed: refuse/preserve ambiguous state, refuse upgrade under exclusive lock.
- The common failure was `System.ArgumentException: The path is not of a legal form` at `[IO.File]::Replace($temp, $Path, $null)` in the receipt update path. That null backup is supported in some .NET documentation, but did not behave as intended on the contributor's PowerShell 5.1 runtime. **Do not assume a platform-independent guarantee from this single failure.**
- Failed test fixtures were intentionally retained in the temporary directory, as designed. No real Proofline installation was involved.

**Implemented fix (Windows re-test pending):** give the receipt update a unique, local backup path in the same installation directory. Keep the previous receipt backup if replacement or post-write verification fails; clean it only after the new receipt is verified. Added a dedicated offline regression test for backup cleanup, increasing the M2 suite from six to **seven** cases.

**Contributor Windows retest, 2026-11-23:** Original M1 validator suite **12/12 passed** and M2 offline suite **7/7 passed** after the receipt-backup fix. Cases included clean upgrade, receipt-backup regression, repeated install no-op, interrupted-new finalization, restored old from corrupt active, ambiguous-state refusal, and exclusive-lock refusal. Earlier 2/6 results remain historical; the revised suite passes. Real executable upgrades are **not yet tested**.


## Real-release M2 integration — prepared, execution pending

GitHub releases v0.5.1 and v0.5.2 were verified to contain the Windows x64 archives and SHA256SUMS files. Added `scripts/test_install_upgrade_real_windows.ps1`:

- Allocates a **fresh** random TEMP directory and invokes `install.ps1` for v0.5.1, v0.5.2, then v0.5.2 again.
- Checks each real executable's `--version`, its SHA-256 hash against the installed receipt, and absence of pending/staged/recovery files.
- Requires old and new executable hashes to differ; verifies repeat installation leaves executable and receipt hashes unchanged.
- Runs with `-NoModifyPath` and checks the user PATH value remains unchanged.
- Removes only its own test directory on success; keeps it on failure. `-KeepFiles` retains artifacts on success.

Run from repository root:

```powershell
git pull --ff-only origin feat/windows-install-update
powershell.exe -NoProfile -File .\scripts\test_install_upgrade_real_windows.ps1
```

**Result (contributor-run, 2026-11-23): PASS.** The real-release integration test installed official v0.5.1 (SHA-256 `442D14583870A4E44291BD0AD118DFC536AA9D1096FA6E669BCD01B29BCEF379`), upgraded to v0.5.2 (SHA-256 `7B93F8FE807AAB90133FF19908921079E5A91A51A705118BC3063DC74BD9CCB5`), and repeated v0.5.2 as a no-op. Both actual executables returned expected version strings; installed receipt hashes matched; user PATH was unchanged and temporary directory cleaned. Verified through the contributor's PowerShell transcript, not by an independent assistant Windows run. **Not** a forced-interruption, separate-process race, PowerShell 7, or power-loss test.


## M2 concurrent installer locking — test ready, Windows execution pending

New script: `scripts/test_install_concurrency_windows.ps1`.

- Uses two separate PowerShell 5.1 processes: one holds the stable installer lock and signals readiness; the other attempts to upgrade a fixture-managed installation.
- Requires a controlled lock-refusal error and verifies the old executable hash, old receipt and absence of journal.
- Releases the lock, waits for the holder to exit, then verifies the upgrade can proceed.
- All fixtures are artificial, never executed, and live under a unique TEMP directory. The test does not access the network, registry or an existing Proofline executable.
- On failure the isolated directory remains for investigation; the holder is stopped during cleanup.

Run:

```powershell
git pull --ff-only origin feat/windows-install-update
powershell.exe -NoProfile -File .\scripts\test_install_concurrency_windows.ps1
```

**Windows PowerShell 5.1 result, contributor-run 2026-11-23: PASS.** A second OS process held the stable lock; the competing installer refused to upgrade and left the old executable, receipt and journal unchanged; following release of the lock the upgrade succeeded and temporary files were cleaned. This validates cooperative cross-process lock exclusion in this deterministic scenario; it does not prove arbitrary race ordering or OS crash durability.


## Real-installer interruption tests — scripted, Windows runtime pending

`scripts/test_install_interruption_real_windows.ps1` is a self-contained integration harness:
- Downloads official pinned 0.5.1 and 0.5.2 archives and SHA256SUMS over the installer's existing restricted HTTPS transport and verifies the archives.
- Installs actual v0.5.1 in a fresh TEMP directory.
- Generates a **temporary copy of install.ps1** with exactly one test-only process-kill injection, leaving the production installer source unchanged.
- Forces child PowerShell termination after journal write, after active replacement, after deliberate corruption of the new active executable, and after receipt update.
- Launches a **fresh PowerShell process** using unmodified installer code to recover offline, then validates the runnable restored/finalized executable's exact version and matching receipt and confirms removal of the pending journal.
- Checks the User PATH value is unchanged, and cleans only its own TEMP directory after success. Failure evidence remains in the sandbox.

```powershell
git pull --ff-only origin feat/windows-install-update
powershell.exe -NoProfile -File .\scripts\test_install_interruption_real_windows.ps1
```

**Execution status: NOT RUN on Windows.** It makes genuine HTTPS requests, runs official executables, and forcibly stops its **test-only child** processes; it does not kill the caller or alter a normal Proofline installation. It tests **process termination**, not disk/power-loss durability. A passing result does not prove all possible interrupt timings or real network interruption safety.


## 2026-11-23: interruption test failure and targeted recovery fix

Contributor ran `scripts/test_install_interruption_real_windows.ps1` against real pinned release archives. The first scenario (`after-journal`) stopped with `A recovery or staging executable remains after successful repair.` The script recorded `Completed 0 of 4 interruption scenarios` and preserved its disposable TEMP evidence directory. **This is a test failure, not a passing interruption result.** Earlier offline and live upgrade tests remain valid for the behaviors they actually covered.

**Root cause from source inspection:** the previous installer created the stage under an independent random GUID, while its schema-2 pending journal contained a different transaction GUID. If its process died after the journal was written but before `File.Replace`, recovery correctly kept the old executable, yet could not identify and delete the still-verified staged executable. Its catch/cleanup logic never ran because the worker was forcibly terminated.

**Fix authored (Windows rerun pending):** assign one transaction GUID before staging. Reuse it in both `.proofline-staged-ID.exe` and the schema-2 pending journal; recovery reconstructs the exact stage path from the validated journal ID, verifies its SHA-256 is the expected new digest before deleting it, and removes the pending journal last. No wildcard deletion of unrelated stage files. Add offline checks for clean staged-file removal and refusal/preservation when staged contents are untrusted.

**Deliberate forensic behavior:** after recovery from an intentionally corrupted active executable, `.proofline-damaged-ID.exe` is kept to aid diagnosis. The real interruption harness now allows and verifies that one quarantined file only in the corruption scenario. All other scenarios still reject leftover staged/recovery artifacts. Preserving a quarantined damaged file is not the same as failing recovery.

**Status:** Source updates committed, **not tested on Windows**. Re-run the offline suite (9 expected assertions) and the full real-interruption suite; do not claim all scenarios passed until the Windows output confirms them. Older first-install journals may not carry a matching stage ID; this fix addresses new schema-2 upgrade journals created after it, not arbitrary old orphan files.
