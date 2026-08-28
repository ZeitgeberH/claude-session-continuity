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
#   ./install.sh --no-transcripts ~/proj      skip the transcript mirror
#   ./install.sh --nudge-turns 40 ~/proj      change the reminder cadence (0 = off)
#   ./install.sh --no-sync-nudge ~/proj       no sync reminders at all
#   ./install.sh --retention-days 30 ~/proj   rotate mirrored transcripts
#   ./install.sh -y ~/proj                    take every default, ask nothing
#
# On a terminal it ASKS about the two choices that are genuinely yours: where the
# project's memory should live, and whether to delete old transcripts. Piped or
# redirected (CI, scripts) it asks nothing and takes the defaults. Any flag you
# pass settles that question and suppresses its prompt.
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
DRY=0; INVERT=1; CREATE=0; TARGET=""; ASSUME_YES=0
INVERT_SET=0; RETENTION_DAYS=0; RETENTION_SET=0   # 0 days = keep forever (default)
MIRROR=1; MIRROR_SET=0                            # copy transcripts into the project (default)
NUDGE=1; NUDGE_TURNS=25                           # remind every N turns, and after a compaction
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)          DRY=1 ;;
    --create)           CREATE=1 ;;
    -y|--yes)           ASSUME_YES=1 ;;
    --no-invert-memory) INVERT=0; INVERT_SET=1 ;;
    --invert-memory)    INVERT=1; INVERT_SET=1 ;;
    --no-sync-nudge)    NUDGE=0 ;;
    --sync-nudge)       NUDGE=1 ;;
    --nudge-turns)      shift; NUDGE_TURNS="${1:-0}"; NUDGE=1
                        case "$NUDGE_TURNS" in ''|*[!0-9]*)
                          echo "--nudge-turns needs a whole number (0 = only before compaction)" >&2; exit 2 ;;
                        esac ;;
    --no-transcripts)   MIRROR=0; MIRROR_SET=1 ;;
    --transcripts)      MIRROR=1; MIRROR_SET=1 ;;
    --retention-days)   shift; RETENTION_DAYS="${1:-0}"; RETENTION_SET=1
                        case "$RETENTION_DAYS" in ''|*[!0-9]*)
                          echo "--retention-days needs a whole number (0 = keep forever)" >&2; exit 2 ;;
                        esac ;;
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

# --- ask, but only when there is a human to ask ------------------------------
# A prompt that blocks a CI run is worse than a default, so: TTY only, never with
# -y, and never for a question a flag already answered.
if [ -t 0 ] && [ "$ASSUME_YES" != 1 ]; then
  if [ "$INVERT_SET" != 1 ]; then
    cat <<'ASK'

  Where should this project's memory live?

  Between sessions Claude keeps notes about a project — decisions, context, what
  it learned. By default that store sits in Claude's own home folder (~/.claude),
  away from your project: it does not travel when you move, copy or share the
  project, and in a container it is wiped by a rebuild.

    1) In the project folder   — travels with the project, survives a rebuild
    2) In Claude's home folder — leave it where Claude puts it

ASK
    printf '  Choice [1]: '; read -r ans || ans=""
    case "$ans" in 2) INVERT=0 ;; *) INVERT=1 ;; esac
  fi

  if [ "$MIRROR_SET" != 1 ]; then
    cat <<'ASK'

  Keep a copy of session transcripts in the project?

  Claude Code stores a full transcript of every session under its own home folder,
  which is not durable — a container rebuild or a cleanup takes it, and each
  session log's pointer to its transcript dies with it. Copying them into the
  project keeps that record for as long as the project exists.

  They are the complete verbatim conversation, including anything you paste. The
  copy is gitignored, but that does not keep it out of a zip, a backup, or an
  image built from this directory.

    1) Yes, copy them into the project — durable, and drillable from each log
    2) No, leave them in Claude's home folder only

ASK
    printf '  Choice [1]: '; read -r ans || ans=""
    case "$ans" in 2) MIRROR=0 ;; *) MIRROR=1 ;; esac
  fi

  if [ "$MIRROR" = 1 ] && [ "$RETENTION_SET" != 1 ]; then
    cat <<'ASK'

  Delete old session transcripts?

  A full transcript of every session is copied into the project
  (.claude-transcripts/) so it survives Claude's home folder being cleared.
  Nothing removes them, so that folder grows for as long as the project lives —
  and it holds the complete text of every conversation.

    Press Enter to keep them forever, or type a number of days after which
    old ones are deleted (e.g. 30). The most recent 3 are always kept.

