# AgentScope — Product & Technical Spec (v0.1)

Native macOS menu bar app + CLI that shows **every AI coding agent running on this Mac** (Claude Code, Codex CLI, GitHub Copilot CLI) as a live graph: sessions → subagents → tool calls, with status (working / needs you / failed / idle), context usage and estimated cost.

Inspiration: the "Agent graph" UI (orchestrator → agents → tools, colored edges) and CodexBar (menu bar app + bundled CLI, installed via `brew install --cask`).

Mockups: `design/main-window.html`, `design/menubar-popover.html`, `design/install-cli.html` (open in a browser; they are the visual source of truth).

---

## 1. Goals

1. One glance: which agents are running, what each is doing right now, which one is waiting for me.
2. Graph view of the agent tree per session (main agent → subagents → tool calls), animated in real time.
3. Install with one terminal command, set up all agents with one more (`agentscope setup`).
4. 100% local. No network calls except optional update checks. No prompts/code leave the machine.

### Non-goals (v1)
- Controlling agents beyond permission Allow/Deny (no sending prompts, no starting sessions).
- Cloud agents (Copilot cloud agent, Codex cloud, Claude on the web).
- Copilot inside VS Code chat (only Copilot **CLI** in v1 — see Open questions).
- Windows / Linux app (CLI may build on Linux later).

---

## 2. Users & key scenarios

- **S1 — Glance:** several agents run in different terminals; the menu bar icon shows the active count and an orange dot when one needs input.
- **S2 — Needs you:** an agent hits a permission prompt → macOS notification + banner in popover with **Allow / Deny / Jump to** (Jump to = focus the terminal/IDE window).
- **S3 — Understand:** open the main window → graph shows session → subagents → current tool calls with animated edges; activity feed underneath.
- **S4 — Failure:** a tool call fails → red edge + red row in feed; popover row turns red.
- **S5 — Spend:** today's tool calls, tokens, estimated cost per agent.

---

## 3. Architecture

```
┌──────────────┐  hook (stdin JSON)  ┌──────────────────────┐
│ Claude Code  │ ───────────────────▶│                      │
│ Codex CLI    │ ──▶ agentscope hook │  Unix domain socket  │──▶ AgentScope.app
│ Copilot CLI  │ ───────────────────▶│  (NDJSON events)     │    (EventStore → UI)
└──────────────┘                     └──────────────────────┘
        │ JSONL transcripts on disk (FSEvents tail) ──────────────▶ fallback / enrichment
```

### 3.1 Components (one Xcode project / SwiftPM workspace)

| Target | Type | Responsibility |
|---|---|---|
| `AgentScopeKit` | Swift package (library) | Event model, normalizers per agent, `EventStore`, socket client/server, config writers, price table |
| `AgentScope` | macOS app (SwiftUI) | `MenuBarExtra` popover, main window with graph, notifications, settings |
| `agentscope` | CLI (Swift, swift-argument-parser) | `setup`, `uninstall`, `status`, `hook`, `doctor`; bundled inside the .app and symlinked by the cask |

Requirements: macOS 14+, Swift 6, SwiftUI, Apple Silicon + Intel (universal). No Electron, no web views.

### 3.2 Ingest path A — hooks (primary)

Each agent is configured to run `agentscope hook --agent <claude|codex|copilot> --event <name>` on lifecycle events.

`agentscope hook` contract:
- Reads the hook JSON payload from **stdin**.
- Adds `agent`, `event`, `ts`, `pid`, `ppid`, `cwd`, `tty` (if any), then writes one NDJSON line to the app's socket `~/Library/Application Support/AgentScope/agentscope.sock`.
- **Must never break or slow the agent:** connect timeout 50 ms; if the app is not running → append to `~/Library/Application Support/AgentScope/spool.ndjson` and exit 0. Total budget < 100 ms. Always exit 0 and print nothing to stdout (exception: permission flow, §3.5).

Hook config locations (verified against docs/issues, re-check before implementing):

