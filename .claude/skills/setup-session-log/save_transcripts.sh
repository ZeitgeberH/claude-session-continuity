#!/usr/bin/env bash
# Mirror the raw session transcripts into the project, so they survive the harness
# directory being destroyed (container rebuild, machine change, cleanup policy).
#
# ★ WHY THIS SHIPS WITH setup-session-log. Every session log carries a
# `transcript:` field pointing into ~/.claude/projects/<sanitized-cwd>/. That is an
# index INTO the lossless record — but the directory it points at is NOT durable.
# Without this hook the chain advertises a drill-down path it cannot honour: in a
# real devcontainer project a rebuild destroyed ~4 months of transcripts and every
# `transcript:` pointer in 39 logs became dead, while the logs themselves (living in
# the project) survived intact. The chain is the curated layer; this makes the raw
# layer as durable as the project itself.
#
# ⚠ COPY, NOT SYMLINK — deliberate, and the opposite of what SKILL.md Step 1
# recommends for the MEMORY dir. That "invert the link" pattern (real files in the
# repo, harness dir symlinked at them) is right for memory and WRONG here: applying
# it to the transcript dir means `mv`-ing a directory Claude Code is ACTIVELY
# WRITING the current session into. A copy has the same durability, never touches
# the source, and cannot corrupt a live session.
#
# ⚠ NEVER TOUCHES the memory dir or the session-log chain. Different stores.
#
# Wire to SessionEnd (captures the finished session) AND Stop (so an abruptly-killed
# environment still leaves a near-complete mirror — a rebuild is exactly the case
# where SessionEnd may never fire). Cheap: copies only when the source is newer.
set -u
proj="${CLAUDE_PROJECT_DIR:-$PWD}"

# Claude Code stores transcripts under a project dir named for the cwd with every
# '/' replaced by '-'  (e.g. /workspace -> -workspace, /home/u/p -> -home-u-p).
sanitized="${proj//\//-}"
src="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$sanitized"
dst="$proj/.claude-transcripts"

[ -d "$src" ] || exit 0
mkdir -p "$dst" 2>/dev/null || exit 0

for f in "$src"/*.jsonl; do
  [ -e "$f" ] || continue                       # no-match guard (no nullglob)
  base=$(basename "$f")
  if [ ! -f "$dst/$base" ] || [ "$f" -nt "$dst/$base" ]; then
    # write to a temp name then move, so a killed copy never leaves a truncated file
    cp -p "$f" "$dst/$base.tmp" 2>/dev/null && mv -f "$dst/$base.tmp" "$dst/$base"
  fi
done

# A small manifest, so a future session can see what was captured without parsing
# a directory of UUIDs.
{
  echo "# Transcript mirror — written by .claude/hooks/save_transcripts.sh"
  echo "# Source: $src (NOT durable). This copy lives in the project and survives."
  echo "# last-run: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo
  for f in "$dst"/*.jsonl; do
    [ -e "$f" ] || continue
    d=$(stat -c '%y' "$f" 2>/dev/null | cut -c1-16)
    [ -z "$d" ] && d=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f" 2>/dev/null)   # BSD
    s=$(stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f" 2>/dev/null || echo 0)
    printf '%s  %8s KB  %s\n' "$d" "$(( (s + 1023) / 1024 ))" "$(basename "$f")"
  done
} > "$dst/MANIFEST.txt" 2>/dev/null

exit 0