ASK
    printf '  Days [keep forever]: '; read -r ans || ans=""
    case "$ans" in
      ''|0|no|none|never)  RETENTION_DAYS=0 ;;
      *[!0-9]*)            say "not a number — keeping transcripts forever."; RETENTION_DAYS=0 ;;
      *)                   RETENTION_DAYS="$ans" ;;
    esac
  fi
  echo
fi

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
hooks_wanted="inject_session_log.sh"
[ "$MIRROR" = 1 ] && hooks_wanted="$hooks_wanted save_transcripts.sh"
[ "$NUDGE"  = 1 ] && hooks_wanted="$hooks_wanted nudge_sync.sh"
for h in $hooks_wanted; do
  if [ "$DRY" = 1 ]; then say "would: link .claude/hooks/$h -> ../skills/setup-session-log/$h"; continue; fi
  if [ -f "$TARGET/.claude/hooks/$h" ] && [ ! -L "$TARGET/.claude/hooks/$h" ]; then
    say "hook $h: real file present (deliberate fork?) — leaving it alone"
    continue
  fi
  ln -sfn "../skills/setup-session-log/$h" "$TARGET/.claude/hooks/$h"
  say "hook $h ✅ (symlink)"
done
if [ "$MIRROR" != 1 ]; then
  say "transcripts: NOT copied into the project. They stay in Claude's home folder"
  say "             only, so a rebuild or cleanup takes them and each session log's"
  say "             transcript: pointer dies with them. Re-run with --transcripts."
elif [ "$RETENTION_DAYS" -gt 0 ] 2>/dev/null; then
  if [ "$DRY" = 1 ]; then
    say "would: enable transcript rotation (${RETENTION_DAYS}d, keep newest 3)"
  else
    ln -sfn "../skills/setup-session-log/prune_transcripts.sh" "$TARGET/.claude/hooks/prune_transcripts.sh"
    cat > "$TARGET/.claude/hooks/transcript-retention.conf" <<CONF
# Retention policy for .claude-transcripts/ (read by prune_transcripts.sh).
# These files are the full verbatim conversation — treat as sensitive.
RETENTION_DAYS=$RETENTION_DAYS
KEEP_NEWEST=3
CONF
    say "transcripts: rotating after ${RETENTION_DAYS}d, newest 3 always kept ✅"
  fi
else
  say "transcripts: kept forever (no rotation). Prune by hand, or re-run with"
  say "             --retention-days N. The folder holds full conversations."
fi
if [ "$NUDGE" = 1 ]; then
  if [ "$DRY" = 1 ]; then
    say "would: enable sync reminders (before compaction${NUDGE_TURNS:+, every ${NUDGE_TURNS} turns})"
  else
    cat > "$TARGET/.claude/hooks/sync-nudge.conf" <<CONF
# When to remind the agent to run /sync-mem (read by nudge_sync.sh).
# NUDGE_EVERY_TURNS: remind every N turns; 0 disables. Read at runtime, so you can
#   change it here without re-running the installer.
# There is no compaction trigger: PreCompact cannot be acted on (no turn between it
#   and compaction) and PostCompact fires when the detail is already gone, so the
#   sync it prompts would record a degraded summary.
NUDGE_EVERY_TURNS=$NUDGE_TURNS
CONF
    if [ "$NUDGE_TURNS" -gt 0 ] 2>/dev/null; then
      say "sync reminders: every ${NUDGE_TURNS} turns ✅ (change it in sync-nudge.conf)"
    else
      say "sync reminders: hook installed but disabled (NUDGE_EVERY_TURNS=0)."
      say "                Set it in .claude/hooks/sync-nudge.conf to enable."
    fi
  fi
else
  say "sync reminders: not installed. /sync-mem is then entirely manual — nothing"
  say "                will prompt you, and unsaved findings can be lost."
fi
run chmod +x "$TARGET/.claude/skills/setup-session-log/inject_session_log.sh" \
              "$TARGET/.claude/skills/setup-session-log/save_transcripts.sh" \
              "$TARGET/.claude/skills/setup-session-log/prune_transcripts.sh" \
              "$TARGET/.claude/skills/setup-session-log/nudge_sync.sh"
