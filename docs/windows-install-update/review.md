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
| PowerShell 7 validation | Not yet run |
| Real User PATH registry persistence and fresh-terminal behavior | Not yet run |
| Physical power loss / kernel crash / arbitrary in-progress file-write failure | Not tested; do not claim |
| First-install kill-after-journal and staged-file garbage collection | Not tested by current real-interruption suite |

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
4. Run a deliberate **first-install** process-interruption case: schema-1 pending records currently do not carry a stage ID, so an interrupted first install may leave an untracked staged executable. Address this with exact-ID, hash-verified cleanup rather than wildcard deletion.
5. Review installation in paths containing spaces/non-ASCII characters, working-directory reparse points, and write-permission failures.
6. Keep Windows `proofline update` support separate. Publishing/hosting a Windows one-line entrypoint needs a publisher-approved path and provenance review; do not invent a hosted URL.

**PR hygiene:** the implementation and tests are currently mixed with extensive exploratory `docs/windows-install-update/*` research notes and experiments. Create the final PR branch from **current `upstream/main`** and transplant only the reviewed `install.ps1`, appropriate tests, succinct Windows README/docs, and optional CI integration. No production test-crash instrumentation or temporary fixtures should be committed. Upstream `AGENTS.md` requires a hidden chronological comment containing user-submitted coding prompts in PR descriptions, unless the author is a member of the `prooflinedev` organization.

**Security caveat:** a `SHA256SUMS` manifest fetched from the same compromised origin as the archive is consistency validation, **not independent publisher authentication**. The versioned install receipt is not a cryptographic signer identity either.
