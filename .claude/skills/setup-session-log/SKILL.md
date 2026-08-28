---
name: setup-session-log
description: Scaffold the append-only session-log continuity system in a project — numbered, dated session logs chained by prev/next links, a SessionStart hook that auto-injects the chain head into every new/resumed session, and the maintenance protocol that keeps the chain growing instead of being overwritten. Invoke once per project (or when a project has no session_logs/ yet). Idempotent: re-running detects an existing chain and only repairs missing pieces.
---

# /setup-session-log — install the session-log continuity layer

## What this installs and why

Most memory systems keep **current state** (recall-optimized, deduplicated) and **raw transcripts** (lossless, verbose). What's missing is the curated middle layer: a compact per-session summary of *what was done* and *what's planned next*, in an **append-only linked chain** so a future session can reconstruct the project's evolution cheaply and audit whether each session did what the previous one asked. The old `for_next_session.md`-gets-overwritten pattern destroys that thread; this chain preserves it.

Four components get installed:
1. **The chain** — `<memory>/session_logs/session_NNN_YYYY-MM-DD.md`, one per session, linked by `prev:`/`next:` frontmatter, each carrying its `session_id`/`transcript` pointer (an index INTO the raw transcript).
2. **The auto-inject hook** — a `SessionStart` hook (`inject_session_log.sh`) that prints the chain head into every new session's context. Deterministic — no reliance on the agent following a pointer, so no "read the log first" reminder is needed in CLAUDE.md. It also carries a built-in staleness check (see below).
3. **The transcript mirror** — a `SessionEnd` + `Stop` hook (`save_transcripts.sh`) that copies the raw `.jsonl` transcripts into `<project>/.claude-transcripts/`. **Without it the chain advertises a drill-down it cannot honour**: every log's `transcript:` field points into `~/.claude/projects/…`, which is *not* durable. In a real devcontainer project a rebuild destroyed ~4 months of transcripts — all 39 logs survived (they live in the project) but every `transcript:` pointer in them died. The chain is the curated layer; this makes the raw layer as durable as the project.
4. **The maintenance protocol** — written into the project so `/sync-mem` (or session end) APPENDS a new log + continuity check rather than overwriting.

> **★ The staleness check has two modes and a third state that announces itself.** If any work file
> was modified after the chain head's own date, the hook prepends a `⚠ SESSION-LOG STALENESS WARNING`
> naming the newest offender — the chain goes stale silently otherwise (work happens without a session
> ever being logged for it) and nothing else catches that.
> - **git mode** — files `git status` already flags (tracked-modified + untracked). Deliberately not
>   `git log -1`: a session can leave real uncommitted work behind and commit dates miss exactly that.
> - **mtime mode** — for projects that are **not git repositories**. ⚠ This case is not hypothetical
>   and the failure is silent: without it the check runs, finds nothing, and reports clean *forever* —
>   a warning system that can never fire, which is worse than none because it reads as coverage.
>   Observed in a devcontainer whose workspace was not a repo: a 13-day unlogged gap went unreported.
> - **unavailable** — if neither works, the hook **says so** in the injected context. An inert check
>   must never be mistaken for a clean bill of health.

## When to use

- Setting up a new long-lived project where you want cross-session continuity.
- A project that has memory (`MEMORY.md`) but no `session_logs/` chain yet.
- Skip for one-off / throwaway sessions — the chain is overhead there (its value is curated history for *evolving* projects).

## Procedure

Run these steps. Everything is idempotent — check-before-write at each step.

### Step 0 — Idempotency check
Resolve `PROJECT` = current working directory. If `session_logs/` already exists with at least one `session_*.md`, the chain is set up: **don't re-scaffold**. Instead verify the hook + protocol are present (Steps 6–9) and report. Stop unless something's missing.

### Step 1 — Resolve the memory dir (`MEM`)
Find the directory that holds `MEMORY.md`:
- If `PROJECT/.claude-memory/MEMORY.md` exists → `MEM = PROJECT/.claude-memory`.
- Else if `PROJECT/.claude/memory/MEMORY.md` exists → `MEM = PROJECT/.claude/memory`.
- Else find the auto-memory dir (the harness names it in the environment, typically `~/.claude/projects/<sanitized-cwd>/memory/`) and make it reachable from the project root — see the box below for **which direction to link**. **This includes the case where no memory exists yet:** create `PROJECT/.claude/memory/store/` with an empty `MEMORY.md` and invert the link now. Deferring it is a false economy — see *Invert up front* below.

