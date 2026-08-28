#!/usr/bin/env bash
# One-screen git state for the /sync-mem audit + report. Read-only: never commits,
# stages, or pushes. Degrades quietly on a non-repo or a repo with no remote.
set -u
proj="${CLAUDE_PROJECT_DIR:-$PWD}"
g() { git -C "$proj" "$@" 2>/dev/null; }

g rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "ℹ git: not a repository — no commit discipline to report."
  echo "   (The chain is then unauditable against code; consider 'git init'.)"; exit 0; }

branch=$(g branch --show-current); [ -z "$branch" ] && branch=$(g rev-parse --abbrev-ref HEAD)
if ! g rev-parse HEAD >/dev/null 2>&1; then
  echo "⚠ git: branch '$branch' has NO COMMITS yet — nothing the session log can point at."; exit 0
fi

mod=$(g status --porcelain --untracked-files=all | grep -cv '^??')
unt=$(g status --porcelain --untracked-files=all | grep -c '^??')
head_sha=$(g rev-parse --short HEAD)
head_age=$(g log -1 --format=%cr)

line="branch $branch @ $head_sha ($head_age)"
[ $((mod + unt)) -eq 0 ] && line="$line | tree clean" \
  || line="$line | UNCOMMITTED: $mod tracked, $unt untracked"

up=$(g rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')
if [ -n "$up" ]; then
  ahead=$(g rev-list --count "$up"..HEAD); behind=$(g rev-list --count HEAD.."$up")
  [ "$ahead" -gt 0 ] && line="$line | $ahead unpushed"
  [ "$behind" -gt 0 ] && line="$line | $behind behind $up"
else
  line="$line | no upstream (local only)"
fi
echo "$line"

# The lever: the chain is tracked, so an uncommitted log is invisible to any clone.
chain=""
for c in "$proj/.claude-memory/session_logs" "$proj/.claude/memory/session_logs"; do
  [ -d "$c" ] && chain="$c" && break
done
if [ -n "$chain" ]; then
  head_log=$(ls "$chain"/session_*.md 2>/dev/null | sort | tail -1)
  if [ -n "$head_log" ]; then
    rel="${head_log#$proj/}"
    if g check-ignore -q "$head_log"; then
      echo "⚠ the session-log chain is GITIGNORED — it cannot be shared or audited."
    elif [ -n "$(g status --porcelain --untracked-files=all -- "$rel")" ]; then
      echo "⚠ $rel is uncommitted — commit it with the work it describes."
    else
      echo "✅ chain head is committed."
    fi
  fi
fi
