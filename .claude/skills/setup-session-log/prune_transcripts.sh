#!/usr/bin/env bash
# Retention for the transcript mirror. save_transcripts.sh only ever ADDS; nothing
# in the upstream skill rotates .claude-transcripts/, so it grows without bound and
# holds the full verbatim conversation of every session.
#
# OPT-IN. install.sh only wires this when you ask for a retention period; the
# default is to keep every transcript forever, because deleting someone's
# conversation history is not a thing to do by default.
#
# Deliberately a SEPARATE script rather than logic inside save_transcripts.sh, so
# that a project which never enables rotation carries no deletion code on a hook
# path at all.
#
# Prunes the MIRROR only, never the harness's own transcripts.
# Wire to SessionEnd (once per session — not Stop, which fires every turn).
set -u
proj="${CLAUDE_PROJECT_DIR:-$PWD}"
dst="$proj/.claude-transcripts"
conf="$proj/.claude/hooks/transcript-retention.conf"

RETENTION_DAYS=30     # delete mirrored .jsonl older than this
KEEP_NEWEST=3         # ...but always keep at least this many, whatever their age
[ -f "$conf" ] && . "$conf"

[ -d "$dst" ] || exit 0

# Newest-first list; anything within KEEP_NEWEST is exempt regardless of age.
mapfile -t all < <(ls -t "$dst"/*.jsonl 2>/dev/null)
[ "${#all[@]}" -le "$KEEP_NEWEST" ] && exit 0

removed=0
for f in "${all[@]:$KEEP_NEWEST}"; do
  # -mtime +N is "older than N days"; guard against a bad conf value.
  [ -n "$(find "$f" -maxdepth 0 -mtime "+$RETENTION_DAYS" 2>/dev/null)" ] || continue
  rm -f "$f" && removed=$((removed + 1)) \
    && echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')  pruned  $(basename "$f")" >> "$dst/PRUNE.log"
done

[ "$removed" -gt 0 ] && echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')  pruned $removed file(s), retention=${RETENTION_DAYS}d keep-newest=${KEEP_NEWEST}" >> "$dst/PRUNE.log"
exit 0