The hook resolves `PROJECT/.claude-memory/session_logs` (or `.claude/memory/session_logs`) at runtime, so `MEM` must be reachable under one of those.

> **Never point a link from the project OUT to the auto-memory dir.** The obvious move —
> `PROJECT/.claude-memory -> <auto-memory-dir>` — creates an **absolute host path** inside the project
> tree. It works on the host and **breaks the moment the project is opened anywhere the host path does
> not exist**: a devcontainer/Docker bind-mount, a remote/SSH workspace, a CI checkout, or another
> machine. The editor follows the link into nothing and reports missing files. It also drags the raw
> `.jsonl` transcripts (siblings of `memory/`) into the project tree if you link the *parent*.
>
> **Invert it instead** — real files in the repo, harness dir points at them:
> ```sh
> mkdir -p PROJECT/.claude/memory/store
> cp -a <auto-memory-dir>/. PROJECT/.claude/memory/store/
> mv <auto-memory-dir> <auto-memory-dir>.bak          # rollback until verified
> ln -s PROJECT/.claude/memory/store <auto-memory-dir>
> ```
> The only symlink now lives under `~/.claude/`, where Claude Code (which runs on the **host**)
> resolves it fine; the project tree contains real files that resolve in *every* namespace. Verify by
> reading `<auto-memory-dir>/MEMORY.md` (through the link) and, if containerized,
> `ls` the store from inside the container. Then delete the `.bak`.
> Gitignore `store/` unless the memory is genuinely shareable — it carries machine-specific paths.
>
> **★ Invert up front, even when the auto-memory dir is empty.** It is tempting to skip this on a
> fresh project ("no memory yet, nothing to link") and invert later if it turns out to matter. Don't:
> inverting afterwards means `MEMORY.md`, `for_next_session.md` and `session-log-protocol.md` all move
> down one level into `store/`, so every relative link they carry to the chain has to be rewritten
> `session_logs/` → `../session_logs/`, and any decision already recorded in the chain saying "not
> inverted" is now false and needs correcting. The empty case is exactly when inverting is free.
>
> **★ Why the inversion is the intended end state, not an optional hardening — containers.** When
> Claude Code runs in a container or devcontainer, `~/.claude/` typically lives on the *ephemeral*
> side and the project is the bind-mounted *persistent* workspace. Un-inverted, the memory dir sits
> in the disposable half and a rebuild takes it with it. Inverted, the real files live in the
> persistent workspace and the throwaway half holds only a symlink — so memory survives exactly as
> long as the project does. This is the same reasoning as `save_transcripts.sh` (Step 6), which
> mirrors the raw `.jsonl` transcripts into the workspace for the identical reason: everything the
> harness keeps outside the project is on borrowed time. The pair — inverted memory dir + mirrored
> transcripts — is what makes a containerized project's history durable. Treat "host machine, no
> container" as the special case that merely *tolerates* skipping it, not the default.

### Step 2 — Create the chain directory
`mkdir -p MEM/session_logs`.

> **Frontmatter-normalizer caution.** Some harnesses run an auto-memory frontmatter normalizer that
> rewrites *any* file inside the memory dir to the memory schema — nesting fields under `metadata:`,
> stamping `originSessionId`, and **stripping non-schema keys like `prev`/`next`** (which breaks the
> chain's doubly-linked frontmatter). The log *body* is unaffected either way; only the links matter.
>
> **The safe layout, which sidesteps this without any linking gymnastics:** keep the chain in the
> project at `PROJECT/.claude/memory/session_logs/`, and — if you inverted the link in Step 1 — keep it
> **as a sibling of `store/`, never inside it**:
> ```
> PROJECT/.claude/memory/
>   ├── session_logs/   <- the chain. NOT the memory dir -> normalizer never reads it.
>   └── store/          <- the memory dir the harness symlink points at. Normalized.
> ```
> The normalizer only walks the *memory dir*, so a project-local chain outside it is untouched — and
> unlike the old `<memory-parent>/session_logs/` sibling trick, this needs no `.claude-memory` symlink
> and therefore survives containers and remote workspaces (Step 1). Do not put the chain inside the
> memory dir and then "work around" the normalizer; move the chain out instead.

### Step 3 — Write the first log
Determine **today's date** (pass it in; date functions are unavailable in skill contexts) and the **session_id** (the UUID in your scratchpad path `/tmp/claude-*/<UUID>/scratchpad`, which equals the newest `.jsonl` in the auto-memory's parent `projects/<cwd>/` dir). Write `MEM/session_logs/session_001_<today>.md`:

