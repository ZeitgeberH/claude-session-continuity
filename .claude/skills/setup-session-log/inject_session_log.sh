#!/usr/bin/env bash
# SessionStart hook — auto-inject the current session-log chain head into the new
# session's context, so the agent starts with the previous session's summary +
# planned next steps deterministically (no reliance on following a pointer).
#
# Installed per-project by the `setup-session-log` skill. PORTABLE: resolves the
# project's memory dir at runtime — no hardcoded path. JSON is built with python3
# (NOT jq, which is often absent) so it can't silently fail at session start.
proj="${CLAUDE_PROJECT_DIR:-$PWD}"
logdir=""
for cand in "$proj/.claude-memory/session_logs" "$proj/.claude/memory/session_logs"; do
  [ -d "$cand" ] && logdir="$cand" && break
done
head=""
[ -n "$logdir" ] && head=$(ls "$logdir"/session_*.md 2>/dev/null | sort | tail -1)

# --- Bootstrap: installed, but the chain was never created -------------------
# install.sh sets up the skills and hooks from a plain shell, where no session
# exists — so it cannot write the first log (that needs a session id and a real
# summary of a session that has not happened yet). Rather than leave the user to
# remember a follow-up command, say so HERE, in the one place guaranteed to be
# read at the moment it can be acted on. Fires only while no chain exists, so it
# cannot nag.
if [ -z "$head" ]; then
  [ -f "$proj/.claude/skills/setup-session-log/SKILL.md" ] || exit 0   # not our project
  bootstrap_msg=$(cat <<'MSG'
=== SESSION-LOG SETUP INCOMPLETE (auto-injected at SessionStart) ===
This project has the session-log system installed — skills present, hooks registered — but the
log chain itself has not been created yet, so there is no previous-session summary to load.

That is the expected state straight after install.sh: it runs in a plain shell where no session
exists, so it cannot write the first log, which needs a session id and a summary of a session
that has not happened.

ACTION: run the /setup-session-log skill now. It is idempotent — it detects what the installer
already did and fills in only what is missing. Tell the user you are doing it. Once the chain
exists this notice is replaced by the previous session summary, and you will not see it again.
MSG
)
  python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": sys.argv[1]}}))' "$bootstrap_msg"
  exit 0
fi

