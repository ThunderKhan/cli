# Proofline Windows Installation and Update — Project Context

> Internal working document. This is a research and engineering handoff, not a claim that implementation or Windows validation is complete.
>
> Updated: 2026-11-22. This document lives on the contributor's feature branch and is intended to be removed or condensed into maintainable upstream documentation before the final PR.

## 1. Project identity and motivation

- Upstream: https://github.com/prooflinedev/cli
- Contributor fork: https://github.com/ThunderKhan/cli
- Development branch: `feat/windows-install-update`
- Inspected base commit: `4d494f67dab0028c2e2a96e6a8bd2a44b3b0216b`
- Candidate: Ayan Khan; Software Engineering Intern application to Proofline
- Application route: substantial contribution to a Proofline developer-tool repository
- Application page: https://proofline.sh/careers/software-engineering-intern/
- The upstream maintainers have **not** approved this particular proposal; a technically useful PR is not a promise of acceptance, merge, or internship selection.

**Why this work?** Proofline already publishes a native Windows CLI executable, but its documented Windows installation is manual. We want a reproducible, secure, maintainable Windows install experience and, if justified by investigation, safe native self-update. Our ambition is to demonstrate ownership of a real operating-system and release-engineering problem, not inflate the number of features.

## 2. Guidance from Proofline's founder

On 2026-11-22, Mohsen Azimi advised the candidate to:
1. Identify a specific reproducible problem.
2. Show the implementation's behavior and how the fix was verified.
3. Run Proofline on the change.
4. Open a PR that is ready for technical review.
5. Explain which Proofline review findings were accepted or rejected and why.
6. Submit the PR URL, a narrated demonstration of **at most two minutes**, a brief introduction, location, and availability to `intern-applicants@proofline.sh`; the subject must include `Software Engineering Intern`.

This is procedural guidance, **not endorsement of the Windows installer or self-update scope**. A merge is not required for the application.

## 3. Verified upstream starting point (2026-11-22)

The following observations come from files inspected in `prooflinedev/cli` and its fork at the base commit:

- `README.md`, "Windows installation": users download `proofline-x86_64-pc-windows-msvc.tar.gz` and `SHA256SUMS`, verify the SHA-256 checksum, extract `proofline.exe`, place it on PATH, and manually replace it to upgrade. It explicitly says the Unix installer and self-update command do not install Windows binaries.
- `install.sh`: Unix shell installer for Linux/macOS; downloads from `https://proofline.sh/cli/download/<version>/`, checks release SHA256SUMS, stages and installs the binary into a user-owned directory. It currently contains `PROOFLINE_INSTALLER_VERSION=0.5.0`, which is an in-source value and must not be confused with a verified published release.
- `scripts/archive.py`: packages the already-built Windows `proofline.exe` into a deterministic `.tar.gz` archive containing one executable.
- `.github/workflows/ci.yml`: `windows-2025` job compiles Windows x64 CLI, creates the archive, runs `--version`, `setup --print`, and `review --schema`. There is no automated Windows installation/upgrade test at this base commit.
- `.github/workflows/release.yml`: builds the Windows x64 artifact among five target archives, produces SHA256SUMS, and publishes via existing release scripts.
- `scripts/publish-r2.sh` and `scripts/github-assets.py`: manage existing immutable versioned release assets and GitHub releases; any Windows installer distribution must integrate with the established release trust model.
- `src/update.rs`: release discovery and verified update logic, but the official binary update target selection is Linux/macOS. Windows updater architecture must be investigated instead of assuming it is a trivial extension.
- `AGENTS.md`: includes a pull-request metadata requirement; consult current repository instructions again before PR creation.
- The current fork branch exists, is writable, and initially points at the inspected base commit.

A repository scan on 2026-11-22 found no directly overlapping open Windows PowerShell-installer PR; adjacent provenance PRs #72 and #73 may affect trust/integrity design. **Refresh the open PRs/issues before implementation or upstream submission.**

## 4. What gets built versus what gets installed

Do **not** conflate these components:

1. **CLI executable**: `proofline.exe`, native Windows executable compiled from Rust using the `x86_64-pc-windows-msvc` target. Users normally do not compile it themselves.
2. **Release archive**: `proofline-x86_64-pc-windows-msvc.tar.gz`, a compressed package containing `proofline.exe`; this is a delivery format, not an installer program.
3. **Installation script** (proposed): `install.ps1`, a PowerShell script that selects an official release, downloads and verifies its archive, validates extraction, stages the executable into a user-controlled location, optionally updates user PATH, verifies installation, and reports errors.
4. **Self-update** (potential expansion): `proofline update` should eventually be able to update a Windows installation safely. A running executable may be locked on Windows; process coordination and replacement semantics require explicit design and real Windows tests.
5. **Native installer packages**: MSI/MSIX, Winget, Scoop, Chocolatey, and a GUI setup wizard are separate distribution choices. They are **not prerequisites** for a script-based installer, and are not initially in scope.

