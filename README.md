# agentSkills_mem

Two Claude Code skills for giving a long-horizon, multi-session project working memory across
sessions.

**Why use this.** Without it, an agent starting a new session has to reconstruct "where things
stand" from git log and code alone — reading one pre-digested session-log entry costs roughly a
tenth the tokens that reconstruction does, and some things never make it into git at all (why an
approach was tried and dropped, what's still shaky, what to check before trusting a number). The
chain is a convenience cache, not a source of truth — git and the code stay authoritative — but for
a project where sessions are spread across days or weeks and judgment calls accumulate, that cache
is the difference between re-deriving context every time and picking up cleanly. For a short-lived
project, or one already tracked in an external PM tool, it's overhead without much payoff.

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
