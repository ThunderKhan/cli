# Research — One-command Windows installation for Proofline

> Research notes, 2026-11-22. Internal-only working document on `ThunderKhan/cli` branch `feat/windows-install-update`. Source code and documentation were inspected; **no Windows execution or tests were performed as part of this research**. Review decisions with the contributor before implementation.

## 1. Bottom line

**We do not need to create a second Windows executable or MSI installer.** Proofline's Rust build already creates `proofline.exe`. A small PowerShell entry point (`install.ps1`) can download the existing official Windows archive, verify it against the release checksum manifest, inspect/extract it safely, install it into a user-owned directory, and make the executable available on PATH.

A one-command *user experience* is possible without a Windows package manager, but a trusted, official script URL requires upstream publisher cooperation. The script can be developed and tested in the fork before an endpoint is agreed.

The engineering challenge is **not** making a one-liner. It is making every failure leave a safe, explainable state.

## 2. What mature tools actually do

### Deno — straightforward reference implementation
- Official documented Windows command: `irm https://deno.land/install.ps1 | iex`.
- Actual open-source `install.ps1` fetches a release archive for the Windows MSVC target, extracts with `tar.exe`, installs into a directory under the user's home, changes user PATH only when missing, and invokes the installed binary.
- Deno's particular script is short. **It does not show the strict release-manifest integrity and rollback behavior we are proposing for Proofline.** We should learn its user experience and avoid treating it as a security specification.
- Sources: https://docs.deno.com/runtime/getting_started/installation/ and https://github.com/denoland/deno_install/blob/master/install.ps1

### uv — installer and updater as one system
- uv documents a Windows PowerShell installer and support for a custom install directory; it can disable shell modifications.
- uv documents that self-update is for standalone installations, while package-manager installations should use that manager's upgrade path.
- Its Rust updater includes special Windows handling: it renames the existing executable with a `.previous.exe` suffix, launches an installer, and attempts restoration if that installer fails. **This is a design to study, not proof that all interruption cases are solved.**
- Public uv issues #12142 and #12816 describe Windows self-update interruption or broken-state problems. These are useful failure-case case studies, not direct evidence that Proofline has the same bug.
- Sources:
  - https://docs.astral.sh/uv/getting-started/installation/
  - https://docs.astral.sh/uv/reference/installer/
  - https://github.com/astral-sh/uv/blob/main/crates/uv/src/commands/self_update.rs
  - https://github.com/astral-sh/uv/issues/12142
  - https://github.com/astral-sh/uv/issues/12816

### GitHub CLI and Rustup — alternative distribution decisions
- GitHub CLI offers `winget install --id GitHub.cli --source winget`. This is one command, but it requires a package manifest, publisher coordination, and package-manager lifecycle semantics.
- Rustup offers a native installer executable (`rustup-init.exe`) because it manages an entire compiler/toolchain installation, which is more complex than Proofline's single CLI binary.
- Recommendation: **do not start** by producing a Winget manifest, MSI or installer executable. Those are later distribution options if upstream wants them.
- Sources: https://github.com/cli/cli/blob/trunk/docs/install_windows.md and https://rust-lang.org/install

## 3. Verified Proofline pipeline (fork base commit 4d494f67)

1. Rust/Cargo builds Windows `proofline.exe` for `x86_64-pc-windows-msvc`.
2. `scripts/archive.py` packages that executable into `proofline-x86_64-pc-windows-msvc.tar.gz`.
3. Release CI generates `SHA256SUMS`, publishes the checked archives through the existing GitHub/R2 distribution flow, and records GitHub artifact attestations.
4. `README.md` tells Windows users to manually download, check, extract and place `proofline.exe` on PATH; it explicitly states the Unix installer and self-update command don't install Windows binaries.
5. `install.sh` is a Unix-specific shell installer, not usable as a native Windows PowerShell installer.
6. `src/update.rs` contains reusable ideas (release manifest verification, bounded download, staging) but explicitly refuses Windows in its official update target logic.
7. `.github/workflows/ci.yml` already has a Windows build/smoke-test job but no installer integration tests.

**Version caution:** On this research date the latest release observed in earlier investigation was `v0.4.7`, while current source `install.sh` contains a `0.5.0` version constant. Never use a source constant as proof that corresponding release artifacts are published. Resolve release policy against actual published assets.

**Distribution caution:** `https://proofline.sh/cli` currently serves the Unix install experience. We must not claim `https://proofline.sh/install.ps1` or any invented Windows endpoint exists. A final hosted script URL and changes to the official release pipeline require maintainer agreement.

## 4. The proposed one-command experience

An *illustrative* PowerShell installer call could eventually be:

```powershell
irm https://<approved-official-host>/install.ps1 | iex
```

