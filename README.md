# agentSkills_mem

Two Claude Code skills for giving a long-horizon, multi-session project working memory across
sessions — extracted from a working project so other agents/projects can pull just these, without
unrelated project-specific baggage.

## `setup-session-log`

Scaffolds an append-only, prev/next-linked chain of per-session summaries
(`session_logs/session_NNN_YYYY-MM-DD.md`), auto-injected into every new session via a
`SessionStart` hook (`inject_session_log.sh`) — so an agent starts each session knowing what the
previous one did and planned next, deterministically, without relying on a "read the log first"
reminder.

Includes a built-in staleness check: if the working tree has files modified after the chain head's
own date (per `git status`), the hook warns instead of silently trusting a log that might not
reflect recent work. Portable — tries GNU `stat` first, falls back to BSD/macOS `stat -f`.

## `sync-mem`

Persists a session's durable findings — corrections, decisions, project state — into general
memory plus the session-log chain, at natural checkpoints (before stepping away, or on request).
Covers both generic memory and any project-specific extension declared in
`.claude/sync-mem-project.md`.

## Installing in another project

Copy `.claude/skills/setup-session-log/` and/or `.claude/skills/sync-mem/` into the target
project's `.claude/skills/`, then invoke `/setup-session-log` there to scaffold the chain and
register the hook. See each skill's `SKILL.md` for full detail.

## License

MIT — see [LICENSE](LICENSE).
