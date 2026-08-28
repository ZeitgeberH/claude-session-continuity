#!/usr/bin/env bash
# Nudge the agent to run /sync-mem before the session's detail is lost.
#
# ★ WHY A NUDGE AND NOT AN ACTION. This hook cannot run /sync-mem itself — hooks
# run shell commands, not skills — and it deliberately does not force the issue by
# blocking. It adds context asking the agent to sync. Two reasons:
#   - Blocking a turn (exit 2) hijacks whatever the user was mid-way through. A
#     sync forced at an arbitrary point often has nothing durable to save yet.
#   - On PreCompact especially, blocking means starting a substantial operation in
#     a context that is already full — the moment it is most likely to fail.
#
# TWO TRIGGERS, configured in .claude/hooks/sync-nudge.conf:
#   PreCompact — fires just before context is compacted, which is the moment
#     detail is actually about to be lost. Rare, precise, on by default. There is
#     no "context is N% full" hook input to key off instead: no hook event
#     receives context-window usage or token counts at all.
#   Stop — fires every turn; nudges every NUDGE_EVERY_TURNS turns. Off by default
#     (0). A turn count cannot tell a natural checkpoint from the middle of a
#     debugging chain, so it is a blunt instrument — useful as a backstop, not as
#     the primary trigger.
#
# CONDITION-AWARE: the turn counter resets whenever the chain head is actually
# written, so a session that syncs on its own is never nagged. Silent when no
# chain exists — SessionStart's bootstrap notice covers that case.
set -u
proj="${CLAUDE_PROJECT_DIR:-$PWD}"
conf="$proj/.claude/hooks/sync-nudge.conf"
state="$proj/.claude/hooks/.sync-nudge.state"

NUDGE_ON_COMPACT=1        # nudge before compaction
NUDGE_EVERY_TURNS=0       # 0 = never nudge on turn count
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
  PreCompact)
    [ "$NUDGE_ON_COMPACT" = "1" ] || exit 0
    emit PreCompact "=== SESSION-LOG: context is about to be compacted ===
Detail from this session is about to be summarised away. Anything learned but not yet
written down will be harder to recover afterwards.

ACTION: run /sync-mem now, before continuing — it appends this session's findings to the
log chain and saves what is durable to memory. If you have already synced since the last
substantive work, say so briefly and carry on; do not sync twice for nothing."
    ;;
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