This is **not a live Proofline command**. Piping a downloaded script into `Invoke-Expression` executes whatever was returned without first reviewing the saved file. PowerShell documentation specifically cautions against avoidable use of `Invoke-Expression` and explains that execution policy is not a security boundary. Never tell users to switch off their security policies globally.

A safer and more inspectable development/manual path is to download the reviewed `install.ps1` as a file, inspect it, and execute it explicitly. We should evaluate the final supported invocation only after reviewing actual script provenance, redirect policy, and Windows PowerShell behavior.

## 5. Minimum useful installer design (research proposal)

| Step | What it means | Required failure behavior |
|---|---|---|
| Detect | Check Windows and CPU architecture | Unsupported machine: explain and exit without changes |
| Select | Choose published version, with validated override | Unknown or malformed version: reject |
| Download | Fetch official release archive and SHA256SUMS over HTTPS | Timeout/redirect/oversize: reject; no installed binary changed |
| Verify | Compare archive SHA-256 to exactly one valid matching entry | Any absent, malformed, duplicate or wrong checksum: reject |
| Inspect | Check compressed archive contains only expected regular `proofline.exe` within limits | Reject traversal, unexpected members, links and empty/oversize executable |
| Stage | Extract to an isolated directory, inspect candidate, validate `--version` | Existing installation untouched |
| Commit | Place verified candidate in user-owned location using a recoverable replacement procedure | Failed upgrade keeps previous working version |
| Discover | Offer user-scoped PATH change if necessary; avoid duplicates | No admin elevation, no system-wide PATH or execution-policy changes |
| Verify | Run new binary and report installed version/path | Clear result and reliable cleanup/recovery |

**Open decisions**: installer should use published `latest` pointer or pin the released script version by default; exact default install directory (`%LOCALAPPDATA%\Programs\Proofline\bin` is one possibility, *not an approved default*); whether to alter user PATH automatically; whether to support PowerShell 5.1 and 7 from day one. All decisions need tests and rationale.

PowerShell's user PATH is stored persistently; a change may not reach already-running terminals automatically. Scripts can set current-process PATH separately. Windows includes a `tar` implementation for modern releases, but direct extraction is not a substitute for validating archive members and bounds.

## 6. Why hashes alone don't make it secure

- `SHA256SUMS` lets us detect a corrupted/mismatched archive **relative to that manifest**.
- If the archive and manifest are both substituted by the same compromised origin, a matching hash alone does not prove the publisher's identity.
- Protect the installer script and release downloads with trusted HTTPS, constrained redirects, fixed official origin rules, release-manifest checks, and (if adopted) independently verified build provenance.
- Proofline has adjacent provenance proposals in PRs #72 and #73. We should review their current status/implementation before duplicating trust checks.
- GitHub artifact attestations can cryptographically bind an artifact to a claimed build identity, but verification requires checking the expected publisher/build identity, not just checking that an attestation exists.

Sources: https://docs.github.com/en/actions/concepts/security/artifact-attestations and https://github.com/prooflinedev/cli/pull/72 and https://github.com/prooflinedev/cli/pull/73

## 7. Windows update: useful, but separate from first install

On Windows, an active executable can prevent replacement, depending on the file handles and sharing modes. A self-updating process must not assume it can overwrite its own in-use image like a typical Unix binary.

Study options before selecting one:
- **External helper / installer process**: let the CLI download and verify a candidate, hand off to another process after the CLI exits, then verify/recover.
- **Side-by-side versioned executables + stable launcher**: reduce in-place replacement conflicts; greater architecture and maintenance cost.
- **Rename-and-reinstall with backup**: used in some mature tools; must test crash points, retries and recovery.
- **Fail closed and require the user to close the running process**: simplest reliable upgrade policy for initial installer.

Windows `MoveFileEx` and related APIs can replace files or schedule work until reboot, but their success/error behavior and permissions need direct Windows tests; do not claim a transactional guarantee without a proven state machine and fault injection.

For evidence:
- Microsoft: https://learn.microsoft.com/en-us/windows/win32/fileio/moving-and-replacing-files
- Microsoft: https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw
- Community explanation: https://stackoverflow.com/questions/1748586/i-dont-get-how-a-program-can-update-itself-how-can-i-make-my-software-update

**Recommendation:** decide the installer first; only add `proofline update` after documenting a reproducible Windows-specific update failure and choosing a testable recovery design. Do not write a mini package manager.

## 8. Compatibility details that deserve explicit tests

