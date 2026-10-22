# AgentScope — notes for Claude Code

Native macOS menu bar app + CLI that visualizes running AI coding agents (Claude Code, Codex CLI, Copilot CLI) as a live graph.

- **Spec:** `SPEC.md` — source of truth for scope, architecture, milestones. M0–M5 are done; don't start Phase 2 items (Allow/Deny, Timeline/Usage tabs, widget) unless asked. §10.1 records what was verified about each agent's hooks.
- **Design:** `design/*.html` — open in a browser and match layout, spacing, colors and states. Port to SwiftUI; do not embed web views.

## Stack & conventions
- Swift 6, SwiftUI, macOS 14+, SwiftPM. Targets: `AgentScopeKit` (library), `AgentScope` (app), `agentscope` (CLI, swift-argument-parser).
- `@Observable` for state; no Combine unless needed. No third-party UI libs. Allowed deps: swift-argument-parser, GRDB (optional), Sparkle (later).
- Business logic lives in `AgentScopeKit` and is unit-tested; app/CLI stay thin.
- Agent payload formats change often: save real payload samples to `Tests/Fixtures/<agent>/<version>/` and test normalizers against them. Never guess field names — capture a real payload first (`agentscope hook` debug mode writes raw input to a file).

## Hard rules
- `agentscope hook` must always exit 0, print nothing (except the opt-in permission flow), and finish in < 100 ms even if the app isn't running.
- `setup`/`uninstall` merge non-destructively into users' agent configs, back up originals, and are idempotent.
- No network calls. No storing prompt text unless the debug setting is on.

## Commands
- Build/test: `swift build`, `swift test` (SwiftPM only, no Xcode project). CI: `.github/workflows/ci.yml`.
- Release: `scripts/release.sh` (universal; signs + notarizes when `DEVELOPER_ID` / `NOTARY_PROFILE` are set, updates `Casks/agentscope.rb`). App icon: `swift scripts/make-icon.swift`.
- `agentscope doctor` checks app, hooks, Codex trust and hook speed on a real machine.
- App bundle: `scripts/build-app.sh [debug|release] [--universal]` → `build/AgentScope.app` (CLI at `Contents/Helpers/agentscope`).
- Visual check without clicking the menu bar (debug builds): `AGENTSCOPE_SNAPSHOT=<dir> $(swift build --show-bin-path)/AgentScopeApp` writes light/dark PNGs of the popover and other views, then quits.
- End-to-end: `scripts/integration-test.sh` (fixtures → real `agentscope hook` → spool/socket → app → `agentscope status`; isolated `AGENTSCOPE_HOME`).
- Capturing fixtures: `touch "$AGENTSCOPE_HOME/keep-raw-payloads"` makes `agentscope hook` save raw stdin under `$AGENTSCOPE_HOME/payloads/<agent>/`; point a throwaway agent run at the hook (Claude: `claude -p --setting-sources project --settings <file>` with the hooks block, prompt on stdin), then `scripts/import-fixtures.py <payload-dir> <agent> <version> <run-cwd>` scrubs paths into `Tests/Fixtures/`.
- `AGENTSCOPE_HOME=<dir>` relocates socket/spool/state (keep it short: the socket path must fit in 104 bytes). `AGENTSCOPE_MOCK=1` shows the design's mock data in the popover.
- The app's SwiftPM target is `AgentScopeApp` and the CLI's sources live in `Sources/AgentScopeCLI`: `AgentScope` vs `agentscope` collide on case-insensitive APFS.