```markdown
---
session: 001
date: <today>
session_id: <uuid>
transcript: <path>/<uuid>.jsonl
commit: <short sha of HEAD when this log was written, or null outside a repo>
dirty: <true if the tree had uncommitted changes at that moment, else false>
prev: null
next: null
---

# Session 001 — <today>

> First entry in the session-log chain. Installed by /setup-session-log.

## Continuity check (vs previous session)
N/A — chain starts here.

## Done this session
- <what this session actually accomplished, or "set up the session-log system">

## Next session should do
- <the starting agenda for next session>

## Decisions on probation
- <recent choices not yet validated>

## Working context
- <env/data state needed to resume: running processes, key files/paths>

## Skip-the-rabbit-hole reminders
- <issues already resolved that a future session might re-investigate>
```

> **★ `commit:` is what makes the chain auditable against the code.** With it, a future session can
> run `git diff <commit>..HEAD` and see precisely what changed since a given session — the narrative
> and the diff line up, which is the whole promise of an append-only chain sitting next to a repo.
> Without it the log says "reworked the loader" and nothing connects that to a revision.
>
> Semantics: record **HEAD at the moment the log is written**. The log's *own* commit necessarily
> lands afterwards, so `commit:` points at the state the narrative describes, not at the commit
> containing the log — trying to make it self-referential is circular and cannot be done in one
> commit. `dirty: true` records that the tree had uncommitted work at write time, which is the
> honest signal that the narrative describes more than the repo does.
>
> Outside a repo write `commit: null` — and treat that as a prompt to `git init` (see README), not
> as a neutral default. Don't retrofit `commit:` onto existing logs by rewriting history; start the
> convention at the next log.

### Step 4 — Pointer file
Write `MEM/for_next_session.md` as a thin pointer (NOT carry-over content):

```markdown
---
name: For next session — pointer to the session-log chain
description: Stable entry point. Points to the current head of the append-only session-log chain.
type: ephemeral
lifetime: persistent-pointer
---

> **Read the chain head:** [`session_logs/session_001_<today>.md`](session_logs/session_001_<today>.md)

In-flight context lives in the **session-log chain** under `session_logs/` (append-only, numbered, dated, prev/next-linked). At session end, APPEND a new log per `session-log-protocol.md` — do not overwrite this file. **Current chain head:** `session_001_<today>.md`
```

### Step 5 — MEMORY.md bootstrap line
Ensure the FIRST line of `MEM/MEMORY.md` (above any heading) is:

```markdown
> See [for_next_session.md](for_next_session.md) — pointer to the **session-log chain** (`session_logs/`). Each session appends a numbered, dated, back-linked log (never overwritten); the chain head is auto-injected at session start.
```

Add it if missing; never duplicate.

### Step 6 — Install the hook scripts
`mkdir -p PROJECT/.claude/hooks/`, then **symlink** both bundled scripts into it (relative links, so
they survive the project being moved or mounted at a different path):

```sh
cd PROJECT/.claude/hooks
ln -sf ../skills/setup-session-log/inject_session_log.sh .   # SessionStart injector + staleness check
ln -sf ../skills/setup-session-log/save_transcripts.sh   .   # transcript mirror
chmod +x ../skills/setup-session-log/*.sh                    # the real files carry the bit
```

> **★ Symlink, don't copy — otherwise the hooks silently fork from the skill.** Copying leaves two
> independent versions of each script. They are identical on install day and drift the moment the
> skill is updated: re-copying `.claude/skills/` from upstream updates the *skill* while
> `.claude/hooks/` keeps running the old code, with nothing reporting the mismatch — the exact
> failure mode that stops upstream fixes from reaching people. A symlink makes "update the skill"
> and "update the running hook" the same action. If a project genuinely needs a divergent hook,
> replace the link with a real file deliberately, so the fork is visible in `ls -l`.
>
> Verify with `ls -l PROJECT/.claude/hooks/` (expect `-> ../skills/...`) and by pipe-testing through
> the link in Step 9. If the skill is installed at *user* scope (`~/.claude/skills/`) rather than in
> the project, a relative link cannot reach it — copy in that case and note the drift risk in the
> session log.

Both scripts are portable: they resolve the project and memory dirs at runtime and use python3, not jq.