| Agent | Config file written by `setup` | Notes |
|---|---|---|
| Claude Code | `~/.claude/settings.json` → `hooks` | Events incl. `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Notification`, `SubagentStart`, `SubagentStop`, `Stop`, `SessionEnd`. Docs: https://code.claude.com/docs/en/hooks |
| Codex CLI | `~/.codex/hooks.json` | Smaller event set close to Claude's (`PreToolUse`, …). User must trust hooks once via `/hooks` in Codex — `setup` prints this. |
| Copilot CLI | `~/.copilot/hooks/agentscope.json` | Format `{"version":1,"hooks":{"preToolUse":[{"type":"command","bash":"…","timeoutSec":10}]}}`. Events incl. `preToolUse`, `postToolUse`, `notification`. Known issue: repo-level hooks not loaded in `-p` mode; user-level ones are. Docs: https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-hooks-reference |

`setup` rules: detect which agents are installed; merge into existing config (never overwrite user hooks); back up the original as `*.agentscope-backup-<date>`; idempotent (marker `"_agentscope": true` or matching command string); `uninstall` removes only our entries.

### 3.3 Ingest path B — transcripts (fallback + enrichment)

Tail with FSEvents + file offsets:
- Claude Code: `~/.claude/projects/**/*.jsonl`
- Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`

Used for: sessions started before setup, token usage / model names, context %, recovering after the app was closed. Copilot CLI: hooks only in v1 (logs in `~/.copilot/logs` are process logs, not a stable format).

Session is **alive** if its process exists (match by pid from hooks, or by `cwd` + process name via `libproc`/`sysctl`) and had activity in the last N minutes; otherwise **idle**; removed from active list after 30 min idle (configurable).

### 3.4 Normalized event model (`AgentScopeKit`)

```swift
enum AgentKind: String, Codable { case claude, codex, copilot }
enum NodeStatus: String, Codable { case working, needsYou, answered, failed, idle }

struct Session: Identifiable { id: String; agent: AgentKind; project: String /* cwd basename */;
    cwd: URL; pid: Int32?; model: String?; startedAt: Date; lastEventAt: Date;
    status: NodeStatus; contextUsed: Double? /* 0…1 */; tokens: Int; costUSD: Double? }

struct AgentNode: Identifiable { id: String; sessionId: String; parentId: String?; // nil = main agent
    name: String /* "main", "Explore", "Plan"… */; model: String?; status: NodeStatus }

struct ToolCall: Identifiable { id: String; agentNodeId: String; tool: String /* Bash, Read, apply_patch, MCP name */;
    summary: String /* "npm test", "src/api.ts" — truncated 60 chars */; startedAt: Date;
    finishedAt: Date?; status: NodeStatus; error: String? }

struct AgentEvent: Codable { ts: Date; agent: AgentKind; sessionId: String; kind: EventKind; raw: Data }
```

One normalizer per agent maps raw hook payload → `AgentEvent`. Mapping table (fill exact field names while implementing, from real payload samples saved under `Fixtures/`):

| Normalized | Claude Code | Codex | Copilot CLI |
|---|---|---|---|
| sessionStarted | `SessionStart` | session start event / first rollout line | first event seen |
| toolStarted | `PreToolUse` | `PreToolUse` | `preToolUse` |
| toolFinished | `PostToolUse` | `PostToolUse` (if available) | `postToolUse` |
| toolFailed | `PostToolUseFailure` | error in rollout | (verify) |
| needsYou | `Notification` (permission/idle) | (verify) | `notification` (permission prompt) |
| subagentStarted/Stopped | `SubagentStart` / `SubagentStop` (`agent_id`, `agent_type`) | — | — |
| turnFinished | `Stop` | `Stop` | (verify) |
| sessionEnded | `SessionEnd` | process exit | process exit |

`EventStore`: `@Observable`, in-memory graph per session + ring buffer of last 500 events; persisted daily stats (tool calls, tokens, cost) in a small SQLite (GRDB) or JSON file. Raw prompts are **not** stored unless "Debug: keep raw payloads" is on.

### 3.5 Permission Allow/Deny (phase 2, behind a setting)

For `PreToolUse` (Claude) / `preToolUse` (Copilot) only:
`agentscope hook --decide` sends the event and waits (≤ timeout − 1 s) for the user's choice in the app, then prints the agent-specific decision JSON to stdout (Claude: hook decision output / exit 2 to block; Copilot: `{"permissionDecision":"allow"|"deny"}`). If the app doesn't answer → print nothing, exit 0 → the agent shows its normal prompt. Default OFF; only for tool categories the user selects (e.g. Bash). Codex: not supported until verified.

### 3.6 Cost estimation
Tokens from transcripts × editable price table (`prices.json`, per model, input/output/cache). Always labeled "est.". Copilot: show calls only (subscription, no per-token cost).

---

## 4. UI spec (see `design/`)

### 4.1 Menu bar (`MenuBarExtra`, window style)
- Icon: graph glyph + number of working sessions; orange dot when any `needsYou`; red dot when a failure in last 60 s.
- Popover (356 pt wide): header (live, calls/min) → **Needs you** banner(s) with Allow / Deny / Jump to → Active sessions list (agent badge, project, current action, context bar, elapsed) → idle sessions dimmed → 3 stat tiles (Tool calls, Tokens, Cost today) → `Open Agent Graph ⌘⇧A`, `Settings… ⌘,`, `Quit ⌘Q`.

### 4.2 Main window
- Toolbar segmented control: **Graph** | Timeline | Usage (v1: Graph only; others stub).
- Sidebar (260 pt): sessions list with status dots; Today stats card.
- Graph: root "This Mac" → session nodes → subagent nodes → tool-call chips. Layered top-down tree layout (own simple layout, no dependency). Draw with SwiftUI `Canvas` for edges + SwiftUI views for nodes. Animated dots moving along edges for in-flight calls (`TimelineView(.animation)`), pulse ring on `needsYou`, soft glow on the selected/active session. Pan & zoom, click node → inspector popover (payload summary, timestamps, error).
- Edge colors: Call `#2F6FEB`, Answer `#22A06B`, Needs you `#E8890C`, Failed `#D93F3F`, Idle `#D1D1D6`. Legend under graph.
- Activity feed (bottom, monospaced): `HH:mm:ss  agent  message`, newest on top.
- Agent badges: Claude `#D97757` "CC", Codex `#1D1D1F` "CX", Copilot `#7A4FD6` "CP" (no third-party logos in v1).
- Light + dark mode via semantic colors; respect Reduce Motion (disable flowing dots).

