# Windows installer — upstream review checkpoint (2026-11-23)

Development branch: `feat/windows-install-update` (internal working branch; **do not open upstream PR from it**). Upstream currently supports manual Windows archive installs. The fork's new `install.ps1` is intended to add a current-user, verified Windows x64 installation/upgrade path without implementing native `proofline update`.

## Evidence received from contributor (Windows PowerShell 5.1)

| Check | Status |
| --- | --- |
| Checksum/archive/version/PATH helper fixtures | PASS, 12/12 |
| Upgrade/rollback/lock/retry-classification fixtures | PASS, 10/10 |
| Official v0.5.1 → v0.5.2 executable upgrade and repeat no-op | PASS |
| Separate-process lock exclusion and retry | PASS |
| Four forced child-termination checkpoints with separate-process recovery | PASS, 4/4 |
| GUI behavior of **new hidden child-launch helper** | **Needs retest** |
| PowerShell 7 local validation | PASS: 12/12, 13/13, lock, real upgrade, 8/8 interruption cases (2026-11-23) |
| Real User PATH registry persistence and fresh-terminal behavior | CI-only test authored, not run |
| Physical power loss / kernel crash / arbitrary in-progress file-write failure | Not tested; do not claim |
| Fresh-install journal and exact-ID stage recovery | Implemented in schema 3; 3 offline + 4 real interruption cases **await Windows execution** |

The forced termination suite uses **test-only instrumented copies** of the installer and validates checkpoint markers. It does not add crash switches to production code. All reported results are based on the contributor's Windows terminal logs, not an independent assistant reproduction.

## User experience cleanup

`scripts/test_install_interruption_real_windows.ps1` used `Start-Process` to launch its PowerShell worker and recovery children, which can create visible console windows. Replaced those launches with `System.Diagnostics.ProcessStartInfo` configured with `UseShellExecute = false`, `CreateNoWindow = true` and `WindowStyle = Hidden`. Concurrent async reads of stdout/stderr prevent full-buffer deadlocks; exit codes and textual diagnostics are retained, with a 90-second timeout. The cross-process lock test explicitly sets `WindowStyle = Hidden` as well. This is **testing-only behavior**; `install.ps1` does not spawn extra PowerShell interpreters, and its actual `proofline.exe --version` smoke check already requests `CreateNoWindow`.

**Retest required:** run the concurrency and four-checkpoint interruption tests on Windows to validate both behavior and lack of popups.

## Submission-readiness review

**Covered well:** strict official HTTPS origin and bounded downloads; exact SHA-256 manifest selection; strict single-member tar extraction; no admin elevation; same-directory staging; hash/execute verification; managed receipt; exclusive lock; conservative handling of unknown states; tested true 0.5.1/0.5.2 binary upgrade; recovery after selected process kills.

**Open before claiming production-ready:**

1. Verify the updated hidden-window test harness on Windows PowerShell 5.1, including all four crash-checkpoint markers.
2. Add PowerShell 7 and Windows offline suites to the upstream Windows CI job and validate, or obtain equivalent repeatable evidence. The existing CI workflow builds/tests the Windows executable, but doesn't run the new installer suites.
3. Test user PATH persistence in a disposable Windows account or with registry restoration; current tests only establish a pure helper and `-NoModifyPath`.
4. Re-run the new first-install tests. Schema-3 now journals the stage ID before creation and removes only a matching hash-verified stage; the 3 new fixture tests and 4 real interruption checkpoints are **unverified on Windows**.
5. Review installation in paths containing spaces/non-ASCII characters, working-directory reparse points, and write-permission failures.
6. Keep Windows `proofline update` support separate. Publishing/hosting a Windows one-line entrypoint needs a publisher-approved path and provenance review; do not invent a hosted URL.

**PR hygiene:** the implementation and tests are currently mixed with extensive exploratory `docs/windows-install-update/*` research notes and experiments. Create the final PR branch from **current `upstream/main`** and transplant only the reviewed `install.ps1`, appropriate tests, succinct Windows README/docs, and optional CI integration. No production test-crash instrumentation or temporary fixtures should be committed. Upstream `AGENTS.md` requires a hidden chronological comment containing user-submitted coding prompts in PR descriptions, unless the author is a member of the `prooflinedev` organization.

**Security caveat:** a `SHA256SUMS` manifest fetched from the same compromised origin as the archive is consistency validation, **not independent publisher authentication**. The versioned install receipt is not a cryptographic signer identity either.


**Post-review work:** Windows PowerShell 5.1 contributor confirmed that the hidden-worker harness still passes both the concurrency test and all four existing upgrade-interruption scenarios. Because the terminal log does not show the desktop UI, the absence of flashing windows is not independently confirmed. The first-install stage-identification fix and all eight forced-interruption test scenarios **subsequently passed** on the contributor's Windows PowerShell 5.1 machine (2026-11-23).


## CI readiness — 2026-11-23

Added `.github/workflows/windows-installer.yml`: pull-request and manual-dispatch-only, with a `windows-2025` two-engine matrix (`powershell.exe` Windows PowerShell 5.1 and `pwsh.exe` PowerShell 7). Both engines run the generator syntax check and the three completely offline validation/upgrade/cross-process-lock scripts. It does **not** run pinned-network release tests or intentional child-termination tests automatically.

