# agentSkills_mem

A pair of Claude Code skills for giving a long-horizon, multi-session project working memory across
sessions. For a short-lived project, or one already tracked in an external PM tool, it's overhead
without much payoff.

**Why use this.** `setup-session-log` gives an agent a time machine for its own project memory: a
chain of session logs linked by `prev`/`next`, walkable backward on demand. Most sessions, an agent
doesn't travel at all — it just lives in the present, the current head, auto-injected
automatically. But the chain is where you go when a fact needs checking: when was this believed
true, why, and has anything changed since. `sync-mem` is what keeps a fact from getting stranded
back there — it pulls what's durable out of a session's narrative and into memory *before* that
session becomes just another stop on the timeline, so the next agent doesn't have to travel back to
find it. 

Without this pairing, an agent starting a new session has to reconstruct "where things stand" from
git log and code alone — roughly 10x the tokens of reading one pre-digested entry, and some things
(why an approach was tried and dropped, what's still shaky) never make it into git at all.

## `setup-session-log`

An append-only, prev/next-linked chain of per-session summaries
(`session_logs/session_NNN_YYYY-MM-DD.md`), auto-injected into every new session via a
`SessionStart` hook — so an agent starts already knowing what happened and what's next, without a
"read the log first" reminder.

Includes a staleness check: warns if the working tree has changed since the chain head's own date,
instead of silently trusting a log that might be out of date. Portable — GNU `stat` first, BSD/
macOS `stat -f` fallback.

## `sync-mem`

Persists a session's durable findings — corrections, decisions, project state — into memory and
the session-log chain, at natural checkpoints. Covers general memory plus any project-specific
extension declared in `.claude/sync-mem-project.md`.

## Installing in another project

Copy `.claude/skills/setup-session-log/` and/or `.claude/skills/sync-mem/` into the target
project's `.claude/skills/`, then invoke `/setup-session-log` there to scaffold the chain and
register the hook. See each skill's `SKILL.md` for full detail.

## License

MIT — see [LICENSE](LICENSE).
