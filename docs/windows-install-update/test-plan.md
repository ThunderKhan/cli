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

- Windows PowerShell 5.1: **not run**
- PowerShell 7 on Windows: **not run**
- Windows CI: **not run**
- Approval to implement replacement strategy: **pending results**
