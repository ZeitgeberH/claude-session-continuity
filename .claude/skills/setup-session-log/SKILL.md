---
name: setup-session-log
description: Scaffold the append-only session-log continuity system in a project — numbered, dated session logs chained by prev/next links, a SessionStart hook that auto-injects the chain head into every new/resumed session, and the maintenance protocol that keeps the chain growing instead of being overwritten. Invoke once per project (or when a project has no session_logs/ yet). Idempotent: re-running detects an existing chain and only repairs missing pieces.
---

# /setup-session-log — install the session-log continuity layer

## What this installs and why

Most memory systems keep **current state** (recall-optimized, deduplicated) and **raw transcripts** (lossless, verbose). What's missing is the curated middle layer: a compact per-session summary of *what was done* and *what's planned next*, in an **append-only linked chain** so a future session can reconstruct the project's evolution cheaply and audit whether each session did what the previous one asked. The old `for_next_session.md`-gets-overwritten pattern destroys that thread; this chain preserves it.

Four components get installed:
1. **The chain** — `<memory>/session_logs/session_NNN_YYYY-MM-DD.md`, one per session, linked by `prev:`/`next:` frontmatter, each carrying its `session_id`/`transcript` pointer (an index INTO the raw transcript).
2. **The auto-inject hook** — a `SessionStart` hook (`inject_session_log.sh`) that prints the chain head into every new session's context. Deterministic — no reliance on the agent following a pointer, so no "read the log first" reminder is needed in CLAUDE.md. It also carries a built-in staleness check (see below), and a bootstrap notice: when the skills and hooks are installed but no chain exists yet — the state `install.sh` leaves behind — it injects an instruction to run `/setup-session-log`, so the user never has to remember a follow-up command. That notice fires only while the chain is missing.
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
Resolve `PROJECT` = current working directory, then classify which of **three** states it is in. Say which one you found when you report — the state is the useful part of the answer, not an aside.

| State | How to tell | What to do |
|---|---|---|
| **Fresh** | no `.claude/hooks/inject_session_log.sh`, no `session_logs/` | Run the whole procedure, Steps 1–10. |
| **Installer-prepared** | hooks + `settings.json` registrations present, but `session_logs/` missing or empty | Run **Steps 1–5 and 8 only** — the chain and the protocol. Steps 6–7 are already done: verify them, don't redo them. |
| **Already set up** | `session_logs/` holds at least one `session_*.md` | **Don't re-scaffold.** Verify the hook + protocol (Steps 6–9) and report. Stop unless something is missing. |

> **★ "Installer-prepared" is the expected result of `install.sh`, not a broken install — say so.**
> `install.sh` deliberately does the mechanical half (memory inversion, hook symlinks,
> `settings.json`, `.gitignore`) and stops, because the first log needs today's date, the session
> UUID, and a real summary of the session — agent work a shell script cannot do. Finishing that half
> is exactly what this skill is being invoked for.
>
> So **do not report it as a "partial install", a problem, or something you repaired.** That wording
> has been observed in the wild and reads as a diagnosis of breakage when nothing is wrong; it
> makes a user go looking for a fault that does not exist. Report it as the handoff completing —
> name what the installer had already done, and what you added. Reserve repair language for a state
> that genuinely is inconsistent (for example hooks registered in `settings.json` but the scripts
> missing from `.claude/hooks/`, which is a real fault worth flagging).
>
> Distinguish the two by *evidence*, not assumption: an installer-prepared project has the hook
> symlinks and the `settings.json` entries but no `session_*.md`. Check both before concluding.

### Step 1 — Resolve two locations: the chain, and the memory dir
These are different things and must not be conflated. One is fixed; the other is the user's choice.

**`CHAIN` is always inside the project** — `PROJECT/.claude/memory/session_logs/` (or
`PROJECT/.claude-memory/session_logs/` if that layout already exists). The `SessionStart` hook probes
**only those two paths**, so a chain written anywhere else is invisible no matter how correct it
looks. This holds regardless of where memory lives.

**`MEM` is wherever `MEMORY.md` lives**, and may legitimately sit *outside* the project:
- `PROJECT/.claude-memory/MEMORY.md` exists → `MEM = PROJECT/.claude-memory`.
- `PROJECT/.claude/memory/store/MEMORY.md` (or `.../memory/MEMORY.md`) exists → that directory.
- Otherwise → the harness auto-memory dir (typically `~/.claude/projects/<sanitized-cwd>/memory/`),
  **used as it is**. If it doesn't exist yet, create it.

