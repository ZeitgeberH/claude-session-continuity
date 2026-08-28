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

## Instruction for installation

Clone this repo once, then pick the mode that matches your situation:

```sh
git clone https://github.com/ZeitgeberH/agentSkills_mem
```

### New project — starting from nothing

```sh
./agentSkills_mem/install.sh --create ~/new-project
```

Takes a bare path and leaves you a committed git repository with the skills installed, the hooks
registered, and the memory dir already inverted. It makes the directory, runs `git init`, installs,
then makes the initial commit — so the first session log has a real HEAD to anchor its `commit:`
field to instead of `null`.

This mode handles `git init` for you, which matters more than it looks:

- **The staleness check gets its good mode.** The `SessionStart` hook warns when work happened
  without a session log being written for it, and it has two implementations: `git` mode asks
  `git status --porcelain` (precise, instant), while `mtime` mode walks the tree with `find` and
  needs a hand-tuned `.claude/hooks/staleness-prune.txt` on any project with data or vendor
  directories.
- **The chain becomes auditable.** Each log's "Done this session" sits next to real commits, which
  is the property the prev/next design exists to give you.

Two deliberate limits:

- **`--create` is a flag, not automatic.** Silently creating a mistyped path would install into the
  wrong directory and report success. Without the flag a missing directory is an error that names
  the flag. It also refuses when the *parent* doesn't exist — it scaffolds a project, not a whole
  path.
- **It is the only mode that commits**, because it is the only mode where the repo contains nothing
  but what the installer just put there. If the commit fails (no `user.name` / `user.email`) it says
  so rather than continuing silently.

### Existing project — adding to work you already have

```sh
./agentSkills_mem/install.sh ~/existing-project
```

The directory must already exist. It does **not** need a `.claude/` directory — that gets created.
`settings.json` is merged, not overwritten: existing keys (`permissions`, `mcpServers`, other hooks)
are preserved, and re-running adds nothing twice.

**This mode never commits.** Your tree may hold unrelated in-flight work, and sweeping that into a
commit nobody asked for is exactly the surprise this tool refuses to spring — the same rule
`/sync-mem` follows when it reports git state but won't act on it. Commit the install yourself,
alongside whatever else is in flight.

This is the common case: the payoff here is long-horizon work, and long-horizon work usually already
has a repo. (It's also why this repo isn't a GitHub template — a template serves only brand-new
projects, hands the clone this repo's README and identity, and leaves no path for upstream fixes to
arrive.)

**If it isn't a git repository yet,** run `git init` and commit soon after — between `init` and the
first commit every file is untracked, which needlessly widens the staleness check's candidate set.
Initializing later is not fatal: the hook probes for a repo at runtime every session and upgrades
itself. Commit the chain (`session_logs/`) — it's the shareable layer — and gitignore
`.claude-transcripts/` and `.claude/memory/store/`, which carry machine-specific paths and, in the
transcripts' case, the full verbatim conversation.

### What both modes do

Copy both skills, symlink the hooks into `.claude/hooks/`, merge `settings.json`, seed `.gitignore`,
and relocate the project's memory dir into the project (below). Both are re-runnable, and
`--dry-run` prints the plan without touching anything.

#### Two questions it asks

On a terminal the installer asks about the two choices that are genuinely yours. Piped or redirected
— CI, a script — it asks nothing and takes the defaults, so it never blocks an unattended run. Any
flag you pass settles that question and suppresses its prompt; `-y` takes every default silently.

| Question | Default | Flag |
|---|---|---|
| Where should this project's memory live — the project folder, or Claude's home folder? | **project folder** | `--no-invert-memory` |
| Delete session transcripts older than N days? | **keep forever** | `--retention-days N` |

**Memory location.** Between sessions Claude keeps notes about a project — decisions, context, what
it learned. By default that store lives in Claude's own home folder (`~/.claude`), away from your
project: it doesn't travel when you move, copy or share the project, and in a container a rebuild
wipes it. Choosing the project folder puts the real files in the project and leaves a symlink behind
in `~/.claude`, so the notes live and die with the project. That's the default, and in a container
it's close to required — see the box below for exactly what gets moved.

**Transcripts.** A full transcript of every session is copied into `.claude-transcripts/` so it
survives Claude's home folder being cleared. Nothing removes them, so the folder grows for the life
of the project and holds the complete text of every conversation. Keeping them forever is the
default — deleting someone's history is not a sensible thing to do by default — but you can name a
retention period, and the 3 most recent are always kept whatever their age. Choose rotation and the
installer wires a `prune_transcripts.sh` hook and writes the knobs to
`.claude/hooks/transcript-retention.conf`; decline and no deletion code is installed at all.

Neither scaffolds the chain itself: the first log needs today's date, the session UUID, and a real
summary of the session, which is agent work. `/setup-session-log` finishes that, and is idempotent —
it picks up from whatever the installer left.

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

#### After it runs — the session boundary, and why it isn't optional

`install.sh` runs in a plain shell, before Claude Code is involved at all. The installer cannot do
this part: **skills and hooks are registered when a session starts**, not when their files appear on
disk. So finish the install like this, exactly as `install.sh` prints on exit:

```
./install.sh [--create] ~/proj   # skills copied, hooks symlinked + registered, memory inverted
        ↓
cd ~/proj && claude              # skills are invocable in this session; hooks are live
        ↓
/setup-session-log               # scaffolds the chain; idempotent, picks up from the installer
        ↓
start one more session           # from here the chain head is auto-injected at every start
        ↓
…work…  →  /sync-mem             # appends the next log at each checkpoint
```

If you ran the installer from *inside* a session already open on that project, restart that session
instead of starting one — same boundary, different starting point.

Skipping that boundary corrupts nothing, but nothing you installed actually *runs*: invoking a
just-copied skill in the same session fails with `Unknown skill` — that is this rule showing up, not
a broken install.

The third step earns its place for one specific reason: the first session starts *before* the chain
exists, so the `SessionStart` hook fires, finds no `session_logs/`, and exits silently with nothing
to inject. Only from the next session does the chain head actually reach the agent's context.

If you genuinely must set up inside one session, read each `SKILL.md` and follow its procedure by
hand, and treat the next session start as the real acceptance test.

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