# --- Staleness check --------------------------------------------------------
# The chain can go stale silently: work happens (files get touched) without a
# session log ever being appended for it. Compare the head's own date against the
# newest work file in the tree.
#
# ★ TWO MODES, AND A THIRD STATE THAT ANNOUNCES ITSELF.
#   git   — files git already flags as changed (tracked-modified + untracked).
#           Deliberately NOT `git log -1`: a session can leave real, uncommitted
#           work behind, and commit dates miss exactly that (this is how a real
#           4-day gap was first found).
#   mtime — for projects that are NOT git repositories. Without this the check
#           runs, finds nothing, and reports clean FOREVER — a warning system that
#           can never fire, which is worse than none because it reads as coverage.
#           (Observed in a real devcontainer project whose workspace was not a repo:
#           a 13-day unlogged gap went unreported.)
#   n/a   — if neither mode is available, SAY SO. An inert check must never be
#           mistaken for a clean bill of health.
head_date=$(basename "$head" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
stale_count=0; stale_newest=""; stale_newest_date=""; mode=""

_consider() {   # $1 = absolute path; updates the stale_* accumulators
  local f="$1" fdate
  [ -f "$f" ] || return 0
  # GNU stat first (Linux); BSD stat (macOS) rejects -c, so fall back to its -f/-t form.
  fdate=$(stat -c '%y' "$f" 2>/dev/null | cut -c1-10)
  [ -z "$fdate" ] && fdate=$(stat -f '%Sm' -t '%Y-%m-%d' "$f" 2>/dev/null)
  [ -z "$fdate" ] && return 0
  if [[ "$fdate" > "$head_date" ]]; then
    stale_count=$((stale_count + 1))
    if [ -z "$stale_newest_date" ] || [[ "$fdate" > "$stale_newest_date" ]]; then
      stale_newest_date="$fdate"; stale_newest="${f#$proj/}"
    fi
  fi
}

if [ -n "$head_date" ]; then
  if git -C "$proj" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    mode="git"
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      _consider "$proj/$f"
    done < <(git -C "$proj" status --porcelain 2>/dev/null | cut -c4- \
             | grep -vE '^(\.claude-memory/|\.claude/memory/|\.claude-transcripts/)')
  elif find "$proj" -maxdepth 0 -newermt "1970-01-01" >/dev/null 2>&1; then
    # Not a git repo, but `find -newermt` works → walk mtimes directly.
    mode="mtime"
    # Optional per-project tuning: one path per line (relative to the project root,
    # '#' comments allowed) in .claude/hooks/staleness-prune.txt. Large data/vendor
    # trees make the generic walk slow — on one real project pruning data/, src/ and
    # a sibling repo took it 1.6 s -> 0.04 s. Tuning here means a project never has
    # to FORK this script, which is how upstream fixes stop reaching people.
    extra_prune=()
    if [ -f "$proj/.claude/hooks/staleness-prune.txt" ]; then
      while IFS= read -r line; do
        line="${line%%#*}"; line="${line// /}"
        [ -n "$line" ] && extra_prune+=( -o -path "$proj/${line%/}" )
      done < "$proj/.claude/hooks/staleness-prune.txt"
    fi
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      _consider "$f"
    done < <(find "$proj" \
          \( -name '.git' -o -name 'node_modules' -o -name '__pycache__' \
             -o -name '.ipynb_checkpoints' -o -name '.venv' -o -name 'venv' \
             -o -name '.claude-transcripts' -o -name '.claude-memory' \
             -o -path "$proj/.claude/memory" "${extra_prune[@]}" \) -prune -o \
          -type f \( -name '*.py' -o -name '*.md' -o -name '*.ipynb' -o -name '*.js' \
             -o -name '*.ts' -o -name '*.R' -o -name '*.jl' -o -name '*.sh' \
             -o -name '*.csv' -o -name '*.parquet' -o -name '*.json' -o -name '*.yaml' \) \
          -newermt "$head_date 23:59:59" -print 2>/dev/null | head -500)
  else
    mode="unavailable"
  fi
fi

python3 - "$head" "$head_date" "$stale_count" "$stale_newest" "$stale_newest_date" "$mode" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
head_date, stale_count, stale_newest, stale_newest_date, mode = (
    sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6])
try:
    body = p.read_text()
except Exception:
    sys.exit(0)
warning = ""
if stale_count:
    warning = (
        f"\n⚠ SESSION-LOG STALENESS WARNING ({mode}): {stale_count} file(s) in the working tree "
        f"were modified after this chain head's date ({head_date}) — newest: {stale_newest} "
        f"({stale_newest_date}). The log below may not reflect that work. Check before trusting it "
        f"as complete, and consider appending a session log for the gap once you understand it.\n"
    )
elif mode == "unavailable":
    # An inert check must declare itself — silence would read as "verified clean".
    warning = (
        "\nℹ Staleness check UNAVAILABLE here (not a git repository, and `find -newermt` is not "
        "supported). Absence of a warning below does NOT mean the chain is up to date — verify "
        "manually that a log exists for any recent work.\n"
    )
ctx = (
    "=== SESSION-LOG CHAIN HEAD (auto-injected at SessionStart) ===\n"
    f"This is the previous session's summary + planned next steps. File: {p}\n"
    f"Walk each log's `prev:` link in {p.parent} for older history; "
    "the full memory index is in MEMORY.md. Each log's `session_id`/`transcript` "
    "points to the raw turn-by-turn record if you need detail beyond the summary."
    + warning + "\n"
    + body
)
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ctx,
}}))
PY
