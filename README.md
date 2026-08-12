# agentSkills_mem

Two Claude Code skills for giving a long-horizon, multi-session project working memory across
sessions.

**Why use this.** Together the two skills split a project's memory along two axes, not one:

- **Access — short-term vs. long-term.** The session-log chain is long-term in *storage* (nothing
  in it is ever deleted or overwritten) but short-term in *use*: only the current head is
  auto-injected and actively read each session. The rest sits archived, walked via `prev`/`next`
  links only when you deliberately need it — chasing the provenance of a past decision, not
  routine reading.
- **Content — episodic vs. semantic.** The chain is episodic: dated, narrative, "session N did X,
  decided Y, planned Z next." `sync-mem` writes the complementary layer into Claude Code's
  built-in memory system, which is semantic: durable facts and decisions, stripped of when or why
  they were learned.

An agent needs both. A fact without its provenance can quietly go stale; a narrative with nowhere
to distill facts out of it just grows forever, unread. Without this pairing, an agent starting a
new session has to reconstruct "where things stand" from git log and code alone — roughly 10x the
tokens of reading one pre-digested entry, and some things (why an approach was tried and dropped,
what's still shaky) never make it into git at all. For a short-lived project, or one already
tracked in an external PM tool, it's overhead without much payoff.

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
