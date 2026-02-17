#!/bin/bash
# claude-sessions - Search, browse, and resume Claude Code sessions
# beyond the built-in 10-session CLI limit and ~50-session VS Code dropdown.
#
# Requirements: bash, python3 (pre-installed on macOS and most Linux distros)
# Platforms:    Linux, macOS
#
# Usage:
#   claude-sessions                → list all indexed sessions (with real titles)
#   claude-sessions search TERM    → search by keyword in titles, summaries, prompts
#   claude-sessions grep TERM      → search in session file contents (slower, all files on disk)
#   claude-sessions info ID        → show session metadata and real title
#   claude-sessions read ID        → read conversation messages (paged with less)
#   claude-sessions resume ID      → resume session in Claude CLI terminal
#
# ID = first 8 characters of the session UUID.

VERSION="1.0.0"

PROJ_DIR="$HOME/.claude/projects"
INDEX_SUFFIX="sessions-index.json"

# --- Helpers ---

# Find the sessions-index.json for the current project context.
# Claude Code encodes the project path (replacing / with -) as the directory name.
find_index() {
    local cwd="${1:-$(pwd)}"
    local encoded index_file
    while [ "$cwd" != "/" ] && [ -n "$cwd" ]; do
        encoded=$(echo "$cwd" | sed 's|/|-|g')
        index_file="$PROJ_DIR/$encoded/$INDEX_SUFFIX"
        if [ -f "$index_file" ]; then
            echo "$index_file"
            return
        fi
        cwd=$(dirname "$cwd")
    done
    echo ""
}

get_proj_dir() {
    local index_file
    index_file=$(find_index)
    if [ -z "$index_file" ]; then
        echo ""
        return 1
    fi
    dirname "$index_file"
}

# --- Commands ---

# List or search sessions. Extracts the real first user message ("title")
# from .jsonl files, since the index's firstPrompt field gets overwritten
# after /compact.
list_sessions() {
    local index_file
    index_file=$(find_index)
    if [ -z "$index_file" ]; then
        echo "No sessions-index.json found for current directory."
        echo "Run this from your project directory (or any subdirectory)."
        return 1
    fi

    local search_term="${1:-}"
    local proj_dir
    proj_dir=$(dirname "$index_file")

    python3 - "$index_file" "$search_term" "$proj_dir" <<'PYEOF'
import json, sys, os

index_file = sys.argv[1]
search = sys.argv[2].lower() if len(sys.argv) > 2 and sys.argv[2] else ""
proj_dir = sys.argv[3] if len(sys.argv) > 3 else os.path.dirname(index_file)


def extract_title(filepath):
    """Extract the real first user text from a .jsonl session file.

    Claude Code stores conversations as JSONL. The first 'user' type message
    contains the user's actual first words. We skip system/IDE tags (content
    starting with '<') to get the real text.

    This is needed because the index's 'firstPrompt' field gets overwritten
    after /compact with a mid-conversation message.
    """
    try:
        with open(filepath) as fh:
            for line in fh:
                try:
                    msg = json.loads(line)
                    if msg.get("type") not in ("human", "user"):
                        continue
                    content = msg.get("message", {}).get("content", "")
                    if isinstance(content, list):
                        for c in content:
                            if isinstance(c, dict) and c.get("type") == "text":
                                text = c.get("text", "").strip()
                                if text and not text.startswith("<"):
                                    return text
                    elif isinstance(content, str):
                        text = content.strip()
                        if text and not text.startswith("<") and text != "[Request interrupted by user]":
                            return text
                except (json.JSONDecodeError, KeyError):
                    continue
    except Exception:
        pass
    return ""


with open(index_file) as f:
    data = json.load(f)

entries = sorted(data["entries"], key=lambda x: x.get("created", ""), reverse=True)
total = len(entries)
matches = []

for e in entries:
    filepath = e.get("fullPath", os.path.join(proj_dir, e["sessionId"] + ".jsonl"))
    title = extract_title(filepath) if os.path.exists(filepath) else ""
    e["_title"] = title

    if search:
        searchable = (title + " " + json.dumps(e)).lower()
        if search not in searchable:
            continue
    matches.append(e)

if search:
    print(f"Search: '{sys.argv[2]}' — {len(matches)} results (of {total} indexed)")
else:
    print(f"Sessions: {total} indexed")

print()
# Header
print("%-12s %5s %-10s %-40s %s" % ("Date", "Msgs", "ID", "Title", "Summary"))
print("-" * 110)

for e in matches:
    created = e.get("created", "")[:10]
    msgs = e.get("messageCount", 0)
    sid = e["sessionId"][:8]

    title = e.get("_title", "")
    summary = e.get("summary", "")

    if title:
        # First line of user's real first message, truncated
        title_display = title.split("\n")[0][:38]
    else:
        title_display = "(no title)"

    summary_display = summary[:35] if summary else ""

    print("%-12s %5d %-10s %-40s %s" % (created, msgs, sid, title_display, summary_display))

if not matches and search:
    print("(no results — try 'claude-sessions grep %s' to search all files on disk)" % sys.argv[2])
PYEOF
}

