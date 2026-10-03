# AGENTS.md — project instructions

Repository: `Kryptas531/IPAD_BLUETOOTH_MIRACLE`. An iPad controls Windows through
BLE HID; direct Wi-Fi TV control is specified in `SPEC.md` §7.3 and is not implemented.

## Canon and read order
- Read this file, `SPEC.md`, the active task, then directly relevant code and Git state.
- `SPEC.md` is the single product/technical specification, versioned by Git SHA.
  Current Git and the spec beat old summaries. Git history is the archive; do not create
  parallel roadmap, architecture or layout specifications.
- Runtime-specific material (`QWEN.md`, `.qwen/`, `.pi/`) is not the default instruction
  chain. Consult it only for an explicitly requested runtime workflow; it does not
  override the active task or define repository-wide agent roles or merge authorization.

## Change boundaries
- Change behavior, architecture, UX, acceptance or scope in a separate `spec(...)`
  commit before implementation; implementation commits/PRs reference that spec SHA.
  Pure fixes restoring specified behavior do not require a new spec commit.
- Preserve Windows pairing, BLE/HOGP reports, keyboard, mouse, Direct Input, GAME/RACING,
  CONTROL and the optional foreground helper. TV input must remain separate (§7.3).
- Protected: `BTRemote/LowEnergy/`, `BTRemote/Classic/`, `BTRemote/HIDInput.swift`,
  `BTRemote/HIDReports.swift`, Bluetooth resource JSONs, `BTRemote/Info.plist` and
  `BTRemote/entitlements.plist`. Changes require a concrete technical reason, the exact
  SPEC authorization and focused review; TV scope is not a blanket BLE/signing exception.
- Keep PARKED/non-goals in §11 parked. Reuse working code; no unrelated fixes, style
  rewrites, or new dependencies without a concrete need and compatible licensing.
- Preserve upstream attribution to `jqssun/darwin-bt-remote`, AGPL-3.0-only and `LICENSE`.

## Build and verification
- XcodeGen generates the uncommitted Xcode project from `project.yml` (Swift 6,
  strict concurrency, iOS 15 minimum). `ci_scripts/ci_post_clone.sh` installs XcodeGen,
  downloads the two missing Nordic Bluetooth JSON resources and generates the project.
- iPad delivery uses `.github/workflows/unsigned.yml`: macOS runner → dependency-free
  Swift checks → unsigned iPhoneOS Release build (`CODE_SIGNING_ALLOWED=NO`) →
  `btr-remote-unsigned-ipa` containing `BTRemote.ipa`. Install via SideStore/Sideloadly,
  re-signed with a free Apple ID. Preserve this path.
- That workflow runs on `main` pushes or `workflow_dispatch`; a feature-branch push
  alone does not trigger it. When CI is required, verify the actual tested commit.
- On macOS, `build.sh` supplies the existing lint/build/package commands; the workflow
  supplies the dependency-free `swiftc` test invocation. Windows has no Xcode build.
  For companion changes use `dotnet build companion/WindowsForeground/WindowsForeground.csproj -c Release`
  and `dotnet run --project companion/WindowsForeground.Tests/WindowsForeground.Tests.csproj -c Release`
  (see `companion/README.md`).
- Documentation-only edits: inspect the full diff and cross-section consistency;
  do not rebuild an unchanged application. CI proves compilation/tests, not hardware
  behavior. Physical acceptance remains in §9 and §7.3; TV wake is unconfirmed until tested.

## Git delivery
- Fetch/preflight before delivery; verify the worktree, branch, base and local/remote
  `main` relationship. Stop on divergent `main`; do not overwrite unrelated work.
  Use a feature branch based on verified `origin/main`, or the task's verified current
  worktree/branch. Never push feature changes directly to `main`.
- Keep small commits. Review the committed exact HEAD independently; verify relevant
  checks and hardware gates before delivery. Push/PR require task authorization;
  merge requires a separate explicit owner request. After merge, update `main` by
  fast-forward only. No force-push or published-history rewriting.
- Commit/PR title: `type(scope): concrete outcome`; types: `spec`, `feat`, `fix`, `test`,
  `docs`, `refactor`, `chore`, `ci`. PR body: `SPEC`, `BASE`, `GOAL`, `CHANGED`, `VERIFIED`,
  `PHYSICAL TEST`, `RISKS`, with concise factual values.
- Do not commit credentials, downloaded IPA/ZIPs, SideStore data, `rawprobe/`,
  `.qwen/tmp/`, build output or unrelated scratch; preserve unknown local files.