> **★ Never relocate the memory dir as a side effect of this skill.** If the harness memory dir is
> not already a symlink into the project, that is a decision, not an oversight: `install.sh` asks
> where memory should live and `--no-invert-memory` declines the move. Inverting it here because this
> skill prefers a layout would silently override an answer the user was explicitly asked for, and
> would move their memory without them asking — the same class of surprise as committing someone's
> in-flight work.
>
> So: use whatever `MEM` resolves to and put the chain in the project either way. If relocating looks
> worthwhile, *say so* and point at `install.sh --invert-memory`; don't do it unasked.
>
> When it *has* been inverted, the box below explains why the link runs harness → project and never
> the reverse — worth knowing when verifying an existing install.

> **★ A symlink existing is not proof the memory dir works — resolve it.** If the harness memory dir
> is already a symlink, test that it *resolves* (`[ -f "$auto/MEMORY.md" ]`), not merely that it is a
> link. A dangling link is a real, observed state: `store/` is gitignored, so `git clean -xdf`, a
> fresh clone, or deleting and recreating the project leaves the link in `~/.claude/` pointing at a
> target that no longer exists. The failure is silent — the harness memory dir resolves to nothing
> and memory quietly stops working, while every check that only asks "is it a symlink?" reports
> success. If it dangles, recreate the target (`store/` plus an empty `MEMORY.md`) and say that you
> repaired it, noting any memory it held is gone. If it resolves somewhere *other* than this
> project's `store/`, leave it alone and tell the user: that is a collision, not a fault to
> overwrite.

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
`mkdir -p CHAIN` — that is `PROJECT/.claude/memory/session_logs/`, from Step 1. **Not** `MEM/session_logs`: when memory lives in the harness directory those are different paths, and only the project one is visible to the hook.

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
`mkdir -p PROJECT/.claude/hooks/`, then **symlink** the two required scripts into it (relative links,
so they survive the project being moved or mounted at a different path). A third,
`prune_transcripts.sh`, is **opt-in** — wire it only if the user asks for transcript rotation:

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
> **Transcript rotation is opt-in, and off by default.** `save_transcripts.sh` only ever adds, so
> `.claude-transcripts/` grows for the life of the project. `prune_transcripts.sh` ships alongside it
> and deletes mirrored `.jsonl` older than `RETENTION_DAYS`, always keeping the `KEEP_NEWEST` most
> recent whatever their age, logging to `PRUNE.log`, and touching the mirror only — never the
> harness's own transcripts. Wire it (symlink + a `SessionEnd` registration + a
> `.claude/hooks/transcript-retention.conf` carrying the two knobs) **only when the user chooses a
> retention period.** Ask; don't assume. Deleting somebody's conversation history is not a sensible
> default, and a project that never enables rotation should carry no deletion code on a hook path at
> all. `install.sh` asks this question at install time.
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
      { "hooks": [ { "type": "command", "command": "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/inject_session_log.sh", "timeout": 10, "statusMessage": "Loading session-log chain head..." } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/save_transcripts.sh", "timeout": 15, "statusMessage": "Mirroring transcripts..." } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/save_transcripts.sh", "timeout": 15, "statusMessage": "Mirroring transcripts..." } ] }
    ]
  }
}
```

**Use `${CLAUDE_PROJECT_DIR:-.}`, never a hardcoded absolute path.** If an event already has a hook, **add alongside — don't replace**.

> **★ An absolute path in `settings.json` is a portability bug, and `settings.json` is committed.**
> Hardcoding `/home/you/proj/.claude/hooks/…` bakes one machine's layout into a tracked file: clone
> the project anywhere else — another machine, a CI checkout, a container whose bind-mount lands at
> `/workspace` instead — and every hook silently fails to fire. Silently is the operative word;
> a missing hook produces no error, just a session that quietly starts without its chain head. This
> is the same class of mistake as the outward `.claude-memory` symlink in Step 1, and it is
> especially perverse here, because the container case is exactly the one this system exists to
> serve.
>
> `CLAUDE_PROJECT_DIR` is exported into the hook environment — the bundled scripts already rely on
> it (`proj="${CLAUDE_PROJECT_DIR:-$PWD}"`). The `:-.` fallback costs nothing and degrades to a
> project-relative path if the variable is ever absent.
>
> Hook commands are run through a shell, so the expansion happens there, not in the JSON. Confirm on
> the next session start rather than assuming: if the chain head is injected, it expanded. Validate the merged file parses (`python3 -c "import json;json.load(open('.claude/settings.json'))"` — jq may be absent).

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
2. **One session, one log — check this FIRST.** Compare the head's `session_id:` with the current session's UUID (from the scratchpad path `/tmp/claude-*/<UUID>/scratchpad`).
   - **Different** → append a new log, steps 3-6 below.
   - **Same** → this session already has a log (a second `/sync-mem`, or `/setup-session-log` ran earlier in this same session). **Update that log in place** — keep its number, date, `session_id`, `prev`/`next`; rewrite its body to cover the session as a whole so far; refresh `commit:`/`dirty:`. Then stop: no new file, no back-link, no pointer change. This is the normal case right after a fresh install, not a deviation.
   - **Head has no `session_id`** → append. Never rewrite a log you cannot prove is yours.
   Two logs for one session share a `session_id`/`transcript`, make the second log's continuity check vacuous (it would check this session's own next-steps against itself), and stop the chain length from matching the session count.
3. **Continuity check:** read the head's "Next session should do"; the new log opens with a section marking each item DONE / DEFERRED / DROPPED (with why).
4. Create `session_{NNN+1}_<today>.md` (prev: = old head, next: null). Sections: Continuity check, Done this session, Next session should do, Decisions on probation, Working context, Skip-the-rabbit-hole. Record `session_id`/`transcript` in frontmatter, plus `commit:` (short HEAD sha at write time) and `dirty:` so the entry is anchored to a revision.
5. Back-link: set the previous head's `next:` to the new file.
6. Refresh `for_next_session.md`'s pointer to the new head.
7. **Commit the log with the work it describes.** The chain is tracked (unlike `store/` and
   `.claude-transcripts/`), so an uncommitted log is invisible to every clone and to the next
   machine. Commit it yourself **only if `git status --porcelain` lists nothing but the files you
   just wrote** — then it can sweep up nothing unrelated. If anything else is uncommitted, report
   and leave it: committing someone's in-flight work is not yours to do.

NEVER overwrite a *previous* session's log — that is history. Your own session's log is not history yet; refining it is step 2 above. Pass today's date + session_id in explicitly.

```

