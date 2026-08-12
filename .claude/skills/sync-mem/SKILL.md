---
name: sync-mem
description: Persist this session's durable findings to memory (memory entries + MEMORY.md index) and to any project-specific files declared in the current project's `.claude/sync-mem-project.md` extension. Invoke at natural session checkpoints — after a meaningful finding lands, before stepping away, or when the user explicitly asks to save state. Single entry point covering both general-purpose memory and project-specific markdown / data-file maintenance.
---

# /sync-mem — persist session findings

Use this skill when work in the session has reached a stable point worth saving for the next session. **One invocation handles both general-purpose memory and project-specific extensions.**

> **Integrates with `setup-session-log`.** When a `session_logs/` chain is installed, the ephemeral carry-over (Step 8) is APPENDED to the chain (the head is the "for next session", auto-injected at SessionStart) instead of overwriting `for_next_session.md`. Durable findings (Steps 1–7) go to memory files as usual. Episodic (session-logs) and semantic (memory / ologs) are complementary layers.

> **Compatibility with the auto-memory system (read first).** Three harness facts change how the steps below behave:
> - **Frontmatter normalizer.** Any file written *into* the auto-memory `memory/` dir is rewritten to the memory schema — it stamps `originSessionId`, may nest fields under `metadata:`, and **strips non-schema keys**. So don't rely on extra frontmatter keys persisting in memory entries.
> - **Session-log chain location.** The chain lives *outside* the memory dir — precisely so the normalizer doesn't strip its `prev`/`next` links. `session-log-protocol.md` records the exact path for this project; trust it over anything hardcoded here.
>   **Symlinks resolving the memory dir run *inward*** (harness → project), never outward: an outward `.claude-memory` symlink embeds an absolute *host* path inside the project tree, which breaks in a devcontainer, a remote workspace, or any environment where that host path doesn't exist — the editor reports missing files. The harness-side memory dir should instead be a symlink pointing inward at the project's own copy.
> - **MEMORY.md organization.** Preserve whatever structure the project's `MEMORY.md` already uses (this one is a flat index); do not impose a different sectioning.

## Procedure

### Step 1 — Diff the conversation

Look back at the conversation since the last `/sync-mem` invocation (or the start of the session if none). Identify durable findings worth persisting. Group them by which auto-memory type fits:

- **User memory** — role, goals, responsibilities, knowledge, preferences.
- **Feedback memory** — guidance the user gave on how to approach work (corrections AND validated approaches). Include `**Why:**` and `**How to apply:**` lines.
- **Project memory** — ongoing-work state, decisions, deadlines, key incidents that aren't derivable from code or git. Convert relative dates to absolute.
- **Reference memory** — pointers to external systems / papers / docs.

### Step 2 — Apply the "do not save" filter

Drop anything that matches the auto-memory exclusion list:
- Code patterns, conventions, architecture, file paths, project structure (derivable from current code).
- Git history / who-changed-what (use `git log` / `git blame` instead).
- Debugging solutions or fix recipes (the fix is in the code).
- Anything already in CLAUDE.md.
- Ephemeral task state, in-progress work, current-conversation-only context.

These exclusions apply even when the user asks to save them. If the user explicitly requests something on the exclusion list, ask what was *surprising* or *non-obvious* about it — that's the part worth keeping.

### Step 3 — Plan the writes (DON'T write yet)

For each finding that survives the filter, decide:
- **New memory file?** Choose a `<type>_<topic>.md` filename. Check `MEMORY.md` first to confirm no existing file covers it.
- **Update existing file?** Use `Edit` for small additions; only `Write` to fully rewrite.
- **MEMORY.md index touch?** Required for any new file; rewrite the line for any updated description.
- **Ephemeral carry-over?** Items that didn't survive Step 2's filter but are still useful for the *next* session (in-flight tasks, decisions on probation, working context). Track these as candidates for the session-log carry-over (Step 8; or `for_next_session.md` in the no-chain fallback) — they're written *last*, after long-term writes finalize.