**CI status:** workflow committed but not executed. It has no `push` trigger, so pushing this development branch does not spend CI minutes automatically. It will run when a matching pull request is opened, subject to repository Actions settings/limits.


## Windows 5.1 full first-install and upgrade interruption retest — PASS (2026-11-23)

Contributor ran these from `D:\Projects\cli` after pulling the current development branch:
- `scripts/test_install_windows.ps1`: **12 passed, 0 failed**.
- `scripts/test_install_upgrade_windows.ps1`: **13 passed, 0 failed**, including the three new schema-3 fresh-install recovery cases.
- `scripts/test_install_interruption_real_windows.ps1`: **8 of 8 forced-termination scenarios passed**, including all four original upgrade cases and all four fresh-install cases. Actual official v0.5.1 and v0.5.2 archives were downloaded and verified, fresh recovery processes validated the executable and receipt, and the temporary sandbox was deleted successfully.

All results are evidenced by user-provided Windows PowerShell 5.1 output, not a separate execution by this assistant. This supersedes previously pending statements for these exact cases.

**Still unverified:** PowerShell 7 runtime, real User PATH write/read from a new process, whether graphical PowerShell windows appeared on the user's desktop, full device power-loss durability, and arbitrary concurrent/interrupted filesystem writes.


## 2026-11-23: PowerShell 7 and user PATH persistence validation prepared

- Added `scripts/test_install_user_path_ci_windows.ps1`, which **refuses to run outside a GitHub Actions Windows runner**. On that disposable runner it writes a temporary GUID-named directory into the **current user's** PATH, verifies a separate fresh PowerShell process sees that registry change, checks the operation remains idempotent and restores the original User PATH in `finally`. If an unexpected concurrent PATH edit occurs, it refuses to overwrite the new value. This makes it unsuitable for running on the contributor's personal Windows profile.
- The `windows-installer.yml` workflow now runs that CI-only User PATH test in both its `powershell.exe` 5.1 and `pwsh.exe` 7 matrix jobs, after the offline suites. Its trigger is **PR + manual dispatch only**, not a push to the development branch.
- Fixed `scripts/test_install_upgrade_real_windows.ps1` to invoke the same PowerShell binary/edition that the contributor uses to launch the test. Previously, an outer `pwsh` invocation still delegated each real install to `powershell.exe`, which would not meaningfully check the PS7 installer path.

**Execution status: not yet tested.** All new CI PATH checks and real-release PS7 coverage need execution evidence. Do not mark them as passing from the successful Windows 5.1 logs.

Optional local PowerShell 7 smoke test (only if `pwsh.exe` is already available):

```powershell
pwsh.exe -NoProfile -File .\scripts\test_install_windows.ps1
pwsh.exe -NoProfile -File .\scripts\test_install_upgrade_windows.ps1
pwsh.exe -NoProfile -File .\scripts\test_install_concurrency_windows.ps1
pwsh.exe -NoProfile -File .\scripts\test_install_upgrade_real_windows.ps1
pwsh.exe -NoProfile -File .\scripts\test_install_interruption_real_windows.ps1
```

This last group only creates isolated/temp installations; `scripts/test_install_user_path_ci_windows.ps1` is *not* for local execution. If `pwsh.exe` is absent, the proper next verification environment is the planned Windows CI matrix, not an assumption that PowerShell 7 behaves exactly like 5.1.

**Outstanding:** No upstream PR yet; CI must run after a focused branch/PR is prepared, and its minute budget/availability must be considered before starting any workflow.


## PowerShell 7 full local integration results — PASS (2026-11-23)

Contributor ran the tests using the portable `pwsh.exe` from `%LOCALAPPDATA%\Programs\PowerShell\7` on a Windows host, with the development branch at `a68f94c`:

| Test | PowerShell 7 result |
| --- | --- |
| Offline installer validator | **PASS: 12 passed, 0 failed** |
| Offline install, upgrade and recovery | **PASS: 13 passed, 0 failed** |
| Separate-process lock exclusion | **PASS: lock refused competing upgrade; upgrade succeeded after release** |
| Official real-release v0.5.1 → v0.5.2 upgrade | **PASS: installed both real executables; repeated v0.5.2 was a no-op; User PATH unchanged by `-NoModifyPath`** |
| Real first-install and upgrade interruption integration | **PASS: 8/8 checkpoints recovered via fresh PowerShell process; disposable files cleaned** |

Observed real executable digests:
- v0.5.1: `442D14583870A4E44291BD0AD118DFC536AA9D1096FA6E669BCD01B29BCEF379`
- v0.5.2: `7B93F8FE807AAB90133FF19908921079E5A91A51A705118BC3063DC74BD9CCB5`

**Interpretation:** The installer has passed the full user-run Windows PowerShell **5.1 and 7** local matrix for these exact scenarios. This supersedes earlier sections that marked the PowerShell 7 suite as unexecuted. It is not evidence of a GitHub Actions CI run: the workflow's current-user PATH **registry write/read/restore** integration check is still **not executed**, and no upstream pull request has been opened. The user has not explicitly confirmed whether any GUI consoles flashed during the latest hidden-worker tests. Physical power-loss / disk failure durability and independent publisher signing remain outside the verified scope.

**Next gate:** run the Windows CI-only User PATH persistence test on a disposable hosted runner when a focused PR is opened (subject to GitHub Actions capacity); keep registry mutation off the contributor's personal Windows account.