- Windows PowerShell 5.1 uses the older .NET Framework; PowerShell 7 uses modern .NET. Web/TLS APIs, parsing, and defaults can differ.
- PowerShell's `curl` can refer to a command alias in older Windows PowerShell; avoid ambiguous calls by using `curl.exe` or a chosen .NET/PowerShell API deliberately.
- PowerShell 5.1's `Invoke-WebRequest` gained a script-execution-risk warning after December 2025 security updates unless called in a way that bypasses HTML parsing. Test the real invocation on a patched Windows runner.
- PATH updates should be scoped to the user and avoid duplication or modification of existing unrelated entries.
- Test installation paths with spaces and Unicode, permission failures, interrupted downloads, a locked destination, and concurrent installs.

Sources:
- https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/invoke-webrequest?view=powershell-5.1
- https://support.microsoft.com/en-us/servicing/os/windows/2025/12/powershell-5-1-invoke-webrequest-preventing-script-execution-from-web-content
- https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_environment_variables
- https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies

## 9. Test strategy and next experiment

**First reproducible experiment (baseline)**: on Windows x64, with no Proofline on PATH, execute the current README's manual steps for a known published release. Record OS, PS version, release name, downloaded SHA256SUMS, verified digest, extracted file, install path, PATH changes and final `proofline --version`. We should not call the manual workflow a *broken executable*, only a missing automated installation experience.

**Then test the new script** against:
1. Fresh install, reinstall, explicit version, PATH idempotency.
2. Corrupted download, wrong/duplicate/missing checksum, malicious archives, empty member.
3. Failed network, permissions, full disk, invalid directories, locked executable.
4. Previous version preserved after failed upgrade; concurrent attempts cannot corrupt state.
5. Both PowerShell 5.1 and 7 on Windows CI, plus one real official release E2E.

**Next design decision for discussion with the contributor**: first deliver a robust standalone `install.ps1`, or choose an integrated installer + self-update design from the outset? Suggested route is standalone first with install-layout choices that do not block future update integration, followed by a focused and separately validated updater milestone.

## 10. Source quality and research limits

This pass prioritized directly inspectable tool implementations (Deno, uv, Proofline), primary Microsoft/PowerShell API documentation, GitHub's supply-chain docs, and real uv issue reports. Stack Overflow was used to locate common updater patterns, **not** as normative documentation. Medium/Substack tutorials were not needed to verify these technical facts.

**Nothing in this document is an implementation/test result.** Treat this as a research basis for selecting architecture and writing acceptance tests, not as proof that the project is fixed. Update this file with measured Windows behavior and upstream decisions before coding.

## 11. Commit policy reminder

Research notes are a dedicated documentation milestone. Future work should use a few logical milestone commits, test before committing when feasible, and preserve failure evidence. If a pushed commit fails, do not automatically erase history: fix forward or deliberately consolidate with `--force-with-lease` only when safe and coordinated (see `context.md`).

---

## 12. Research update — How mature tools recover from failed Windows updates (2026-11-22)

### Practical result

There is no universal "transactional installer" that makes every possible Windows failure disappear. Projects reduce risk by **preparing a candidate away from the installed program, keeping a recoverable old version, making the final switch as narrow as possible, and proving what happens when the switch fails**. Power loss, killed processes, access-denied operations and concurrent updaters must be considered separately from handled exceptions.

### Case A — uv: rename old binary, run separate installer, restore on reported failure

Source: https://github.com/astral-sh/uv/blob/main/crates/uv/src/commands/self_update.rs

Inspected `execute_official_installer()` on 2026-11-22:
- Windows-only: obtain `current_exe()` and rename it to a sibling path ending in `.previous.exe`.
- Launch an external PowerShell installer; on unsuccessful return, attempt to rename previous back to the original name.
- On success, request Windows-aware deletion of the previous executable.
- The updater specifically distinguishes standalone installations from package-manager installs using an installation receipt.

**What this buys:** a straightforward recoverable backup on ordinary installer error. **Limit:** the code's restoration path runs only if control returns. A process kill or power loss between rename and install must be separately recovered. This is not a guarantee of every crash point.

### Case B — Scoop: version directories plus 'current' directory junction

Sources:
- https://github.com/ScoopInstaller/Scoop/wiki/The-%27Current%27-Version-Alias
- https://github.com/ScoopInstaller/Scoop/wiki/FAQ
- https://github.com/ScoopInstaller/Scoop/blob/master/lib/install.ps1

Scoop keeps versions in separate directories and normally manages an `apps/<app>/current` junction that points at the selected version. Older versions can remain installed until cleanup, making manual rollback easier.

**What this buys:** a new version can be fully prepared while the old version remains on disk; stable command paths may resolve through a pointer to the selected version.

**Limits:** Scoop's `link_current()` implementation removes an existing junction and then creates a new one; this is not proof of an uninterrupted atomic pointer switch. Deletion of old versions, junction permissions, external PATH references, and crashes during retargeting still need tests. For a single executable, introducing a permanent directory-link layout may be excessive.