### 4.3 Notifications
`UNUserNotificationCenter` on `needsYou` (once per event) and on session finished (optional). Click → Jump to.

### 4.4 Jump to
Find terminal/IDE owning the agent process (walk `ppid` chain: Terminal, iTerm2, Ghostty, Warp, VS Code, Cursor, JetBrains) → activate app via `NSRunningApplication`; for Terminal/iTerm2 select tab via AppleScript (requires Automation permission, ask once).

### 4.5 Settings
Agents on/off, idle timeout, notifications, Allow/Deny (phase 2), price table, launch at login (`SMAppService`), "Keep raw payloads" (debug), Re-run setup.

---

## 5. CLI

```
agentscope setup [--agent claude|codex|copilot] [--dry-run]   # write hooks, show diff
agentscope uninstall [--agent …]                               # remove our hooks, restore nothing else
agentscope status [--json]                                     # same data as popover, table output
agentscope hook --agent <a> [--event <e>] [--decide]           # internal, called by agents
agentscope doctor                                              # checks: app running, socket, hooks present, Codex hooks trusted
```

---

## 6. Distribution

- Homebrew cask in own tap: `brew install --cask <owner>/tap/agentscope` (installs .app, symlinks `agentscope` CLI). Same model as CodexBar.
- Developer ID signing + notarization (needs Apple Developer Program). Without it: document `xattr -cr /Applications/AgentScope.app`.
- GitHub Releases: universal `.zip`/`.dmg`; optional Sparkle auto-update later.
- After install, first launch offers to run setup (same as CLI).

---

## 7. Milestones

- **M0 — Skeleton:** workspace with 3 targets, MenuBarExtra showing static mock data matching `design/menubar-popover.html`.
- **M1 — Ingest:** socket server, `agentscope hook`, spool, Claude Code normalizer + `setup` for Claude. Real sessions appear in popover.
- **M2 — Graph:** main window graph + feed + sidebar, matching `design/main-window.html`. Subagents from `SubagentStart/Stop`.
- **M3 — Codex + Copilot:** normalizers, setup, transcript tailer, fixtures + unit tests.
- **M4 — Polish:** notifications, Jump to, stats & cost, settings, dark mode, Reduce Motion.
- **M5 — Ship:** signing/notarization, cask, README, `doctor`.
- **Phase 2:** Allow/Deny, Timeline & Usage tabs, WidgetKit summary widget.