[ -f "$SRC/.claude/skills/sync-mem/git_state.sh" ] && run chmod +x "$TARGET/.claude/skills/sync-mem/git_state.sh"

# --- settings.json: merge, never clobber -------------------------------------
if [ "$DRY" = 1 ]; then
  say "would: merge SessionStart/SessionEnd/Stop hooks into .claude/settings.json"
else
python3 - "$TARGET" "$RETENTION_DAYS" "$MIRROR" "$NUDGE" "$NUDGE_TURNS" <<'PY'
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
reg = {"SessionStart": [(f"{B}/inject_session_log.sh", 10, "Loading session-log chain head...")]}
if sys.argv[3] == "1":     # transcript mirror wanted
    reg["SessionEnd"] = [(f"{B}/save_transcripts.sh", 15, "Mirroring transcripts...")]
    reg["Stop"]       = [(f"{B}/save_transcripts.sh", 15, "Mirroring transcripts...")]
    if int(sys.argv[2]) > 0:   # rotation too — prune after the mirror, once per session
        reg["SessionEnd"].append((f"{B}/prune_transcripts.sh", 10, "Pruning old transcripts..."))
if sys.argv[4] == "1":     # sync reminders — always register, even at 0 turns.
    # The cadence lives in sync-nudge.conf and the script reads it at runtime. If the
    # hook were only registered when the count is non-zero, editing that conf later
    # would silently do nothing, which is exactly what happened to one install.
    reg.setdefault("Stop", []).append((f"{B}/nudge_sync.sh", 10, "Checking session-log state..."))
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
  ign=""
  [ "$MIRROR" = 1 ] && ign="$ign .claude-transcripts/"
  [ "$INVERT" = 1 ] && ign="$ign .claude/memory/store/"
  [ "$NUDGE"  = 1 ] && ign="$ign .claude/hooks/.sync-nudge.state"
  for e in $ign; do grep -qxF "$e" "$gi" || echo "$e" >> "$gi"; done
  if [ -n "$ign" ]; then say "gitignore ✅ ($(echo $ign); the chain stays tracked)"
  else say "gitignore: nothing to ignore (chain stays tracked)"; fi
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
  if [ -L "$auto" ]; then
    # ⚠ An existing symlink is NOT proof of a working setup. It can point at a
    # target that no longer exists — `store/` is gitignored, so `git clean -xdf`,
    # a fresh clone, or a deleted-and-recreated project all leave the link behind
    # and its target gone. Reporting ✅ on that is worse than failing: the harness
    # memory dir silently resolves to nothing and memory quietly stops working.
    # So: resolve it, and repair if it dangles.
    link_target=$(readlink "$auto")
    if [ "$link_target" != "$store" ]; then
      say "memory: ⚠ harness dir is a symlink to a DIFFERENT place:"
      say "          $link_target"
      say "        expected $store"
      say "        Leaving it untouched — two projects may share a path, or this"
      say "        one moved. Resolve by hand before relying on memory."
    elif [ -f "$auto/MEMORY.md" ]; then
      say "memory: already inverted, and the link resolves ✅"
    elif [ "$DRY" = 1 ]; then
      say "would: repair dangling memory link (target $store is missing)"
    else
      mkdir -p "$store"
      [ -f "$store/MEMORY.md" ] || printf '# Memory index\n' > "$store/MEMORY.md"
      if [ -f "$auto/MEMORY.md" ]; then
        say "memory: link existed but its target did not — REPAIRED ✅"
        say "        (recreated $store; any memory it once held is gone)"
      else
        say "memory: ⚠ link still does not resolve after repair. Inspect $auto"
      fi
    fi
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
  say "memory: staying in Claude's home folder (~/.claude), not the project."
  say "        In a container that is the ephemeral half, so it will not survive"
  say "        a rebuild; moving it into the project later means migrating files"
  say "        and rewriting their relative links. Re-run with --invert-memory."
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

Done — that was the setup. You are ready to work:

    cd $TARGET && claude

Use Claude Code as usual. Your first session creates and commits the session-log
chain in the background; run /sync-mem at checkpoints to save what it learned.

(Ran this from inside a session already open on this project? Restart that one —
skills register at session start.)
EOF