### Case C — Rustup: separate updater process that waits for the original process

Sources:
- https://github.com/rust-lang/rustup/blob/main/src/cli/self_update/windows.rs
- https://github.com/rust-lang/rustup/blob/main/src/cli/self_update/stage.rs

On Windows, `run_update()` spawns a prepared replacement process. That process calls `wait_for_parent()` before taking the self-update lock and performing installation work via `install_bins`, then records the result.

**What this buys:** replacement does not need to be attempted by the executable that is currently running; locking helps coordinate concurrent updater attempts.

**Limits:** a helper introduces process-handoff, state, cleanup and failure paths. Copying Rustup's machinery into a single-binary CLI without evidence would be needless complexity.

### D — Microsoft's file-replacement primitives

Sources:
- https://learn.microsoft.com/en-us/windows/win32/fileio/moving-and-replacing-files
- https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw
- https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew
- https://learn.microsoft.com/en-us/dotnet/api/system.io.file.replace

`ReplaceFile` (also exposed by .NET `File.Replace`) can replace one file with another and optionally create a backup of the original. `MoveFileEx` offers rename/replacement options; a delayed-until-reboot operation has fundamentally different semantics and cannot confirm success before reboot. File-sharing access and whether executables are open affect whether operations succeed.

**Do not claim** that .NET `File.Replace` is a complete application transaction, that it works on an in-use executable, or that any two-step rename is atomic. Testing must measure the relevant Windows versions and file handles. Do not depend on the deprecated Windows transactional NTFS (TxF) facility.

### The minimal failure-state contract for Proofline installation

**Invariant:** up to the point of final replacement, the existing installed `proofline.exe` and its PATH entry are untouched. Any failure before that point leaves the old CLI runnable.

Proposed stage model:

1. `PRECHECK`: Windows x64, candidate release, install location, existing-file type, no unsafe symlinks/reparse points, required permissions.
2. `DOWNLOAD`: fetch bounded archive and manifest into an isolated temp folder.
3. `VERIFY`: validate official origin, checksum and strict archive contents.
4. `STAGE`: unpack and confirm candidate executable works, including exact version.
5. `SWAP`: use a narrow replace/backup operation, preferably staging on the *same volume*; do not allow two updates to race.
6. `POSTCHECK`: validate the destination binary; retain backup if validation fails and attempt restore.
7. `CLEANUP`: delete temporary files and backups only after successful postcheck; report failures explicitly.

For a **fresh installation**, there is no old binary to restore, but any partial new installation must not be mistaken for success. For an **existing installation**, the old version must remain preserved or recoverable after all tested failed swaps. A crash after rename but before replacement may leave the conventional path missing; decide and test how the next installer run detects and restores the backup.

### Candidate options for the first implementation

| Strategy | Benefit | Risk / cost | Tentative fit |
|---|---|---|---|
| Staging + fail if installed exe is locked | Small, predictable, no helper | Running instances must be closed | **Preferred starting point** |
| Staging + backup file replacement | Maintains explicit old copy for rollback | Lock/sharing semantics and postcheck restoration need tests | **Explore for installer upgrades** |
| Versioned directories + stable link/shim | Simple retention of multiple versions | New layout, junction or launcher, recovery of pointer | Only if experiments justify it |
| External updater helper | Needed to replace own running image safely | Handoff complexity, cleanup, timeout, locking | Future `proofline update` milestone |

### Failure injection: minimum evidence

1. Connection fails *before* download: old exe unchanged.
2. Wrong checksum/malformed archive: old exe unchanged; no execution of unverified bytes.
3. Candidate executable fails `--version`: old exe unchanged.
4. Destination denies writes: installer fails, no old exe corruption.
5. Installed exe is locked/open: deterministic and documented failure or verified safe replacement; never assume success.
6. Failure immediately after backup/rename: next run can recover a working version.
7. Failure immediately after installing new exe but before postcheck: preserve recovery option.
8. Two parallel installer processes: at most one applies a change; no overlapping corruption.
9. Repeated install/retry: idempotent PATH handling and no stale unsafe intermediates.
10. Power/process termination at swap boundaries: document what is and is *not* guaranteed and use persistent recovery state if needed.

**Decision:** first develop a secure standalone installer with explicit reversible failure behavior and tests, choosing the install directory and staging rules so a later Rust `proofline update` can reuse them. A running-CLI self-updater is a separate milestone, and no helper architecture is selected until reproduced Windows behavior is measured.

**Evidence status:** code/docs research only. No Windows runtime test or interruption test has been performed. Do not claim full crash/power-loss safety without such evidence.