Then **gitignore the mirror** — add `.claude-transcripts/` to `PROJECT/.gitignore` (create it if absent). Transcripts are large (tens of MB per long session), grow without bound, and contain the full verbatim conversation. Their job is to survive the harness directory, not to be committed. ⚠ Tell the user the directory needs periodic pruning; **nothing rotates it**. The `Stop` hook
refreshes the mirror after every assistant turn, so a single long session's file grows to tens of MB
and the directory only ever grows. Two things follow: agree a retention rule at install time (e.g.
delete `.jsonl` files older than N days), and treat the directory as *sensitive* — it is the full
verbatim conversation, including anything pasted into it. Gitignoring keeps it out of the repo but
not out of a zip, a backup, or an image built from the workspace.

### Step 7 — Register the hooks
**Read** `PROJECT/.claude/settings.json` first (create `{}` if missing). **Merge** (preserve all existing keys, especially `mcpServers`/`permissions`) these three registrations into `hooks`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "<PROJECT>/.claude/hooks/inject_session_log.sh", "timeout": 10, "statusMessage": "Loading session-log chain head..." } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "<PROJECT>/.claude/hooks/save_transcripts.sh", "timeout": 15, "statusMessage": "Mirroring transcripts..." } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "<PROJECT>/.claude/hooks/save_transcripts.sh", "timeout": 15, "statusMessage": "Mirroring transcripts..." } ] }
    ]
  }
}
```

Use the absolute project path in `command`. If an event already has a hook, **add alongside — don't replace**. Validate the merged file parses (`python3 -c "import json;json.load(open('.claude/settings.json'))"` — jq may be absent).

> **Why `Stop` as well as `SessionEnd`.** `SessionEnd` captures a cleanly-finished session, but the
> failure this protects against — an environment destroyed out from under you — is exactly the case
> where `SessionEnd` never fires. `Stop` runs after each assistant turn, so the mirror stays current
> to within one turn. It is cheap: the script copies only when the source is strictly newer, so a
> normal turn does a `stat` and nothing else. If per-turn latency is ever a concern, drop to
> `SessionEnd` only and accept losing the final session.

### Step 8 — Write the maintenance protocol
Write `MEM/session-log-protocol.md` with the append rules below, and (if the project has a `/sync-mem` extension at `.claude/sync-mem-project.md`) add a one-line pointer to it there. Protocol content:

```markdown
# Session-log chain protocol

At the end of a session (e.g. /sync-mem, or before stepping away):
1. Find the current head = highest-numbered `session_logs/session_NNN_*.md`.
2. **Continuity check:** read the head's "Next session should do"; the new log opens with a section marking each item DONE / DEFERRED / DROPPED (with why).
3. Create `session_{NNN+1}_<today>.md` (prev: = old head, next: null). Sections: Continuity check, Done this session, Next session should do, Decisions on probation, Working context, Skip-the-rabbit-hole. Record `session_id`/`transcript` in frontmatter, plus `commit:` (short HEAD sha at write time) and `dirty:` so the entry is anchored to a revision.
4. Back-link: set the previous head's `next:` to the new file.
5. Refresh `for_next_session.md`'s pointer to the new head.
NEVER overwrite an existing numbered log. Pass today's date + session_id in explicitly.
6. **Commit the log with the work it describes.** The chain is tracked (unlike `store/` and
   `.claude-transcripts/`), so an uncommitted log is invisible to every clone and to the next
   machine. `/sync-mem`'s audit reports this; it does not act on it — committing stays the user's
   call.
```

### Step 9 — Verify
Pipe-test the installed hook and confirm valid JSON with content:
`echo '{}' | PROJECT/.claude/hooks/inject_session_log.sh | python3 -m json.tool` — expect `hookSpecificOutput.additionalContext` containing the first log. On a fresh install this log is brand new, so the staleness check should stay silent (no `⚠` line); it only fires once the working tree moves ahead of the head's date.

### Step 10 — Report
Tell the user what was created. Note: the `SessionStart` hook only fires when a session *begins*, so it takes effect on the **next** session start (can't be tested in-turn). Point them at `/hooks` to confirm registration or disable it. Do **not** add a "read the session log" reminder to CLAUDE.md — the hook makes it deterministic.

## Notes
- Do not switch the hook to `jq` — many environments lack it; the bundled script uses `python3`.
- Logs are loaded by the hook, not the auto-memory loader, so they don't bloat `MEMORY.md`.
- For distribution to other people/machines, wrap this skill + the hook in a plugin (a plugin ships the hook so it activates on install; a skill must be invoked to wire it).
