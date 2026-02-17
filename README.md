# claude-sessions

A zero-dependency bash tool to search, browse, and resume Claude Code sessions - beyond the built-in limits.

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Platform: Linux & macOS](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS-lightgrey.svg)
![Shell: Bash](https://img.shields.io/badge/Shell-Bash-green.svg)

## The Problem

Claude Code stores every conversation as a `.jsonl` file on disk. With heavy use, you accumulate hundreds of sessions. But the built-in UI only shows a fraction of them.

Here are the numbers from my setup (after ~3 months of daily use):

| Layer | What you see | Configurable? |
|-------|-------------|---------------|
| `.jsonl` files on disk | **282+ sessions** | Yes (`cleanupPeriodDays`) |
| `sessions-index.json` | ~82 entries | No |
| VS Code "Past Conversations" dropdown | **~50 sessions** (fixed slot cap) | No |
| CLI `/resume` interactive picker | **10 sessions** (hardcoded) | No |

Your numbers will vary, but the limits are the same for everyone. You may have months of valuable conversations saved on disk, but no way to find or access them through the UI.

## What I Found

After reverse-engineering Claude Code's session handling (CLI v2.1.x) and running empirical tests, here are the findings:

### 1. CLI `/resume` is hardcoded to 10 sessions

In the bundled source code (`cli.js`), the session listing function is called with a literal `10`:

```javascript
// Hardcoded limit - no setting to override it
return ZT6 = TT6(10).then((q) => {
  return sd1 = q.filter((K) => {
    if (K.isSidechain) return false;
    if (K.sessionId === A) return false;
    if (K.summary?.includes("I apologize")) return false;
    // ...additional filters reduce the list further
```

Even with hundreds of sessions on disk, the CLI picker will never show more than 10.

### 2. VS Code dropdown has a fixed slot cap

The VS Code "Past Conversations" dropdown displays a fixed number of sessions. When you "refresh" an old session (by opening it via CLI), it appears in the dropdown, but **the previously oldest visible session disappears**. It behaves like a fixed-size queue - new or refreshed sessions push out the oldest ones.

### 3. `cleanupPeriodDays` only controls file deletion

```javascript
var yDz = 30; // default: 30 days
// Only used for file deletion at startup
((settings.cleanupPeriodDays ?? 30) * 24 * 60 * 60 * 1000)
```

Setting `cleanupPeriodDays: 999` in `~/.claude/settings.json` preserves session files for ~2.7 years instead of the default 30 days. But nothing else in the system respects this value - the index cap and UI limits are completely independent.

### 4. `/compact` overwrites `firstPrompt` in the index (not the VS Code title)

Claude Code's index (`sessions-index.json`) stores a `firstPrompt` field for each session. After running `/compact`, this field gets **overwritten with a mid-conversation message** (the first message after the compaction boundary) instead of your original first words.

**Important**: this does NOT affect the VS Code dropdown title. VS Code reads the title directly from the `.jsonl` file (the actual first `user` message), so it always displays correctly. The issue only affects tools that rely on the index's `firstPrompt` field - which is why this tool extracts the real title from the `.jsonl` file instead.

### 5. `/resume SESSION_ID` does NOT work in VS Code

Typing `/resume SESSION_ID` in the VS Code chat prompt does **not** resume by ID. It either opens the limited dropdown picker or sends the text as a regular message. The only way to resume an arbitrary session is via CLI:

```bash
claude --resume <full-session-id>
```

### 6. CLI resume "refreshes" sessions into VS Code dropdown

Running `claude --resume SESSION_ID` in a terminal:
1. Opens the session successfully (regardless of age)
2. Updates the file's modification time
3. Causes the session to appear in VS Code's dropdown on next refresh
4. But **pushes out the oldest visible session** from the dropdown (fixed slot behavior)

This is the key workaround - but you need to know the session ID first.

## Recommended Settings

Add this to `~/.claude/settings.json` to prevent Claude Code from deleting old session files:

```json
{
  "cleanupPeriodDays": 999
}
```

The default is 30 days. With `999`, your session files are preserved for ~2.7 years (999 is not infinite - it's 999 days). This is a prerequisite for this tool to be useful - you can't search sessions that have been deleted.

### Tip: name your conversations with descriptive first words

Claude Code uses your first message as the conversation title (shown in VS Code's dropdown and in this tool's output). Writing a short descriptive header as your opening line makes sessions much easier to find later:

```
Grafana. Issue: dashboards not loading after upgrade.
I need help debugging...
```

```
Project X. Add authentication middleware.
I want to implement JWT-based auth for...
```

This way, both the VS Code dropdown and `claude-sessions search` will show meaningful titles instead of generic text like "Help me fix this bug".

## The Tool

`claude-sessions` is a single bash script (+ inline Python3) that reads session files directly from disk. No compilation, no package manager, no dependencies beyond what's already on your system.

### What it does

- **Lists all indexed sessions** with your real first message as the title (not the auto-generated summary)
- **Searches** by keyword across titles, summaries, and prompts
- **Grep** searches inside the actual conversation content (slower, but finds everything)
- **Reads** full conversations in a clean paged format
- **Resumes** any session via `claude --resume`, making it appear in VS Code's dropdown
- **Shows metadata** including creation date, message count, file size, git branch

### Installation

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/claude-sessions.git

# Make executable (if not already)
chmod +x claude-sessions/claude-sessions.sh

# Option A: symlink to a directory in your PATH
ln -s "$(pwd)/claude-sessions/claude-sessions.sh" ~/.local/bin/claude-sessions

# Option B: create a short alias (add to your shell config)
# Linux (~/.bashrc):
echo "alias cs='$(pwd)/claude-sessions/claude-sessions.sh'" >> ~/.bashrc && source ~/.bashrc

# macOS (~/.zshrc):
echo "alias cs='$(pwd)/claude-sessions/claude-sessions.sh'" >> ~/.zshrc && source ~/.zshrc
```

After this you can use `cs` instead of the full path:

```bash
cs search grafana
cs read 27e941e2
```

### Requirements

- **bash** (pre-installed on Linux and macOS)
- **python3** (pre-installed on macOS and most Linux distros)
- **Claude Code** (the CLI tool must be installed for `resume` to work)

### Usage

Run the script from your project directory (or any subdirectory). It automatically finds the right `sessions-index.json` for your project context.

```bash
# List all sessions (newest first)
claude-sessions

# Search by keyword (searches titles, summaries, and index metadata)
claude-sessions search vault

# Search inside actual conversation content (slower, covers ALL files on disk)
claude-sessions grep "terraform apply"

# Show detailed info for a session
claude-sessions info 27e941e2

# Read a conversation (paged with less)
claude-sessions read 27e941e2

# Resume a session in Claude CLI (also makes it appear in VS Code dropdown)
claude-sessions resume 27e941e2
```

### Example Output

```
$ claude-sessions search grafana
Search: 'grafana' - 3 results (of 82 indexed)

Date          Msgs ID         Title                                    Summary
--------------------------------------------------------------------------------------------------------------
2026-01-09      32 4fef7d93   Deploy monitoring stack for project      Monitoring Deployment: Vault, Graf
2025-12-22       6 61349b6d   Issue: Grafana prd not healthy           Grafana PRD fix verification
2025-11-19      66 4a26ca65   Setup argocd and monitoring pipeline     ArgoCD deployment troubleshooting
```

The **Title** column shows your real first message. The **Summary** column shows Claude's auto-generated summary. Both are searchable.

## How It Works

1. **Project detection**: The script encodes your current working directory path (replacing `/` with `-`) to find the right project folder under `~/.claude/projects/`.

2. **Title extraction**: For each session, it reads the `.jsonl` file and extracts the first `user` type message, skipping IDE system tags (content starting with `<`). This is your real conversation opener - the one VS Code shows in its dropdown.

3. **Search**: `search` queries the sessions index (fast). `grep` uses system `grep -rl` on all `.jsonl` files (slower but covers sessions not in the index).

4. **Resume**: Runs `claude --resume <full-uuid>` which opens the conversation in Claude CLI. As a side effect, this updates the file's modification time, causing VS Code to include it in the "Past Conversations" dropdown.

## Alternatives

There are more feature-rich tools if you need a GUI, fuzzy search, or advanced capabilities:

| Tool | Language | Install | Key Feature | Open Source |
|------|----------|---------|-------------|-------------|
| **claude-sessions** (this) | Bash | Copy script | Zero-dep, real title extraction | Yes (MIT) |
| [claude-history](https://github.com/raine/claude-history) | Rust | `brew install` / `cargo install` | Fuzzy TUI, markdown rendering, vim keys | Yes (MIT) |
| [claude-run](https://github.com/kamranahmedse/claude-run) | TypeScript | `npx claude-run` | Web UI with real-time streaming | Yes (MIT) |
| [cc-conversation-search](https://github.com/akatz-ai/cc-conversation-search) | Python | `uv tool install` | SQLite FTS, date filtering, Claude Skill | Yes (MIT) |
| [claude-session-browser](https://github.com/davidpp/claude-session-browser) | Go | Binary download | TUI with ripgrep search | Yes (MIT) |
| [Claude Code History](https://marketplace.visualstudio.com/items?itemName=agsoft.claude-history-viewer) | Closed-source | VS Code marketplace | Rich sidebar, diff viewer, analytics | No |

**Why this tool?**
- Zero dependencies (no Rust/Go/Node/Python packages to install)
- Extracts your real conversation title (not the auto-summary)
- Single file - easy to audit, fork, or modify
- Works on any Linux or macOS system out of the box

## Related Issues

- [#13064](https://github.com/anthropics/claude-code/issues/13064) - Session history retention and access beyond UI limits
- [#24435](https://github.com/anthropics/claude-code/issues/24435) - Resume picker hardcoded to 10 sessions (confirmed bug)
- [#12872](https://github.com/anthropics/claude-code/issues/12872) - Session management improvements request

## Session File Structure

For anyone building their own tools, here's what I learned about the session file format:

```
~/.claude/projects/<encoded-path>/
├── sessions-index.json              # Index with metadata (~82 entries max)
├── <uuid>.jsonl                     # Session files (one per conversation)
├── agent-<uuid>.jsonl               # Agent sidechain files (filtered out by this tool)
└── ...
```

Each `.jsonl` file contains one JSON object per line with these `type` values:
- `queue-operation` - Internal queue events
- `file-history-snapshot` - File state tracking
- `user` / `human` - User messages (content may be string or array with `{type: "text", text: "..."}`)
- `assistant` - Claude's responses
- `summary` - Compaction summaries (created by `/compact`)

The `sessions-index.json` has entries with: `sessionId`, `fullPath`, `fileMtime`, `firstPrompt`, `summary`, `messageCount`, `created`, `modified`, `gitBranch`, `projectPath`, `isSidechain`.

## License

MIT - see [LICENSE](LICENSE).
