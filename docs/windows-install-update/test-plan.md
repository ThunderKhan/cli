# Windows file-replacement experiment and test plan

> Created 2026-11-23. **No Windows probe has been executed yet.** This is a research test, not an implementation or claim of production-ready rollback.

## Objective

We must check our design assumption before choosing `[IO.File]::Replace` for the Proofline installer. The probe uses only newly created files in a random temporary folder; **it never touches any actual Proofline installation, PATH, registry, or network**.

## Run the experiment

From the checkout on Windows, use a normal non-admin terminal.

Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -File .\scripts\experiment_windows_replacement.ps1 -ReportPath "$env:TEMP\proofline-ps51-result.json"
```

PowerShell 7 (if installed):

```powershell
pwsh.exe -NoProfile -File .\scripts\experiment_windows_replacement.ps1 -ReportPath "$env:TEMP\proofline-ps7-result.json"
```

Do not disable execution policy system-wide. If local scripts are blocked, use an approved disposable environment. Reports live in the temp directory, not in Git. They may include local paths and system information, so inspect before sharing publicly.

## Cases and expected interpretation

| Probe | Expected finding | Meaning |
|---|---|---|
| `normal-replacement` | PASS: new active, old backup | Ordinary `File.Replace` may support a backup-based switch |
| `missing-candidate` | PASS: fails, old active intact | Invalid source does not damage this fixture |
| `locked-target` | PASS: fails, old active intact | Exclusive handle prevents replacement in this fixture |
| `exclusive-lock` | PASS: second handle refused | Local lock-file primitive works; not proof of multi-process safety |
| `running-executable` | OBSERVED or INCONCLUSIVE | Measure outcome; do not assume Windows always refuses or accepts |
| `sandbox-cleanup` | No FAIL | Only temporary files were removed |

The running executable is a temporary **copy of Windows cmd.exe**, not Proofline itself. The probe starts it briefly, attempts replacement, and stops the process. If unable to start it, the result is explicitly marked INCONCLUSIVE. Success of a simple probe is **not** proof of crash consistency, safe rollback or compatibility with a real Proofline release.

## What results will change in architecture.md?

1. If normal replacement works, consider it for a carefully staged install — but keep a verified independent backup and pending-operation record.
2. If replacement fails under a lock, ensure the existing binary remains usable; do not kill unrelated processes to force progress.
3. If a running .exe can be renamed/replaced under particular conditions, document that measured behavior instead of claiming Windows always forbids it.
4. If the API throws, inspect the files afterward. Microsoft documents `ReplaceFileW` failure states where the paths may not remain unchanged.

## Later acceptance tests for the actual installer

- Offline mock release: valid download, corrupt archive, bad/missing/duplicate checksums, path traversal, unexpected file types.
- Before any mutation: staged candidate executable passes the expected version and integrity checks.
- Failure injection: before backup, after backup, after switch, during postcheck, and before final receipt.
- Recovery rerun: inspect expected hashes and pending record; restore verified old version or refuse ambiguous state without destroying evidence.
- Two separate processes: demonstrate lock serialization and no concurrent corruption.
- Other adversarial cases: locked destination, access denied, space/Unicode paths, interrupted network, retry/idempotent PATH.
- Native Windows PowerShell 5.1 and PowerShell 7; one real published Proofline release.
- **Process-kill tests are not power-loss tests.** State explicitly what has and has not been demonstrated.

## Current decision gate

**No replacement mechanism is approved yet.** Review Windows probe JSON results first, then refine `architecture.md` and implement the acceptance tests before the installer.

Sources: [Microsoft ReplaceFileW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew), [.NET File.Replace](https://learn.microsoft.com/en-us/dotnet/api/system.io.file.replace?view=netframework-4.8.1), [Windows file-sharing rules](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew), [our architecture](./architecture.md).

## Execution record

- Windows PowerShell 5.1: **first user-run probe completed on 2026-11-23; detailed results below**
- PowerShell 7 on Windows: **not run**
- Windows CI: **not run**
- Approval to implement replacement strategy: **pending distinct-binary confirmation and failure injection**


## 2026-11-23: first Windows PowerShell 5.1 probe — evidence received

The contributor ran `powershell.exe -NoProfile -File .\scripts\experiment_windows_replacement.ps1 -ReportPath "$env:TEMP\proofline-ps51-result.json"` from `D:\Projects\cli` and pasted the full JSON output.

- Report timestamp: `2026-11-23T00:42:24.2163786Z`.
- Windows version string: `Microsoft Windows NT 10.0.26200.0`.
- PowerShell version: `5.1.26100.9818`; 64-bit OS.
- `sandboxCleaned: true`.
- `normal-replacement`: **PASS** — active became NEW, backup preserved OLD, candidate removed.
- `missing-candidate`: **PASS** — OLD remained active; backup absent.
- `locked-target`: **PASS** — exclusive handle made replacement fail; OLD remained active.
- `exclusive-lock`: **PASS** — a second exclusive open in the *same process* was refused.
- `running-executable`: **OBSERVED: replacement-succeeded** for a running copy of `cmd.exe`; active and backup present and candidate gone. **Important limitation:** the original experiment copied the **same** `cmd.exe` bytes into both active and candidate, so their SHA-256 hashes matched (`CCD79A7568EA9240CCD6FE124807B9D3E4DBC3A4CF92954299AC3029F4A91D02`). We therefore know the file API returned success and moved paths, but have **not** proved an actual binary change or an updater's ability to alter code in an already-running process.

**Interpretation:** This refutes the broad claim that all running Windows executables categorically prohibit replacement. File sharing/mapping behavior matters. It does **not** establish universal behavior or crash-safe recovery. Results are from contributor-supplied output, not an independent run by the assistant.

**Follow-up probe introduced in the next script revision:** use a running temporary copy of `cmd.exe` as active and a copy of Windows `whoami.exe` as the different candidate; record two distinct expected hashes, verify active digest becomes the candidate's and backup retains original if `File.Replace` reports success. This still cannot prove safe recovery from process termination or power loss.

**PowerShell 7:** not installed on the contributor's laptop. This is **not a blocker** for designing PS5.1-compatible installer logic; evaluate PS7 on a Windows runner later. We do not claim PS7 tests passed.

**Next gate:** run the distinct-binary test, then implement recovery state-machine tests with injected failures at transaction boundaries and a separate cross-process locking test. A normal replace test is not a sufficient basis for claiming robust upgrades.


## 2026-11-23: distinct executable version replacement result

Contributor ran the revised PowerShell 5.1 probe at **2026-11-23T00:50:32.0154576Z** on Windows NT 10.0.26200.0 / PowerShell 5.1.26100.9818. All four expected checks reported PASS, and the temporary sandbox was cleaned.

**Running-executable observation:** while a temporary copy of `cmd.exe` remained running, `[IO.File]::Replace` succeeded with a **different** temporary executable copied from `whoami.exe`.

- Old executable digest (preserved in backup): `CCD79A7568EA9240CCD6FE124807B9D3E4DBC3A4CF92954299AC3029F4A91D02`; 339,968 bytes.
- New executable digest (active path after replacement): `23240EF9F8B0A9A324110B1C2331DE31DC1B0E08F5359CB707E51A939AF56CD3`; 98,304 bytes.
- `stateVerified: true`: active hash equals new candidate hash; backup hash equals original; candidate path absent.

**Conclusion [measured]:** Windows allowed this particular `File.Replace` while the original temporary executable was running and preserved the old executable in the backup. **Not established:** guaranteed replaceability of all Windows executables, update of the already-mapped running program, filesystem durability, or recovery after a forced process kill.

**PS7 remains untested locally** because it is not installed. This is not a reason to install it on the contributor's laptop yet.

### Second experiment: deliberate termination and next-process recovery

New probe: `scripts/experiment_windows_recovery.ps1` (all fixtures are ordinary text files). Run from the repository root on Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -File .\scripts\experiment_windows_recovery.ps1 -ReportPath "$env:TEMP\proofline-recovery-result.json"
```