Illustrative end-user goal: one documented, trusted command to install Proofline; then `proofline --version`, `proofline login`, and ideally `proofline update`. A remote-script pipeline such as `irm ... | iex` is only a *possible* convenience interface, not an approved endpoint or a blanket security recommendation. Script trust, redirects, and execution-policy handling must be considered. Do not claim a URL or endpoint exists until upstream maintainers publish it.

## 5. Working hypotheses and baseline evidence to collect

### Confirmed documentation limitation
Windows users currently follow multiple manual steps to place the CLI on PATH. A proper installer can remove repetitive work and make installation behavior deterministic.

### Not yet demonstrated
- The operational extent of installation failures on typical Windows machines.
- Whether ordinary running processes block replacement of a given installed executable under all relevant APIs and filesystem configurations.
- Which exact Windows self-update strategy best preserves recoverability.
- Whether the proposed commands run identically under Windows PowerShell 5.1 and PowerShell 7.
- What platform/architecture support and install location maintainers will accept.

### Reproduction procedure to record
On a clean or disposable Windows x64 test machine:
1. Record OS edition/build, architecture, shell version, and initial `Get-Command proofline -ErrorAction SilentlyContinue` result.
2. Follow the **published** README Windows installation steps, using a verified, explicitly identified release.
3. Record command outputs, checksum evidence, installation path, PATH state, and `proofline --version`.
4. If testing upgrade limitations, hold a running Proofline process where reproducible; record the specific file-operation result and whether the old installation remains usable.
5. Do not present a subjective "too many commands" experience as a runtime defect. Distinguish an absent automated workflow from a reproduced functional failure.

## 6. Initial engineering goals (subject to research)

**Installer**
- Native PowerShell with no unnecessary third-party dependencies; target Windows x64.
- Explicit, validated version selection; official HTTPS download origin, redirect behavior, timeouts, and download limits.
- Strict SHA-256 manifest parsing: exactly one valid digest entry for the requested archive; reject conflicts and corruption.
- The checksum only binds the archive to the downloaded manifest; it does not independently authenticate the publisher if both can be replaced.
- Inspect compressed archive entries and bounds; reject traversal, unexpected members/metadata, oversized or empty executable; extract into isolated temporary workspace.
- Preflight candidate executable, stage within the destination filesystem, and preserve a previously working binary on every tested failure path.
- User-level install path; no admin rights for the normal path; do not mutate PowerShell execution policy.
- Idempotent user-scoped PATH handling that avoids clobbering other entries or duplicating entries; clearly disclose persistent modifications.
- Fail visibly with clean or recoverable filesystem state.

**Potential Windows self-update**
- Decide architecture only after studying actual Windows replacement semantics.
- Protect current installation against concurrent installs/updates, locked binaries, power loss, and partial replacement.
- Evaluate whether a launcher, side-by-side version directories, external helper, or a narrow scheduled replacement mechanism is justified. Reject needless complexity.
- Integrate into existing Rust update and trust paths without bypassing integrity checks or duplicating unrelated release machinery.
- Treat new privileged background services, broad system PATH changes, and executable replacement outside installer-managed locations as out of scope.

**Quality bar**
- Deterministic tests, fault injection, integration tests on a real Windows runner, and clear reproduction instructions.
- Performance and complexity should be proportional to the problem; "production-quality" means proof of reliability, not maximum lines changed.

## 7. Acceptance criteria before code is called ready

At minimum:
- Baseline documented from actual Windows observation, separate from source-code analysis.
- Fresh install and explicit-version install yield a verified runnable executable.
- Corrupt download, wrong hash, missing/duplicate matching checksum, malicious archive entries, failed downloads, unsupported platform, and failed extraction are rejected **without changing an existing installation**.
- Reinstallation is safe; failed upgrade preserves the prior version; locked-executable behavior is deterministic and documented.
- PATH modification, if offered, is optional/explicit and idempotent.
- Temp-file cleanup behavior demonstrated; any recovery artifacts documented.
- Offline fixtures cover negative cases; one official published release tested end-to-end.
- Windows PowerShell 5.1 and PowerShell 7 behavior verified on Windows, not merely syntax-reviewed elsewhere.
- If self-update is added, native CLI update tests demonstrate clean rollback/failure recovery and appropriate authorization/trust boundaries.
- CI passes, tests and commands have recorded output, relevant Proofline findings are dispositioned with reasons.
- Final PR is limited to high-value upstream files and contains test evidence; narrated demo <= 2 minutes.

## 8. Branch and commit policy (agreed workflow)

