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