The **Driver** runs six isolated test cases. In each, a child **Worker** writes a pending-operation record, then **terminates its own process** at a chosen boundary. A separate **Recover** child acquires the same exclusive lock, checks actual hashes, and either keeps old, finalizes new, restores old, or refuses ambiguous state while preserving evidence.

| Injected stop | Expected recover result |
|---|---|
| Before backup | `KEPT_OLD` |
| After backup | `KEPT_OLD` |
| After replacement | `FINALIZED_NEW` |
| After intentionally corrupting new active file | `RESTORED_OLD` |
| After writing new receipt | `FINALIZED_NEW` |
| After corrupting new file and both backups | `AMBIGUOUS_PRESERVED` (nonzero exit, pending record retained) |

**Scope and caveats:** the test uses copied text bytes, not native binaries, and does not download anything or touch a Proofline installation. A forced child process termination is stronger than a handled exception but is **not power-loss testing**. This probe only exercises the proposed recovery decision tree; it does not prove final installer correctness, cross-process contention while both are live, or filesystem durability.

On failure, the script preserves its temporary test directory and includes that path in the JSON for inspection. Do not mistake a `PASS` result here for a successful production installation.

**Status:** executed by contributor on Windows PowerShell 5.1; all six scripted scenarios passed on the reported machine. Evidence and limitations follow. Windows PowerShell 7 and the production installer remain untested.