**Aim: a small number of meaningful commits, each representing an independently understandable, validated engineering milestone.** Avoid a commit for every line or cosmetic fix, but avoid a single giant unreadable change. Suggested conceptual milestones: research/context; installer core; safety and failure-path tests; self-update (if justified); CI/docs integration. The number is not a target; logical units matter.

1. Make changes in the dedicated fork branch only, never on upstream `main`.
2. Before starting a milestone, record a known-good commit SHA; build and run available checks locally.
3. Prefer committing once the milestone meets its tests. For iterative changes that fail **before committing**, correct them in the working tree or restore that working tree to the known-good commit while preserving failure logs.
4. If a new commit is **local and not pushed**, it can be amended/squashed or reset deliberately to keep the series tidy (first preserve any useful changes and evidence).
5. If a commit is **already pushed**, do **not** automatically erase history or force-push on every failing test. Make a focused correction commit; later, with explicit coordination and no shared consumers, optional interactive rebase/squash on the contributor's fork with `--force-with-lease` can polish the PR. Where history must be preserved, use `git revert` (which creates a new revert commit); do not pretend a revert makes the previous commit disappear.
6. Keep failing test evidence, reasons, and design decisions in internal progress notes, even when commits are later consolidated.
7. Do not remove or rewrite a known-good public commit just because a subsequent change failed; protect recoverability and transparency.
8. Never label tests "passed" without evidence of a real run. A passing Linux syntax check is not proof of Windows behavior.
9. Do not open the upstream PR until the relevant implementation and verification evidence are ready.
10. For the final upstream PR, remove temporary planning documents or extract lasting value into appropriate maintainer/user docs; never delete required reproducibility instructions or security rationale.

This is a **clean-history, evidence-preserving** process, not "revert every red test automatically." Intermediate CI failures are normal engineering feedback, and a reasonable number of focused corrective commits is acceptable.

## 9. Internal documentation plan

Keep temporary notes under `docs/windows-install-update/` on the fork branch:
- `context.md` — this canonical context and operating agreement.
- `research.md` — verified findings, source links, experiment outputs.
- `requirements.md` — precise problem statement, decisions and non-goals.
- `architecture.md` — installer/update state machine and design trade-offs.
- `security.md` — trust boundaries, threat model, invariants.
- `test-plan.md` — reproducible test matrix and results.
- `progress.md` — milestones, known-good SHAs, failures, decisions.

Create each file when research warrants it, rather than prepopulating empty placeholders. The earlier local installer prototype and test scripts are **not in this fork branch yet** and have **not** passed Windows validation. They are reference material, not accepted implementation.

## 10. First research questions / next steps

1. What are the exact steps a clean Windows x64 user must follow today, and what observations demonstrate the problem?
2. Which officially published artifact, checksum manifest, stable release selector, and URLs can be used safely? How do redirects behave?
3. How does PowerShell 5.1 differ from 7 for TLS, archives, process invocation, and persistent PATH?
4. Which Win32 file replacement semantics apply to a running `proofline.exe`, and what minimal update state machine guarantees recoverability?
5. How do upstream provenance verification proposals #72/#73 affect a new installer/update design?
6. Can negative cases run against local fixtures without distributing or executing untrusted payloads?
7. What is the smallest solution that meets the founder's reproducibility and review bar while still demonstrating deep engineering?

**Work order:** research and reproduce -> articulate acceptance contract -> select design -> implement in milestones -> run Windows tests and Proofline review -> document finding dispositions -> submit PR/video/application.

## 11. Primary references

Repository:
- https://github.com/prooflinedev/cli
- https://github.com/prooflinedev/cli/blob/main/README.md
- https://github.com/prooflinedev/cli/blob/main/install.sh
- https://github.com/prooflinedev/cli/blob/main/src/update.rs
- https://github.com/prooflinedev/cli/blob/main/scripts/archive.py
- https://github.com/prooflinedev/cli/blob/main/.github/workflows/ci.yml
- https://github.com/prooflinedev/cli/blob/main/.github/workflows/release.yml
- https://github.com/prooflinedev/cli/pull/72
- https://github.com/prooflinedev/cli/pull/73

Platform documentation:
- Rust Windows MSVC targets: https://doc.rust-lang.org/rustc/platform-support/windows-msvc.html
- PowerShell execution policies: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies
- PowerShell environment variables: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_environment_variables
- Windows moving/replacing files: https://learn.microsoft.com/en-us/windows/win32/fileio/moving-and-replacing-files
- Windows pending file operations: https://learn.microsoft.com/en-us/sysinternals/downloads/pendmoves

> **Status at writing:** Context documentation only. No new installer/update implementation committed in this branch, no Windows test execution claimed, and no upstream PR opened.
