# agentSkills_mem

This design works for the same reason biological memory is shaped this way: no system with bounded
attention — human or agent — can keep everything active at once, so it needs a small "working"
layer plus a consolidation process that decides what's worth carrying forward, stamped with enough
provenance to know when to trust it and when to double-check. Neither the brain nor this pair of
skills got there by aesthetic choice — it's what bounded-memory systems converge on when the
problem is "remember what matters, forget cheaply, and keep receipts."

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

### One command: `install.sh`

```sh
git clone https://github.com/ZeitgeberH/agentSkills_mem
./agentSkills_mem/install.sh ~/path/to/your-project
```

Copies both skills, symlinks the hooks, merges `settings.json` (preserving existing keys), seeds
`.gitignore`, and relocates the project's memory dir into the project (below). Re-runnable, and
`--dry-run` shows the plan without touching anything. It deliberately stops short of scaffolding the
chain — the first log needs today's date, the session UUID, and a real summary, which is agent work
— so finish with `/setup-session-log`.

> **⚠ What it writes outside the target project — read before running.**
> By default the installer also does this, and it is the *only* thing it touches outside `TARGET`:
>
> ```
> ~/.claude/projects/<sanitized-target>/memory   ->   TARGET/.claude/memory/store/
> ```
>
> The directory is moved into the project and replaced with a symlink pointing at it. Any memory
> already there is carried across first; the original is kept as `.bak` until the new location is
> verified by reading `MEMORY.md` back through the link, then removed. A failed verification rolls
> back automatically.
>
> **Why this is the default rather than a flag.** That path holds *this project's own memory* and
> nothing else — so the move relocates data that already belongs to the project you named, it does
> not reach into unrelated state. And the two mistakes are not symmetric: skipping it when you
> should not means memory dies with the next container rebuild (`~/.claude/` is the ephemeral half,
> the project is the persistent bind-mount), or, on a host, a later migration that moves three files
> into `store/` and rewrites every relative link `session_logs/` → `../session_logs/`. Doing it when
> you did not need to leaves a symlink you can undo in one command.
>
> Skip it with **`--no-invert-memory`**.
>
> One caveat the installer also prints: the harness path above is derived from the target path with
> `/` replaced by `-`. If you later open the project by a *different* path — another mount point, a
> symlinked route — Claude Code computes a different directory and will not see this memory.

#### After it runs — two restarts, and why they aren't optional

The installer cannot do this part: **skills and hooks are registered when a session starts**, not
when their files appear on disk. So finish the install like this, exactly as `install.sh` prints on
exit:

```
./install.sh ~/proj      # skills copied, hooks symlinked + registered, memory inverted
        ↓
RESTART the session      # the skills become invocable here
        ↓
/setup-session-log       # scaffolds the chain; idempotent, picks up from what install.sh left
        ↓
RESTART the session      # the SessionStart hook fires from here on; chain head auto-injects
        ↓
…work…  →  /sync-mem     # appends the next log at each checkpoint
```

Skipping the restarts corrupts nothing, but nothing you installed actually *runs*: the chain head is
never injected and the transcript mirror never fires, so the install stays untested while looking
complete. Invoking a just-copied skill in the same session fails with `Unknown skill` — that is this
rule showing up, not a broken install.

If you genuinely must set up inside one session, read each `SKILL.md` and follow its procedure by
hand, and treat the next session start as the real acceptance test.

This works on an **existing** project, which is the common case: the payoff here is long-horizon
work, and long-horizon work usually already has a repo. (That's also why this repo isn't a GitHub
template — a template only serves brand-new projects, gives the clone this repo's README and
identity, and leaves no path for upstream fixes to arrive.)

### `git init` first

Initialize the repository **before** scaffolding the chain. Two concrete payoffs:

- **The staleness check gets its good mode.** The `SessionStart` hook warns when work happened
  without a session log being written for it, and it has two implementations: `git` mode asks
  `git status --porcelain` (precise, instant), while `mtime` mode walks the tree with `find` and
  needs a hand-tuned `.claude/hooks/staleness-prune.txt` on any project with data or vendor
  directories. Not fatal to init later — the hook probes for a repo at runtime every session and
  upgrades itself — but you get the cheap mode from day one. If you do init later, commit soon
  after: between `init` and the first commit every file is untracked, which needlessly widens
  git mode's candidate set.
- **The chain becomes auditable.** Each log's "Done this session" sits next to real commits, which
  is the property the prev/next design exists to give you.

Commit the chain (`session_logs/`) — it's the shareable layer. Gitignore
`.claude-transcripts/` and `.claude/memory/store/`: both carry machine-specific paths, and
transcripts are the full verbatim conversation with no rotation.

### Running in a container? The memory-dir inversion is not optional

`/setup-session-log` points the harness memory dir at the project
(`~/.claude/projects/<cwd>/memory` becomes a symlink into `PROJECT/.claude/memory/store/`) rather
than the reverse. On a plain host that's a portability nicety. In a container it's the whole ball
game: `~/.claude/` sits on the **ephemeral** side while the project is the bind-mounted
**persistent workspace**, so an un-inverted memory dir is destroyed by the next rebuild. Inverted,
the real files live in the workspace and only a symlink is disposable.

This is the same reasoning behind the transcript mirror, which copies the raw `.jsonl` files into
the workspace for the identical reason — a real rebuild once destroyed ~4 months of them. Together
they're what makes a containerized project's history durable. `SKILL.md` Step 1 has the mechanics,
including why the link must never run the other way.

## License

MIT — see [LICENSE](LICENSE).
