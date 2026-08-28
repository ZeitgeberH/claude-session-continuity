#!/usr/bin/env bash
# Install the session-log / memory skills into a target project.
#
# Does the mechanical half of the setup — copy the skills, symlink the hooks,
# merge settings.json, seed .gitignore — so that all that's left is a session
# restart and one /setup-session-log invocation.
#
# Deliberately does NOT scaffold the chain: the first log needs today's date, the
# session UUID, and an actual summary of the session. That's agent work, and
# /setup-session-log is idempotent, so it picks up cleanly from whatever this left.
#
#   ./install.sh [TARGET_PROJECT]         (default: current directory)
#   ./install.sh --dry-run ~/proj         show what would change, touch nothing
#   ./install.sh --create ~/new-proj      scaffold the project first, then install
#   ./install.sh --no-invert-memory ~/proj
#
# TARGET must already exist unless --create is given. It does NOT need a .claude/
# directory — that gets created. --create makes the directory, runs `git init`, and
# makes the initial commit once everything is in place, leaving a repo whose HEAD
# the first session log can point at. It is an explicit flag on purpose: silently
# creating a mistyped path would install into the wrong place and look like it
# worked.
#
# BY DEFAULT this also relocates the project's memory dir into the project:
#   ~/.claude/projects/<sanitized-target>/memory  becomes a symlink pointing at
#   TARGET/.claude/memory/store/. That is the only thing written outside TARGET.
# It moves the target project's OWN memory (that path holds nothing else), and it
# is what keeps memory alive across a container rebuild. --no-invert-memory skips
# it. Backed up, verified, and rolled back automatically on failure.
#
# Re-runnable: every step checks before writing.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0; INVERT=1; CREATE=0; TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)          DRY=1 ;;
    --create)           CREATE=1 ;;
    --no-invert-memory) INVERT=0 ;;
    --invert-memory)    INVERT=1 ;;   # now the default; accepted for compatibility
    -h|--help)       # print the whole header block, however long it grows
                        sed -n '2,${/^[^#]/q;p;}' "$0" | sed 's/^# \?//'; exit 0 ;;
    -*)              echo "unknown flag: $1" >&2; exit 2 ;;
    *)               TARGET="$1" ;;
  esac
  shift
done
TARGET="${TARGET:-$PWD}"

say()  { printf '  %s\n' "$*"; }
run()  { if [ "$DRY" = 1 ]; then say "would: $*"; else "$@"; fi; }

if [ ! -d "$TARGET" ]; then
  if [ "$CREATE" != 1 ]; then
    echo "no such directory: $TARGET" >&2
    echo "  (pass --create to scaffold it: mkdir + git init + initial commit)" >&2
    exit 1
  fi
  parent="$(dirname "$TARGET")"
  [ -d "$parent" ] || { echo "parent directory does not exist: $parent" >&2
                        echo "  --create makes the project, not the whole path." >&2; exit 1; }
  if [ "$DRY" = 1 ]; then
    echo "would: create project directory $TARGET"
    TARGET="$parent/$(basename "$TARGET")"
  else
    mkdir -p "$TARGET"; TARGET="$(cd "$TARGET" && pwd)"
    echo "  created project directory ✅"
  fi
else
  TARGET="$(cd "$TARGET" && pwd)"
fi
[ "$TARGET" = "$SRC" ] && { echo "refusing to install into the skills repo itself" >&2; exit 1; }
for s in setup-session-log sync-mem; do
  [ -d "$SRC/.claude/skills/$s" ] || { echo "missing source skill: $s" >&2; exit 1; }
done
command -v python3 >/dev/null || { echo "python3 required (settings.json merge)" >&2; exit 1; }

echo "Installing into $TARGET"; [ "$DRY" = 1 ] && echo "(dry run — nothing will be written)"

# --- git ---------------------------------------------------------------------
if [ "$CREATE" = 1 ] && ! git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ "$DRY" = 1 ]; then say "would: git init"
  else git -C "$TARGET" init -q && say "git: initialized ✅"; fi
fi
if git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$TARGET" rev-parse HEAD >/dev/null 2>&1; then
    say "git: repo present ✅"
  elif [ "$CREATE" = 1 ]; then
    :   # --create makes the initial commit at the end; don't warn about it here
  else
    say "git: repo has no commits yet — commit before the first session log."
  fi
else
  say "git: NOT a repository. Run 'git init' before /setup-session-log —"
  say "     it gives the staleness check its cheap mode and makes the chain"
  say "     auditable against commits. See README."
fi

# --- skills ------------------------------------------------------------------
run mkdir -p "$TARGET/.claude/skills"
for s in setup-session-log sync-mem; do
  if [ -d "$TARGET/.claude/skills/$s" ]; then say "skill $s: present, refreshing"; fi
  run cp -a "$SRC/.claude/skills/$s" "$TARGET/.claude/skills/"
  say "skill $s ✅"
done

# --- hooks: symlinks, not copies (see SKILL.md Step 6) -----------------------
run mkdir -p "$TARGET/.claude/hooks"
for h in inject_session_log.sh save_transcripts.sh; do
  if [ "$DRY" = 1 ]; then say "would: link .claude/hooks/$h -> ../skills/setup-session-log/$h"; continue; fi
  if [ -f "$TARGET/.claude/hooks/$h" ] && [ ! -L "$TARGET/.claude/hooks/$h" ]; then
    say "hook $h: real file present (deliberate fork?) — leaving it alone"
    continue
  fi
  ln -sfn "../skills/setup-session-log/$h" "$TARGET/.claude/hooks/$h"
  say "hook $h ✅ (symlink)"
done
run chmod +x "$TARGET/.claude/skills/setup-session-log/inject_session_log.sh" \
              "$TARGET/.claude/skills/setup-session-log/save_transcripts.sh"
