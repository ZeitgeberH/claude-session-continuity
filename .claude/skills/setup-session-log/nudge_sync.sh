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
#   Stop — fires at the end of every turn; nudges every NUDGE_EVERY_TURNS turns.
#     THIS IS THE ONE THAT WORKS, and it is on by default. A turn boundary is a
#     moment the model can actually act on: it has a turn, and context to spare.
#   PostCompact — fires after context has been compacted. NOT PreCompact: the docs
#     are explicit that "there is no turn between the PreCompact hook running and
#     compaction happening", so a PreCompact nudge cannot be acted on before the
#     detail it wanted to save is already gone. PostCompact at least lands where
#     the model has a turn, and can salvage what survived compaction.
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

NUDGE_ON_COMPACT=1        # nudge after a compaction
NUDGE_EVERY_TURNS=25      # 0 disables; this is the trigger that can actually be acted on
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
  PostCompact)
    [ "$NUDGE_ON_COMPACT" = "1" ] || exit 0
    emit PostCompact "=== SESSION-LOG: context was just compacted ===
Detail from earlier in this session has been summarised away. Whatever you had learned but
not written down is now only as good as the summary you are left with — it will not get
better, and further compactions will erode it again.

ACTION: check the session-log chain head. If it does not already cover this session's work,
run /sync-mem NOW and record what you still know, while you still know it. Say plainly in
the log if a finding is one you can no longer fully reconstruct — a hedged note is worth
more to the next session than a confident guess."
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