Build a per-file plan: filename, action (create/edit/skip), one-line summary of what's being saved. Surface the ephemeral candidates explicitly so they're visible during user confirmation.

### Step 4 — Confirm with the user

Show the plan as a short bulleted list:
```
About to save:
- NEW: feedback_<topic>.md — <one-line summary>
- EDIT: project_<topic>.md — adding <X>
- INDEX: 2 new lines in MEMORY.md
- CARRY-OVER (session-log chain, or for_next_session.md fallback): <ephemeral items>
- SKIP (off-topic ephemeral): <X>, <Y>
- AMBIGUOUS — needs your call: <Z>
```

Wait for user confirmation (or implicit approval if the user said "/sync-mem just do it"). Resolve ambiguous items with the user before writing. The carry-over doesn't need separate confirmation — in chain mode a new session-log is *appended* (durable, immutable, never overwriting history); in the no-chain fallback `for_next_session.md` is *overwritten* safely. Only confirm the long-term writes and any ambiguous items.

### Step 5 — Execute the memory writes

Memory file format (frontmatter required):
```markdown
---
name: <Memory name>
description: <One-line description, used for recall — be specific>
type: <user | feedback | project | reference>
---

<Body. For feedback / project: lead with the rule/fact, then **Why:** and **How to apply:** lines.>
```

Note: the auto-memory normalizer reshapes this frontmatter on write (stamps `originSessionId`, may nest under `metadata:`, strips any extra keys) — write the three standard fields and don't depend on additional keys surviving.

`MEMORY.md` index format (one line per entry, ≤150 chars):
```
- [Title](file.md) — one-line hook
```

Preserve the project's existing `MEMORY.md` organization: if it's a flat index (as in this project), keep it flat and add the new line in place; only use the four sections **Project** / **Feedback** / **Reference** / **User** when the project's `MEMORY.md` already does. Don't reorganize an existing index, and don't write content directly into MEMORY.md — it's an index only.

### Step 6 — Apply the project-specific extension

Check whether `<cwd>/.claude/sync-mem-project.md` exists. If yes:
1. Read it.
2. Follow its instructions exactly — it declares additional project-specific files to maintain (paper plans, phase write-ups, figure captions, etc.) and any project-specific guards.
3. The extension adds *more* writes, not replacements; it never overrides the generic memory procedure above.

If the file doesn't exist, skip this step silently — the skill still completes successfully on generic memory alone.

### Step 7 — Audit pickup-readiness

Before writing the report, verify that a fresh session reading the saved memory could actually use it. The audit catches the common ways memory rots between save and recall: a path that no longer resolves, a script that errors on import, an index that doesn't list a file you just wrote.

Run these checks on the memory you just touched (new + edited entries from Step 5, **plus any project-extension writes from Step 6**, not the whole library):