## 2026-11-23: recovery experiment — actual Windows results

Contributor executed `experiment_windows_recovery.ps1` in Windows PowerShell 5.1 and supplied its JSON report. **These are user-provided runtime observations, not an independent run by the assistant.**

- Timestamp (UTC): `2026-11-23T00:54:27.9070385Z`
- OS: `Microsoft Windows NT 10.0.26200.0`; PowerShell: `5.1.26100.9818`; x64.
- `scenarioCount: 6`, `allPassed: true`, `sandboxCleaned: true`.
- The worker process was forcibly terminated in all scenarios (`workerExitCode: -1`); a separately launched recovery process then examined the active fixture and transaction record.

| Deliberately interrupted operation | Expected outcome | Observed outcome | Recovery exit | Evidence |
|---|---|---|---:|---|
| `before-backup` | `KEPT_OLD` | `KEPT_OLD` | 0 | Active digest equals old digest; receipt OLD |
| `after-backup` | `KEPT_OLD` | `KEPT_OLD` | 0 | Active digest equals old digest; receipt OLD |
| `after-replace` | `FINALIZED_NEW` | `FINALIZED_NEW` | 0 | Active digest equals new digest; receipt NEW |
| `corrupt-after-replace` | `RESTORED_OLD` | `RESTORED_OLD` | 0 | Active digest equals old digest after repair; receipt OLD |
| `after-receipt` | `FINALIZED_NEW` | `FINALIZED_NEW` | 0 | Active digest equals new digest; receipt NEW |
| `ambiguous` | `AMBIGUOUS_PRESERVED` | `AMBIGUOUS_PRESERVED` | 9 | Active digest matches neither version; pending record preserved; receipt OLD |

Old fixture SHA-256: `099D90CBEE62F89E6478E153EB3240EFCBE4AC2231BEDC3E84549BBEAABA87E8`. New fixture SHA-256: `A253FF09C5A8678E1FD1962B2C329245E139E45F9CC6CED4E5D7AD42C4108FC0`. Both expected hashes were independently compared against the active file in the driver. All completed recovery scenarios cleared the pending record; the ambiguous case retained it.

### What this validates and what it does not

