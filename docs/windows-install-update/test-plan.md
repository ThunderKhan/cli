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

**Results:** NOT YET RUN on Windows. Run in Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -File .\scripts\test_install_upgrade_windows.ps1
```

The suite uses new GUID-named temporary directories and leaves them in place on failure. **Before running a real M2 upgrade**, review these results and then test pinned authentic releases in a disposable directory using `-NoModifyPath`. Existing production installations must not be chosen for the first M2 tests.