1. **Path resolution.** Extract every absolute / project-relative path that appears in the body of the saved entries — script files, parquets, CSVs, figures, directories. For each one, confirm it exists with `ls`. Flag any that don't resolve.
2. **Smoke-import**. For any Python module the memory promises is callable as advertised (e.g. "use `make_figure1.cluster_and_embed`"), do a one-line `python -c "import …; print('OK')"`. Catches stale references after refactors.
3. **Index completeness.** Compare the directory listing of the memory folder against `MEMORY.md` — every entry file (`<type>_*.md`) should appear as exactly one indexed line. Exclude non-entry files: `MEMORY.md` itself, `for_next_session.md`, and session-log infrastructure (`session-log-protocol.md`). Flag genuine orphans.
4. **Carry-over coverage.** Cross-reference the carry-over candidates from Step 3 (and anything you're about to put in the session-log carry-over, or `for_next_session.md` in the fallback) against the in-session task tracker (TodoWrite list, plan, or whatever the session was using). Anything still pending that isn't on the carry-over list is a gap — either close it now (decide + save) or add it.
5. **Spot-check verifiable claims (opportunistic).** If a saved memory cites a number ("2451 MCs", "k=8 default", "7/8 MET-8 in c2") *and that claim might have changed since the memory was last edited*, pick one or two and verify against current data. Skip this check entirely when new memory adds claims that don't overlap with existing files — there's nothing to spot-check.

Output a single line per check: `✅` for clean, `⚠` for issues. If anything fails, surface it in the Step 9 report's **Open / ambiguous** block — don't silently skip.

This audit is lightweight (~30 seconds of bash) and catches the real failure mode: memory entries that look complete at write time but are broken by the time a future session tries to act on them.

### Step 8 — Persist ephemeral carry-over (session-log chain, or fall back to `for_next_session.md`)

After the audit, persist the ephemeral state long-term memory deliberately drops — the *"where were you when you stopped?"* context most valuable to a returning session but not belonging in durable feedback / project / reference files.

**Branch on whether the session-log chain is installed.** Resolve its location by probing, in order, `$CLAUDE_PROJECT_DIR/.claude-memory/session_logs` then `$CLAUDE_PROJECT_DIR/.claude/memory/session_logs` — the same two candidates the SessionStart hook uses. It should live OUTSIDE the memory dir (`store/`) so the frontmatter normalizer cannot strip its `prev`/`next` links — "outside the memory dir" is the invariant, not any particular path. `session-log-protocol.md` is authoritative for this project's actual resolved path. The chain is present if the resolved directory holds at least one `session_*.md`; a missing chain wrongly triggers the fallback, so probe both before concluding.

- **Chain present (preferred):** do NOT write `for_next_session.md`. Instead **append a new session-log** per `session-log-protocol.md` — the chain head IS the carry-over, and the SessionStart hook auto-injects it. The ephemeral sections below (Where I left off · Decisions on probation · Open questions · Working context · Skip-the-rabbit-hole) become the closing sections of that new session-log. Back-link the previous head's `next:`. This supersedes the standalone file — an append-only chain never loses history, whereas an overwritten `for_next_session.md` does.
- **No chain (fallback):** build a fresh `<memory dir>/for_next_session.md` as described below.

**Why this step is last (not first).** Counter-intuitive but deliberate: (a) the audit's findings (broken paths, stale claims, coverage gaps) feed *directly* into "things to fix next session," so writing this file before the audit means missing those; (b) during Step 5 you sometimes promote an "ephemeral" item to long-term memory after deciding it's actually a generalizable lesson — writing the ephemeral file first means retracting; (c) `for_next_session.md` content typically links to long-term memory entries written in Step 5, which need to exist first. Don't reorder.

**"Last" is logical, not physical.** Carry-over candidates can be *identified* throughout the procedure — during Step 1 (diff), Step 3 (plan), Step 5 (when something gets demoted from durable), or Step 7 (audit). Track them mentally or in a draft string as you go. The actual on-disk write happens once, atomically, at Step 8 — that single write incorporates every item captured upstream, including audit findings. Don't write multiple intermediate versions of the file: it leaves the file in inconsistent states if `/sync-mem` fails partway through.

**Fully overwrite the file each invocation.** Never append. Each `/sync-mem` produces a fresh snapshot of "now"; older snapshots are gone. This is what keeps the file from rotting. Even on a clean session with no real carry-over, *still rewrite* the file with a brief "no lingering issues from last session" body — that way `last-synced:` reflects the current date and the next session knows the state is fresh, not stale.

Frontmatter:
```yaml
---
name: For next session — ephemeral carry-over
description: In-flight state from the previous /sync-mem invocation. Overwritten each /sync-mem.
type: ephemeral
lifetime: until-next-sync
last-synced: <today's ISO date — set explicitly, e.g. 2026-05-04>
---
```

The auto-memory loader recognizes `name`, `description`, `type` as standard fields. `lifetime` and `last-synced` are advisory metadata for human readers and the agent reasoning about freshness. Caveat: since `for_next_session.md` lives in `memory/`, the frontmatter normalizer may strip `lifetime`/`last-synced` and reshape `type: ephemeral` — the loader still works, the advisory fields just may not persist. (The chain path avoids this entirely by living outside `memory/`, which is why it's preferred.)

Body sections (omit any that aren't relevant; clean sessions can be very short):
- **Where I left off** — the last in-flight task and *why* it stopped here. One paragraph.
- **Decisions on probation** — recent choices not yet validated by the user, or that might still revert. List form.
- **Open questions / next steps** — things to investigate / decide / build next session. List form.
- **Working context** — env/data state needed to resume cleanly (e.g., "background process X completed", "feature parquets ready at path Y"). List form.
- **Skip-the-rabbit-hole reminders** *(optional)* — issues already solved this session that a returning agent might mistakenly re-investigate. Format: a short bullet pointing at the long-term memory entry that records the resolution. Useful when a fix was non-obvious and worth pointing future-you at.

For a clean / no-carry-over session, body can be a single line: `No lingering issues from last session.`

The Step 7 audit already surfaced the carry-over candidates; this step just structures them into a file the next session can read.

**Pointer in MEMORY.md** *(fallback path only).* The harness loads `MEMORY.md` automatically but not arbitrary files in the memory directory. So in the no-chain fallback, `for_next_session.md` is invisible unless `MEMORY.md` references it. Ensure the very first line of `MEMORY.md` (above the `# Memory Index` heading) reads:

```markdown
> See [for_next_session.md](for_next_session.md) for in-flight context from the previous /sync-mem.
```

Add it once if missing; never duplicate. **When the session-log chain is installed**, this bootstrap line instead points at the chain (set up by `setup-session-log`, e.g. `> Session-log chain: in-flight state lives in session_logs/ …`) — don't add a competing `for_next_session.md` line.

**What goes in / what stays out.** If a finding feels durable enough that the next-session-after-next would still want it, it belongs in long-term memory (Step 5), not here. The ephemeral carry-over (the session-log's closing sections, or `for_next_session.md` in the fallback) is for things whose value evaporates within ~1 session.

### Step 9 — Report

End with a 3-block summary:
```
Saved:
  - <file 1>: <what changed>
  - <file 2>: <what changed>
  - session_logs/session_NNN_<date>.md: appended with N carry-over items
                         (or, no-chain fallback: for_next_session.md rewritten;
                          "no lingering issues" for clean sessions)

Skipped (deliberate):
  - <thing>: <reason>

Open / ambiguous (carry to next session):
  - <thing>
  - [audit] <any path / import / index / coverage issues from Step 7>
```

The "open" section is what makes the next session pick up cleanly — list anything the user wanted to save but couldn't decide on, plus anything you noticed but didn't have authority to persist, plus any audit issues from Step 7. Items in this section should also appear in the session-log carry-over (Step 8; or `for_next_session.md` in the fallback); the report is the conversation-level surfacing, the log/file is the durable carry-over.

## Conventions

- **Specificity beats brevity** in `description:` frontmatter. "User is a data scientist focused on observability" beats "About the user."
- **Convert relative dates** ("Thursday", "next week") to absolute ("2026-03-05") so memories stay interpretable months later.
- **Never duplicate.** Search MEMORY.md first; merge into existing entries rather than creating parallel files.
- **Memory is for things that survive the conversation.** Plans, todos, and in-flight implementation work belong in plan/task tools, not memory.
- **Trust but verify before recommending from memory.** Memory entries can decay — file paths get renamed, flags get removed. Before acting on memory in a future session, sanity-check the current state.

## Failure modes to avoid

- **Don't save what the user just typed verbatim.** Rephrase into the durable lesson; the conversation transcript already exists.
- **Don't pad memory with code snippets.** Reference where the code lives; don't copy it.
- **Don't write a memory entry for something the user is still deciding about.** Wait for the decision, then save the decision + reasoning.
- **Don't skip the index update.** A memory file not in MEMORY.md is invisible to future sessions.