**Measured:** In six deterministic, disposable **text-file** fixtures, a new PowerShell process correctly classified the active state after terminating a child process, kept or restored the old fixture where appropriate, finalized the verified new fixture, and refused an unrecoverable ambiguous state without destroying the pending record. The temporary sandbox was cleaned after all checks passed.

**Not established:** actual Proofline executable validity or ability to run after restore; installer downloads, SHA-256 manifest trust, malicious archives, PATH semantics, multi-process overlap under a real lock, protection from untrusted pending-record tampering, power-loss/OS-crash durability, Windows PowerShell 7 behavior. A failure between writing the temporary pending record and moving it into place was not injected.

**Decision:** Enough evidence to begin the **real installer** implementation and its offline/security tests. Do not spend more time polishing simulated recovery in isolation unless the actual installer exposes a new risk. Carry these invariants into installer integration tests with real executable smoke checks and a genuine cross-process contention test. No installer is yet implemented in this branch.


## Milestone 1 validator results (reported 2026-11-23)

Contributor ran `powershell.exe -NoProfile -File .\scripts\test_install_windows.ps1` on their Windows PowerShell 5.1 environment. Final log: **12 passed, 0 failed**. Cases: valid official-style release archive; four manifest rejections; four malicious or malformed archive rejections; modified archive checksum rejection; strict versions; PATH idempotency. First invocation was interrupted with Ctrl+C and produced no validation result; the subsequent complete invocation produced the reported pass summary.

**Do not conflate this with installer integration validation:** these tests dot-source non-mutating validator helpers and never download or execute the artificial fixture binary. The new `install.ps1` has not yet been proven to install a real official release.

**Next evidence:** isolated first-install + no-op reinstall using published release `v0.5.2`, followed by PowerShell 7 and recovery/concurrency tests. No default install path or user PATH should be modified during the initial live test.


## M1 real-release installation and idempotency — actual Windows results (2026-11-23)

Contributor ran the installer as a non-elevated PowerShell 5.1 script into a new, GUID-named TEMP directory using `-Version 0.5.2 -NoModifyPath`. Evidence:

| Check | Outcome |
| --- | --- |
| Official Proofline v0.5.2 download and manifest check | Installer completed without error |
| Extract, stage and run actual downloaded `proofline.exe` | `proofline 0.5.2` confirmed |
| Same version re-run in same installation directory | Printed `already installed; nothing was changed` |
| Final directory contents | `proofline.exe` (8,342,016 bytes), receipt (106 bytes), lock file (0 bytes) |
| PATH mutation | Explicitly disabled; installer confirmed PATH unchanged |

**Important testing boundary:** Direct expected file hash and detailed receipt contents were not independently printed; the installer asserted checksum/record integrity and returned success. This is a successful M1 integration run, **not yet upgrade or process interruption validation**. No PowerShell 7 or PATH-registry test is claimed.

**Next test requirement for M2:** use two pinned published releases, e.g. 0.5.1 to 0.5.2 (check release existence before testing), test clean upgrade and idempotency, inject failure between writing backup/pending/replace/receipt, independently compare old/new hashes, prove executable runnable after rollback, and verify two separate installer processes cannot corrupt the installation. Keep all of this in a disposable directory and with `-NoModifyPath`.


## M2 proposed upgrade test suite — candidate committed, execution pending

Source: `scripts/test_install_upgrade_windows.ps1`, using the fake PE archive fixtures built by `scripts/generate_windows_installer_fixtures.py`. The test replaces the binary version-check function in its own PowerShell process, so no synthetic executable is run.

| Offline case | Expected invariant |
| --- | --- |
| Existing managed version upgraded to distinct verified candidate | New hash and receipt; pending journal and recovery copy cleaned |
| Repeat installation of same version | No replacement; same receipt and binary |
| Interrupted upgrade with verified new active | Finalize receipt, delete pending and verified old copy |
| Corrupted active executable with verified old copy | Restore old hash and receipt |
| Corrupted active executable and old backup | Refuse, retain journal and evidence |
| Locked installation path | Refuse before changing old executable |