### Step 9 — Verify, then commit if the tree is otherwise clean
Pipe-test the installed hook and confirm valid JSON with content:
`echo '{}' | PROJECT/.claude/hooks/inject_session_log.sh | python3 -m json.tool` — expect `hookSpecificOutput.additionalContext` containing the first log. On a fresh install this log is brand new, so the staleness check should stay silent (no `⚠` line); it only fires once the working tree moves ahead of the head's date.

**Then commit — but only if you can prove it sweeps up nothing else.** Compare `git status --porcelain` against the list of files you just wrote. Commit automatically **only when those two sets are equal**; otherwise stage nothing and tell the user what is uncommitted.

> **★ Why that specific test, rather than "is this a new project".** The thing that makes an
> automatic commit unsafe is not the age of the repo — it is unrelated work in the tree getting
> swept into a commit nobody asked for. "The only changes are the files I just created" tests that
> directly, needs no guessing about project age, and is exactly true in the case this usually runs
> in: a project `install.sh --create` made moments ago, whose only uncommitted files are the chain
> you just wrote. It also stays correct in an existing repo that happens to be clean, and correctly
> refuses in one that is not.
>
> Message: `Add session-log chain (session_001)`. Report the short sha. If the commit fails — no
> `user.name`/`user.email`, a hook rejecting it — say so and carry on; a missing commit is a
> nuisance, a silent failure is a bug.
>
> This is not in tension with `/sync-mem` refusing to commit: the same rule, applied where the tree
> is usually dirty, declines almost every time.

### Step 10 — Report
Open by naming the Step 0 state you found, then say what was created. For an **installer-prepared**
project that means: what `install.sh` had already put in place, and what you added on top — framed
as the handoff finishing, never as a partial or repaired install. For a **fresh** project, just
report what was created. Note: the `SessionStart` hook only fires when a session *begins*, so it takes effect on the **next** session start (can't be tested in-turn). Point them at `/hooks` to confirm registration or disable it. Do **not** add a "read the session log" reminder to CLAUDE.md — the hook makes it deterministic.

## Notes
- Do not switch the hook to `jq` — many environments lack it; the bundled script uses `python3`.
- Logs are loaded by the hook, not the auto-memory loader, so they don't bloat `MEMORY.md`.
- For distribution to other people/machines, wrap this skill + the hook in a plugin (a plugin ships the hook so it activates on install; a skill must be invoked to wire it).