## 8. Acceptance criteria (v1)
- Fresh Mac: `brew install --cask …` + `agentscope setup` → starting `claude`, `codex`, `copilot` in three terminals shows three sessions within 1 s of first activity.
- Claude subagent run appears as child node and disappears/greys on `SubagentStop`.
- Permission prompt in any agent → orange state + notification within 1 s.
- Quitting the app never blocks or errors any agent (hook exits 0 in < 100 ms).
- `agentscope uninstall` leaves user's own hooks byte-identical.
- No outbound network traffic (verify with Little Snitch / `nettop`).
- Idle CPU < 1 %, RAM < 80 MB with 5 sessions.

## 9. Testing
- `AgentScopeKit` unit tests: normalizers against recorded payload fixtures per agent; config merge/unmerge (golden files); tree layout.
- Integration: script that pipes fixture events into `agentscope hook` and asserts the store state.
- Manual checklist per agent version (agents change hook schemas often — keep fixtures versioned).

## 10. Open questions (verify before/while implementing)
1. Exact Codex hook event names & payload fields, and whether `PostToolUse` / notification-type events exist in the installed version.
2. Full Copilot CLI event list (session start/end, failure) and payload fields.
3. Whether Copilot in **VS Code** exposes hooks to user-level config (out of scope v1).
4. Claude Code: best signal for "needs you" (`Notification` payload types vs `PermissionRequest`).
5. Name "AgentScope" — check for conflicts before publishing the cask.

### 10.1 Verified while implementing (Oct 2026, from captured payloads in `Tests/Fixtures/`)
- **All three agents send Claude-style hook payloads** (`session_id`, `hook_event_name`, `tool_name`, `tool_input`, `cwd`, `transcript_path`); one normalizer core handles them with per-agent options.
- **Claude Code 2.1.283:** `PermissionRequest` (with `tool_name`/`tool_input`) is the "needs you" signal (Q4); `Notification` only for `notification_type == "permission_prompt"`. Subagent tool calls carry `agent_id`/`agent_type`. `PostToolUseFailure` has `error` and `is_interrupt`. Async `Agent` calls return at once; the subagent's life is `SubagentStart`→`SubagentStop`.
- **Codex CLI 0.162:** hooks live in `~/.codex/hooks.json` (also `[[hooks.X]]` in config.toml), same layout as Claude's `hooks` block, no matcher needed. Events used: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest, SubagentStart/Stop, Stop, SessionEnd (timeout capped at 3 s). Payloads include `model` and `tool_use_id`; a failing shell command is a normal `PostToolUse`. **Untrusted hooks are skipped silently** until the user approves them in `/hooks`; trust is stored in config.toml as `hooks.state."<hooks.json>:<event>:<group>:<hook>".trusted_hash` (sha256 of the canonical group JSON). AgentScope only checks it (`doctor`), never writes it. Hooks run unsandboxed and without the parent's environment (Q1).
- **Copilot CLI 1.0.100:** supports both camelCase (`preToolUse`, payload `toolName`/`toolArgs`) and Claude-style PascalCase events; only PascalCase has `PostToolUseFailure` and `PermissionRequest`, so setup installs those. No `tool_use_id` → calls are paired by tool + input. `PermissionRequest` also fires for calls its rules then auto-approve, so "needs you" waits a 2 s grace period. User-level `~/.copilot/hooks/*.json` load in `-p` mode (Q2).
- **Transcripts:** Claude repeats a response's `usage` on every content block (dedupe by `message.id`) and writes `cost-state.totalCostUSD`, used instead of our estimate. Codex rollouts report running totals in `event_msg/token_count` plus `model_context_window`.
- **Allow/Deny decision format (Claude Code 2.1.283):** the PermissionRequest hook prints `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` (or `"deny"` with a `message`); verified end to end (`scripts/allow-deny-e2e.sh`). While the hook waits, Claude does not show its own prompt. Not offered for Copilot (it sends PermissionRequest even for calls its rules approve) or Codex.

## 11. After v1
Done: "Your turn" status and inbox order, Allow/Deny for Claude Code (opt-in), quick switcher (⌃⌥Space), stuck/loop detection, repo · branch identity, Timeline tab (turn recaps), guardrails (session/daily cost, context fill), Usage tab (7/30 days by agent/project/model, last 5 hours; from transcripts).
Not planned for now: same-file conflict warning, WidgetKit widget.