**Results:** Contributor Windows PowerShell 5.1 rerun on 2026-11-23: **7 passed, 0 failed**, with the original validator suite at **12 passed, 0 failed**. Run future regressions with:

```powershell
powershell.exe -NoProfile -File .\scripts\test_install_upgrade_windows.ps1
```

The suite uses new GUID-named temporary directories and leaves them in place on failure. **Before running a real M2 upgrade**, review these results and then test pinned authentic releases in a disposable directory using `-NoModifyPath`. Existing production installations must not be chosen for the first M2 tests.


## Real Windows release upgrade integration — pending

`scripts/test_install_upgrade_real_windows.ps1` pins official v0.5.1 and v0.5.2, both confirmed available with a Windows x64 archive and checksum manifest. It installs to a unique disposable TEMP directory, never changes user PATH, checks the executable hash against its receipt, compares two different binary hashes, validates `--version`, checks transaction artifacts, and verifies that repeat installation is byte-for-byte idempotent for executable and receipt.

```powershell
powershell.exe -NoProfile -File .\scripts\test_install_upgrade_real_windows.ps1
```

**Execution status: PASS (contributor's Windows PowerShell 5.1, 2026-11-23).** Pinned v0.5.1 was installed (SHA-256 `442D14583870A4E44291BD0AD118DFC536AA9D1096FA6E669BCD01B29BCEF379`), then upgraded to v0.5.2 (SHA-256 `7B93F8FE807AAB90133FF19908921079E5A91A51A705118BC3063DC74BD9CCB5`). Reinstalling v0.5.2 was a no-op; receipt/executable checks passed, user PATH was unchanged and disposable directory was cleaned. Evidence was contributor-provided PowerShell output. Not proof of power-loss consistency or simultaneous-process safety.


## Cross-process lock test — prepared; not yet run

`scripts/test_install_concurrency_windows.ps1` creates an isolated, fake managed installation, starts a second PowerShell process which holds the installation's lock file, and attempts a competing upgrade. The expected result is a lock-refusal error with **no changes to active bytes, receipt or pending record**. The test then releases the holder and verifies a successful upgrade, demonstrating cross-process lock coordination.

```powershell
powershell.exe -NoProfile -File .\scripts\test_install_concurrency_windows.ps1
```

**PASS on contributor's Windows PowerShell 5.1 (2026-11-23).** A second process held the installer lock; a competing upgrade was refused without changing the old executable, receipt, or pending state. After releasing the holder, the upgrade completed and the temporary sandbox was cleaned. This was deterministic contention, not arbitrary simultaneous installer start times.


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


## 2026-11-23: real interruption test blocked by Windows file sharing

Contributor Windows PowerShell 5.1 results:
- Offline upgrade suite: **9 passed, 0 failed**.
- Real installer forced termination after journal creation: **PASS**; a fresh recovery process kept verified runnable v0.5.1.
- Real forced termination after executable replacement: **FAILED before reaching checkpoint**. The underlying `[IO.File]::Replace` raised a Windows file-in-use error. The original harness redirected the worker's stderr into the parent PowerShell error stream, obscuring the exit-code check. Report: **Completed 1 of 4 interruption scenarios**. The test retained its disposable sandbox.

**Diagnosis and limits:** Windows error 32 (`ERROR_SHARING_VIOLATION`) indicates incompatible sharing/open handles, but the output does **not** establish which process held the file. This is not evidence that rollback failed; the intended stop-after-switch never happened.

**Code changes committed, Windows rerun pending:**
1. `install.ps1` retries `File.Replace` only for Windows sharing or lock HRESULTs (`0x80070020`, `0x80070021`), on a bounded schedule of up to six attempts / approximately 4.65 seconds between retries. Before every subsequent attempt, confirm the candidate and previous executable hashes, the absence of an unexpected backup and no reparse-point substitution. Partial, changed, unrecognized or non-sharing failures are not retried and remain subject to journal recovery.
2. A new offline regression test asserts the retry classification refuses arbitrary errors. Offline M2 suite now has **10 tests**, but the new test has not been run on Windows.
3. The real interruption harness uses independent stdout/stderr capture and checks the child exit code. Every injected termination writes a matching checkpoint marker immediately before `Stop-Process`. Missing marker means a normal worker failure, **not** successful crash injection.
4. The after-switch and after-receipt injection anchors were updated to match the current production installer source.

**Revalidation required:** Windows PowerShell 5.1 should run the offline suites and `scripts/test_install_interruption_real_windows.ps1`, confirming every injected marker and fresh-process recovery, with no manual intervention into a valuable Proofline installation. Do not claim interruption reliability until the actual full suite passes.

**Residual scope:** Process termination is not power interruption. Another process may hold the executable longer than the retry period; in that case the installer must preserve/recover the managed state and report failure, rather than overwrite unsafely.

References: [Microsoft system error codes](https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--0-499-), [Microsoft ReplaceFileW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew).


## First-install interruption recovery — implementation and tests (Windows rerun pending)

The preceding Windows validation (12/12 validators, 10/10 upgrade fixtures, 4/4 real upgrade process terminations, plus the cross-process lock test) passed on the contributor's Windows PowerShell 5.1 environment. The *windowless child-process changes* were also retested and both concurrency and 4/4 upgrade interruption scenarios passed; terminal output alone does not confirm whether the user's screen had no visible window flashes.

The original first-install code created a random staged executable before writing a `schema:1` pending record. If the installer was killed before recording that file's identity, recovery could not safely identify or remove it. This is distinct from the already-tested upgrade staging recovery.

Updated `install.ps1`:
- New first installs write a versioned `schema:3` pending record containing a validated 32-character transaction ID **before creating the staged executable**.
- Stage and journal share the exact same ID. Recovery reconstructs that single path itself (never trusts a path from JSON).
- During recovery of a fresh install, if no active executable was published, it removes only the matching *checksum-verified* stage and then removes the journal. Unrecognized or partial staged bytes cause a refusal with files and journal retained.
- If a valid executable was published, the ordinary receipt is verified or restored before clearing the transaction.
- Existing legacy `schema:1` pending recovery remains supported; the new code does not guess or delete unrelated legacy staged files.

Added **3 offline fixture cases** covering exact-ID cleanup, tampered-stage refusal with preserved evidence, and first-install receipt finalization. The offline M2 suite now has **13 tests** (the last known run had 10/10 before these additions). Expanded `scripts/test_install_interruption_real_windows.ps1` with **4 extra** genuinely executed first-install interruption checkpoints (`fresh-after-journal`, `fresh-after-stage`, `fresh-after-move`, `fresh-after-receipt`). Together with the prior 4 upgrade checkpoints, the real suite now has **8 scenarios**, **not yet run** after expansion.

Test children remain windowless; only disposable GUID-named TEMP directories are used. No production forced-kill switches are embedded in the installer.

From the repository root:
```powershell
git pull --ff-only origin feat/windows-install-update
powershell.exe -NoProfile -File .\scripts\test_install_windows.ps1
powershell.exe -NoProfile -File .\scripts\test_install_upgrade_windows.ps1
powershell.exe -NoProfile -File .\scripts\test_install_interruption_real_windows.ps1
```

**Expected if successful:** 12/12 original checks, 13/13 offline upgrade/first-install checks, and 8/8 real forced-interruption checkpoints. **This expectation is not a test result.** Other open items remain PS7 validation, actual user PATH mutation (as opposed to `-NoModifyPath`), and credible system power-loss tests.