[ -f "$SRC/.claude/skills/sync-mem/git_state.sh" ] && run chmod +x "$TARGET/.claude/skills/sync-mem/git_state.sh"

# --- settings.json: merge, never clobber -------------------------------------
if [ "$DRY" = 1 ]; then
  say "would: merge SessionStart/SessionEnd/Stop hooks into .claude/settings.json"
else
python3 - "$TARGET" <<'PY'
import json, pathlib, sys
target = sys.argv[1]
sp = pathlib.Path(target, ".claude/settings.json")
try:
    cfg = json.loads(sp.read_text()) if sp.exists() and sp.read_text().strip() else {}
except json.JSONDecodeError:
    print("  settings.json: INVALID JSON — not touching it. Merge the hooks by hand."); raise SystemExit(0)
# Project-relative via the env var Claude Code exports to hooks. Never an absolute
# path: settings.json is committed, and a baked-in path breaks every other checkout.
B = "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks"
reg = {"SessionStart": [(f"{B}/inject_session_log.sh", 10, "Loading session-log chain head...")],
       "SessionEnd":   [(f"{B}/save_transcripts.sh",   15, "Mirroring transcripts...")],
       "Stop":         [(f"{B}/save_transcripts.sh",   15, "Mirroring transcripts...")]}
hooks, added = cfg.setdefault("hooks", {}), 0
for event, entries in reg.items():
    matchers = hooks.setdefault(event, [])
    for cmd, timeout, msg in entries:
        if any(h.get("command") == cmd for m in matchers for h in m.get("hooks", [])):
            continue
        matchers.append({"hooks": [{"type": "command", "command": cmd,
                                    "timeout": timeout, "statusMessage": msg}]})
        added += 1
sp.parent.mkdir(parents=True, exist_ok=True)
sp.write_text(json.dumps(cfg, indent=2) + "\n")
json.loads(sp.read_text())
print(f"  settings.json ✅ ({added} hook(s) added, existing keys preserved)")
PY
fi

# --- gitignore ---------------------------------------------------------------
if [ "$DRY" = 1 ]; then say "would: add .claude-transcripts/ and .claude/memory/store/ to .gitignore"
else
  gi="$TARGET/.gitignore"; touch "$gi"
  for e in ".claude-transcripts/" ".claude/memory/store/"; do
    grep -qxF "$e" "$gi" || echo "$e" >> "$gi"
  done
  say "gitignore ✅ (transcripts + memory store; the chain stays tracked)"
fi

# --- optional: invert the memory dir -----------------------------------------
if [ "$INVERT" = 1 ]; then
  sanitized="${TARGET//\//-}"
  auto="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$sanitized/memory"
  store="$TARGET/.claude/memory/store"
  # The one write outside TARGET — always say so explicitly, before doing it.
  say "memory: relocating this project's memory dir INTO the project."
  say "        $auto"
  say "     -> $store"
  say "        (--no-invert-memory skips this. That path holds only this"
  say "        project's memory, and the move is what survives a rebuild.)"
  if [ -L "$auto" ]; then say "memory: already a symlink -> $(readlink "$auto") ✅"
  elif [ "$DRY" = 1 ]; then say "would: invert $auto -> $store"
  else
    mkdir -p "$store"
    [ -d "$auto" ] && cp -a "$auto/." "$store/" 2>/dev/null || true
    [ -f "$store/MEMORY.md" ] || printf '# Memory index\n' > "$store/MEMORY.md"
    [ -d "$auto" ] && mv "$auto" "$auto.bak"
    mkdir -p "$(dirname "$auto")"; ln -s "$store" "$auto"
    if [ -f "$auto/MEMORY.md" ]; then
      rm -rf "$auto.bak"
      say "memory: inverted ✅ (verified by reading MEMORY.md back through the link)"
      say "        ⚠ that harness path is derived from TARGET with '/' -> '-'. Open the"
      say "        project by a different path (other mount point, symlinked route) and"
      say "        the harness will use a different dir and not see this memory."
    else
      rm -f "$auto"; [ -d "$auto.bak" ] && mv "$auto.bak" "$auto"
      say "memory: inversion FAILED, rolled back"; exit 1
    fi
  fi
else
  say "memory: NOT inverted (--no-invert-memory). The memory dir stays under"
  say "        ~/.claude/. In a container that is the ephemeral half, so it will"
  say "        not survive a rebuild; inverting later means migrating files and"
  say "        rewriting their relative links. See README."
fi

# --- initial commit (only for a repo this run created) ------------------------
# Never commits in an existing repo: that tree can hold unrelated in-flight work,
# and sweeping it into a commit nobody asked for is the surprise we refuse to make.
# A repo we just initialized contains nothing but what this script put there.
if [ "$CREATE" = 1 ] && [ "$DRY" != 1 ] \
   && git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
   && ! git -C "$TARGET" rev-parse HEAD >/dev/null 2>&1; then
  git -C "$TARGET" add -A
  if git -C "$TARGET" -c commit.gpgsign=false commit -q \
       -m "Initial commit: session-log + memory continuity system" 2>/dev/null; then
    say "git: initial commit ✅ ($(git -C "$TARGET" rev-parse --short HEAD)) — the first"
    say "     session log now has a revision to anchor to."
  else
    say "git: initial commit skipped (is user.name/user.email set?). Commit by hand"
    say "     before the first session log."
  fi
fi

cat <<EOF

Done. Next:
  1. RESTART the session   — skills and hooks register at session start, not now.
  2. /setup-session-log    — scaffolds the chain (idempotent; picks up from here).
  3. RESTART again         — the SessionStart hook fires from here on.
Then work normally and run /sync-mem at checkpoints.
EOF