# Search inside .jsonl file contents. Slower but covers ALL sessions on disk,
# including those not in the index.
grep_sessions() {
    local term="$1"
    if [ -z "$term" ]; then
        echo "Usage: claude-sessions grep TERM"
        return 1
    fi
    local index_file
    index_file=$(find_index)
    if [ -z "$index_file" ]; then
        echo "No sessions-index.json found."
        return 1
    fi
    local proj_dir
    proj_dir=$(dirname "$index_file")

    local match_files
    match_files=$(grep -rl "$term" "$proj_dir"/*.jsonl 2>/dev/null | grep -v agent-)

    if [ -z "$match_files" ]; then
        echo "No sessions contain '$term'"
        return
    fi

    local count
    count=$(echo "$match_files" | wc -l)

    # Write file list to temp file (can't use pipe + heredoc simultaneously)
    local tmpfile
    tmpfile=$(mktemp)
    echo "$match_files" > "$tmpfile"

    python3 - "$index_file" "$count" "$term" "$tmpfile" <<'PYEOF'
import json, sys, os

index_file = sys.argv[1]
count = sys.argv[2]
term = sys.argv[3]
filelist_path = sys.argv[4]

with open(filelist_path) as fl:
    files = [line.strip() for line in fl if line.strip()]

try:
    with open(index_file) as f:
        data = json.load(f)
    index_map = {e["sessionId"]: e for e in data["entries"]}
except Exception:
    index_map = {}


def extract_title(filepath):
    try:
        with open(filepath) as fh:
            for line in fh:
                try:
                    msg = json.loads(line)
                    if msg.get("type") not in ("human", "user"):
                        continue
                    content = msg.get("message", {}).get("content", "")
                    if isinstance(content, list):
                        for c in content:
                            if isinstance(c, dict) and c.get("type") == "text":
                                text = c.get("text", "").strip()
                                if text and not text.startswith("<"):
                                    return text
                    elif isinstance(content, str):
                        text = content.strip()
                        if text and not text.startswith("<") and text != "[Request interrupted by user]":
                            return text
                except (json.JSONDecodeError, KeyError):
                    continue
    except Exception:
        pass
    return ""


print(f"Grep: '{term}' — {count} sessions match")
print()
print("%-12s %-10s %-40s %s" % ("Date", "ID", "Title", "Summary"))
print("-" * 100)

results = []
for filepath in files:
    sid = os.path.basename(filepath).replace(".jsonl", "")
    short_id = sid[:8]
    entry = index_map.get(sid, {})
    created = entry.get("created", "")[:10] if entry else ""
    summary = entry.get("summary", "")

    title = extract_title(filepath)
    if not title:
        title = "(no title)"

    results.append((created, short_id, title, summary))

results.sort(key=lambda x: x[0], reverse=True)

for created, short_id, title, summary in results:
    date_str = created if created else "(no date)"
    title_display = title.split("\n")[0][:38]
    summary_display = summary[:35] if summary else ""
    print("%-12s %-10s %-40s %s" % (date_str, short_id, title_display, summary_display))
PYEOF

    rm -f "$tmpfile"
}

# Show detailed metadata for a single session.
info_session() {
    local short_id="$1"
    if [ -z "$short_id" ]; then
        echo "Usage: claude-sessions info SHORT_ID"
        return 1
    fi
    local proj_dir
    proj_dir=$(get_proj_dir) || { echo "No sessions-index.json found."; return 1; }
    local index_file="$proj_dir/$INDEX_SUFFIX"

    local full_file
    full_file=$(ls "$proj_dir"/${short_id}*.jsonl 2>/dev/null | grep -v agent- | head -1)
    if [ -z "$full_file" ]; then
        echo "Session not found: $short_id"
        return 1
    fi

    python3 - "$index_file" "$full_file" <<'PYEOF'
import json, sys, os
from datetime import datetime

index_file = sys.argv[1]
filepath = sys.argv[2]
sid = os.path.basename(filepath).replace(".jsonl", "")

entry = None
try:
    with open(index_file) as f:
        data = json.load(f)
    for e in data["entries"]:
        if e["sessionId"] == sid:
            entry = e
            break
except Exception:
    pass

# Extract real title
title = ""
try:
    with open(filepath) as fh:
        for line in fh:
            try:
                msg = json.loads(line)
                if msg.get("type") not in ("human", "user"):
                    continue
                content = msg.get("message", {}).get("content", "")
                if isinstance(content, list):
                    for c in content:
                        if isinstance(c, dict) and c.get("type") == "text":
                            text = c.get("text", "").strip()
                            if text and not text.startswith("<"):
                                title = text
                                break
                elif isinstance(content, str):
                    text = content.strip()
                    if text and not text.startswith("<"):
                        title = text
                if title:
                    break
            except Exception:
                continue
except Exception:
    pass

file_size = os.path.getsize(filepath)
file_mtime = datetime.fromtimestamp(os.path.getmtime(filepath)).strftime("%Y-%m-%d %H:%M")

print(f"Session:  {sid}")
print(f"File:     {filepath}")
print(f"Size:     {file_size / 1024:.0f} KB")
print(f"Mtime:    {file_mtime}")
print()

if title:
    lines = title.split("\n")[:3]
    print(f"Title:    {lines[0][:80]}")
    for l in lines[1:]:
        print(f"          {l[:80]}")

if entry:
    print(f"Created:  {entry.get('created', '')}")
    print(f"Modified: {entry.get('modified', '')}")
    print(f"Messages: {entry.get('messageCount', '?')}")
    print(f"Summary:  {entry.get('summary', '(none)')}")
    print(f"Branch:   {entry.get('gitBranch') or '(none)'}")
else:
    print("(not in sessions-index.json — file exists on disk only)")

print()
print(f"To read:   claude-sessions read {sid[:8]}")
print(f"To resume: claude-sessions resume {sid[:8]}")
PYEOF
}

# Read conversation messages from a session file, paged with less.
read_session() {
    local short_id="$1"
    if [ -z "$short_id" ]; then
        echo "Usage: claude-sessions read SHORT_ID"
        echo "  Shows USER/CLAUDE turns, paged with less."
        return 1
    fi
    local proj_dir
    proj_dir=$(get_proj_dir) || { echo "No sessions-index.json found."; return 1; }

    local full_file
    full_file=$(ls "$proj_dir"/${short_id}*.jsonl 2>/dev/null | grep -v agent- | head -1)
    if [ -z "$full_file" ]; then
        echo "Session not found: $short_id"
        return 1
    fi

    echo "Reading: $(basename "$full_file")"
    echo ""

    python3 - "$full_file" <<'PYEOF' | less
import json, sys

filepath = sys.argv[1]
msg_num = 0

with open(filepath) as fh:
    for line in fh:
        try:
            msg = json.loads(line)
            t = msg.get("type", "")

            if t in ("human", "user"):
                content = msg.get("message", {}).get("content", "")
                if isinstance(content, list):
                    texts = []
                    for c in content:
                        if isinstance(c, dict) and c.get("type") == "text":
                            text = c.get("text", "").strip()
                            if text and not text.startswith("<"):
                                texts.append(text)
                    content = "\n".join(texts)
                elif isinstance(content, str):
                    content = content.strip()
                if content and not content.startswith("<"):
                    msg_num += 1
                    print(f"\n{'=' * 70}")
                    print(f"  USER (msg {msg_num})")
                    print(f"{'=' * 70}")
                    print(content[:3000])

            elif t == "assistant":
                content = msg.get("message", {}).get("content", "")
                if isinstance(content, list):
                    texts = [c.get("text", "") for c in content
                             if isinstance(c, dict) and c.get("type") == "text"]
                    content = "\n".join(t for t in texts if t)
                if content:
                    msg_num += 1
                    print(f"\n{'-' * 70}")
                    print(f"  CLAUDE (msg {msg_num})")
                    print(f"{'-' * 70}")
                    print(content[:3000])
        except Exception:
            pass
PYEOF
}

# Resume a session via Claude CLI.
# This also updates the file's mtime, causing VS Code to show it in the dropdown.
resume_session() {
    local short_id="$1"
    if [ -z "$short_id" ]; then
        echo "Usage: claude-sessions resume SHORT_ID"
        echo "  Opens the session in Claude CLI."
        echo "  The session will then appear in VS Code dropdown too."
        return 1
    fi
    local proj_dir
    proj_dir=$(get_proj_dir) || { echo "No sessions-index.json found."; return 1; }

    local full_id
    full_id=$(ls "$proj_dir"/*.jsonl 2>/dev/null | grep -v agent- | xargs -I{} basename {} .jsonl | grep "^$short_id")
    if [ -z "$full_id" ]; then
        echo "Session not found: $short_id"
        return 1
    fi
    echo "Resuming: $full_id"
    echo "(Session will appear in VS Code dropdown after this)"
    echo ""
    claude --resume "$full_id"
}

# --- Main ---

show_help() {
    cat <<'EOF'
claude-sessions - Search, browse, and resume Claude Code sessions

Commands:
  claude-sessions              List all indexed sessions (with real titles)
  claude-sessions search TERM  Search by keyword in titles, summaries, prompts
  claude-sessions grep TERM    Search in file contents (slower, covers all files on disk)
  claude-sessions info ID      Show session metadata and real title
  claude-sessions read ID      Read conversation messages (paged with less)
  claude-sessions resume ID    Resume session in Claude CLI terminal

ID = first 8 characters of the session UUID (shown in list/search output).

After 'resume', the session will appear in the VS Code "Past Conversations" dropdown.

Tip: create an alias for convenience:
  alias cs='/path/to/claude-sessions.sh'
EOF
}

case "${1:-list}" in
    list)                list_sessions "" ;;
    search)              list_sessions "$2" ;;
    grep)                grep_sessions "$2" ;;
    info)                info_session "$2" ;;
    read)                read_session "$2" ;;
    resume)              resume_session "$2" ;;
    version|--version)   echo "claude-sessions $VERSION" ;;
    help|-h|--help)      show_help ;;
    *)                   echo "Unknown command: $1 (try 'claude-sessions help')" ;;
esac
