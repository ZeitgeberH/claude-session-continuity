#!/usr/bin/env bash
# Nudge the agent to run /sync-mem before the session's detail is lost.
#
# ★ WHY A NUDGE AND NOT AN ACTION. This hook cannot run /sync-mem itself — hooks
# run shell commands, not skills — and it deliberately does not force the issue by
# blocking. It adds context asking the agent to sync. Two reasons:
#   - Blocking a turn (exit 2) hijacks whatever the user was mid-way through. A
#     sync forced at an arbitrary point often has nothing durable to save yet, so
#     the interruption buys nothing.
#
# ONE TRIGGER: Stop, every NUDGE_EVERY_TURNS turns (see sync-nudge.conf).
# A turn boundary is a moment the model can actually act on — it has a turn, and
# context to spare.
#
# ★ TWO COMPACTION TRIGGERS WERE TRIED AND BOTH REMOVED.
#   PreCompact cannot work: the hooks reference states there is "no turn between
#     the PreCompact hook running and compaction happening", so the nudge could not
#     be acted on until the detail it wanted to save was already gone. It looked
#     healthy — registered, firing, well-formed output — and did nothing.
#   PostCompact works mechanically but is not worth having: by then the detail IS
#     gone, so the sync it prompts records a degraded second-hand summary. That is
#     worse than no entry, because the chain's value rests on its entries being
#     trustworthy. Prompting for a low-confidence write pollutes it.
#
# ★ WHY NOT A CONTEXT-PERCENTAGE TRIGGER. No hook event receives context-window
# usage or token counts, so "sync at 40% full" cannot be implemented at all — only
# guessed at. Turn count is the honest approximation.
#
# CONDITION-AWARE: the turn counter resets whenever the chain head is actually
# written, so a session that syncs on its own is never nagged. Silent when no
# chain exists — SessionStart's bootstrap notice covers that case.
set -u
proj="${CLAUDE_PROJECT_DIR:-$PWD}"
conf="$proj/.claude/hooks/sync-nudge.conf"
state="$proj/.claude/hooks/.sync-nudge.state"

NUDGE_EVERY_TURNS=25      # nudge every N turns; 0 disables
[ -f "$conf" ] && . "$conf"

payload=$(cat 2>/dev/null || echo '{}')
event=$(printf '%s' "$payload" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("hook_event_name",""))
except Exception: print("")' 2>/dev/null)

# Locate the chain; stay silent if there is none (bootstrap notice handles that).
logdir=""
for cand in "$proj/.claude-memory/session_logs" "$proj/.claude/memory/session_logs"; do
  [ -d "$cand" ] && logdir="$cand" && break
done
[ -z "$logdir" ] && exit 0
head=$(ls "$logdir"/session_*.md 2>/dev/null | sort | tail -1)
[ -z "$head" ] && exit 0

# Fingerprint = mtime + size, compared for INEQUALITY rather than "newer".
# mtime alone has one-second granularity, so a sync finishing in the same second as
# the last state write would go undetected and produce a spurious nudge; size catches
# that. Inequality also handles the head being replaced by an older file.
head_fp="$(stat -c '%Y-%s' "$head" 2>/dev/null || stat -f '%m-%z' "$head" 2>/dev/null || echo 0-0)"

emit() {   # $1 = hookEventName, $2 = text
  python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":sys.argv[1],"additionalContext":sys.argv[2]}}))' "$1" "$2"
}

case "$event" in
  Stop)
    [ "$NUDGE_EVERY_TURNS" -gt 0 ] 2>/dev/null || exit 0
    count=0; last_fp=""
    [ -f "$state" ] && read -r count last_fp < "$state" 2>/dev/null
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    # First sight: adopt the current fingerprint rather than treating it as a change,
    # so initialising the state does not silently consume the first turn.
    [ -z "$last_fp" ] && last_fp="$head_fp"
    if [ "$head_fp" != "$last_fp" ]; then
      # the chain head changed since we last looked — a sync happened. Reset.
      printf '0 %s\n' "$head_fp" > "$state"; exit 0
    fi
    count=$((count + 1))
    if [ "$count" -ge "$NUDGE_EVERY_TURNS" ]; then
      printf '0 %s\n' "$head_fp" > "$state"
      emit Stop "=== SESSION-LOG: $NUDGE_EVERY_TURNS turns since the last sync ===
Nothing is wrong — this is a periodic reminder that findings from this session are not yet
in the log chain.

If work has reached a point worth recording, run /sync-mem. If it has not, ignore this and
carry on; the reminder will come back later. Do not interrupt what the user asked for in
order to sync."
    else
      printf '%s %s\n' "$count" "$last_fp" > "$state"
    fi
    ;;
esac
exit 0
