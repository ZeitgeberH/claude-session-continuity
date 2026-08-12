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
[ -z "$logdir" ] && exit 0          # no chain in this project → inject nothing

head=$(ls "$logdir"/session_*.md 2>/dev/null | sort | tail -1)
[ -z "$head" ] && exit 0            # dir exists but empty → nothing to inject

# --- Staleness check --------------------------------------------------------
# The chain can go stale silently: work happens (files get touched) without a
# session log ever being appended for it. Catch the common case — compare the
# head's own date against the newest mtime among files git already flags as
# changed (tracked-modified + untracked). Deliberately NOT `git log -1`: a
# session can leave real, uncommitted work behind, and commit dates would miss
# exactly that (this is how a real 4-day gap was first found in this project).
# Simplification, not exhaustive: an untracked *directory* collapses to one
# `git status` line, so files newly added deep inside one may not surface here.
head_date=$(basename "$head" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
stale_count=0
stale_newest=""
stale_newest_date=""
if [ -n "$head_date" ] && git -C "$proj" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    fpath="$proj/$f"
    [ -f "$fpath" ] || continue
    # GNU stat first (Linux); BSD stat (macOS) rejects -c, so fall back to its -f/-t form.
    fdate=$(stat -c '%y' "$fpath" 2>/dev/null | cut -c1-10)
    [ -z "$fdate" ] && fdate=$(stat -f '%Sm' -t '%Y-%m-%d' "$fpath" 2>/dev/null)
    [ -z "$fdate" ] && continue
    if [[ "$fdate" > "$head_date" ]]; then
      stale_count=$((stale_count + 1))
      if [ -z "$stale_newest_date" ] || [[ "$fdate" > "$stale_newest_date" ]]; then
        stale_newest_date="$fdate"
        stale_newest="$f"
      fi
    fi
  done < <(git -C "$proj" status --porcelain 2>/dev/null | cut -c4- | grep -v '^\.claude-memory/')
fi

python3 - "$head" "$head_date" "$stale_count" "$stale_newest" "$stale_newest_date" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
head_date, stale_count, stale_newest, stale_newest_date = sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
try:
    body = p.read_text()
except Exception:
    sys.exit(0)
warning = ""
if stale_count:
    warning = (
        f"\n⚠ SESSION-LOG STALENESS WARNING: {stale_count} file(s) in the working tree were "
        f"modified after this chain head's date ({head_date}) — newest: {stale_newest} "
        f"({stale_newest_date}). The log below may not reflect that work. Check `git status` / "
        f"`git log` before trusting it as complete, and consider appending a session log for the "
        f"gap once you understand it.\n"
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
