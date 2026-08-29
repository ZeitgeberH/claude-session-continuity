# claude-session-continuity

> Cross-session continuity for Claude Code projects: an append-only chain of session logs, loaded
> automatically at every session start, plus a skill that promotes what a session learned into
> durable memory before it scrolls away.

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
"read the log first" reminder. Each entry records the session id, its transcript, and the commit
the work sat at, so a later session can run `git diff <commit>..HEAD` and line the narrative up
against the code.

Setting it up also installs the machinery that keeps the chain honest and durable:

- **A staleness check** in the same hook — warns when the working tree moved on after the chain
  head's date, instead of silently trusting a log that may be out of date. Uses `git status` in a
  repo, file mtimes otherwise, and *says so* when it can do neither, since a check that can never
  fire is worse than none. Portable: GNU `stat` first, BSD/macOS `stat -f` fallback.
- **A bootstrap notice**, also in that hook: if the skills are installed but no chain exists yet,
  it tells the agent to create one. That is what makes `install.sh` the only setup step you perform.
- **A transcript mirror** (`SessionEnd` + `Stop`) copying the raw `.jsonl` into the project, so the
  `transcript:` pointer in every log still resolves after the harness directory is cleared. Optional
  retention is available and off by default.
- **The memory relocation** — the project's memory store moves into the project, with the harness
  directory left as a symlink to it, so memory travels with the project and survives a container
  rebuild.

## `sync-mem`

Persists a session's durable findings — corrections, decisions, project state — into memory and
the session-log chain, at natural checkpoints. Covers general memory plus any project-specific
extension declared in `.claude/sync-mem-project.md`.

**Nothing creates that file for you, and an absent one is the normal state.** A project that has
produced no records has nothing to declare. Instead, when `/sync-mem` finds no extension and notices
that the session changed a result whose *record* lives elsewhere — a plan, a caption, a results
write-up — it says so and offers to start one. It never creates it unasked, and it says *"no project
extension (none needed yet)"* rather than skipping in silence, since silence is why the feature went
undiscovered. The installer stays out of it for the same reason it does not write the first session
log: both need a session's judgement, which a plain shell does not have.

What belongs in it is three things, each depending on the project's shape and so unable to live
anywhere else: the files that **carry results** and therefore fall behind findings silently (a plan,
a spec, a caption, a results write-up); the **guards** that decide whether a save is admissible here;
and the state that **dies quietly** unless the session log names it. A brand-new project's extension
is correctly empty — nothing has produced results yet.

The stub is a skeleton and a pointer. The reasoning behind it — an admission test for what belongs
here versus in `CLAUDE.md`, memory, or the chain; worked entries; and the four rules that keep an
extension from growing into a second, unmaintained memory store — lives in
`skills/sync-mem/project-extension-guide.md`, so it travels with the skill and improves for every
project at once instead of being frozen into each one at install time.

Before it reports, it audits what it just saved: that every path a memory entry cites still
resolves, that nothing written is missing from the index, and that the git state is what you think
it is — uncommitted work, unpushed commits, or a chain head that never got committed and so is
invisible to every clone. It reports that state; it never commits or pushes on your behalf.

## Installation

> ## ⚠️ Read this first
>
> The installer turns on **[two things by default](#two-things-it-does-by-default)** that you should
> agree to knowingly:
>
> 1. **It moves your project's memory directory** into the project and leaves a symlink behind in
>    `~/.claude/` — relying on a path Claude Code does not document as stable. Opt out with
>    `--no-invert-memory`.
> 2. **It copies full verbatim transcripts** of every session into `.claude-transcripts/` in your
>    project, and never deletes them unless you ask. Gitignored, but not invisible.
>
> Both exist because anything under `~/.claude/` is destroyed by a container rebuild. Both are worth
> it for a long-lived project — but read what they do before running, especially on a work machine.

Clone this repo once, then pick the mode that matches your situation:

```sh
git clone https://github.com/ZeitgeberH/claude-session-continuity
```

### New project

```sh
./claude-session-continuity/install.sh --create ~/new-project
```

**That is the whole setup — you are ready to work.** Start Claude Code in the project and use it as
you normally would; your first session quietly creates and commits the session-log chain in the
background before getting on with what you actually came to do.

#### What it asks

Three questions. Press Enter through them to take the defaults — memory in the project folder,
transcripts copied in and kept forever. Both are explained under [What it asks you](#what-it-asks-you).

```
  Where should this project's memory live?
    1) In the project folder   — travels with the project, survives a rebuild
    2) In Claude's home folder — leave it where Claude puts it
  Choice [1]:

  Keep a copy of session transcripts in the project?
    1) Yes, copy them into the project
    2) No, leave them in Claude's home folder only
  Choice [1]:

  Delete old session transcripts?
  Days [keep forever]:
```

#### What it prints

Each step as it happens, roughly this:

```
  created project directory ✅
  git: initialized ✅
  skill setup-session-log ✅
  skill sync-mem ✅
  hook inject_session_log.sh ✅ (symlink)
  hook save_transcripts.sh ✅ (symlink)
  transcripts: kept forever (no rotation).
  settings.json ✅ (3 hook(s) added, existing keys preserved)
  gitignore ✅ (transcripts + memory store; the chain stays tracked)
  memory: relocating this project's memory dir INTO the project.
          ~/.claude/projects/-home-you-new-project/memory
       -> ~/new-project/.claude/memory/store
  memory: inverted ✅ (verified by reading MEMORY.md back through the link)
  git: initial commit ✅ (8de4f69)
```

Every line is a check, not just a log: the memory move is confirmed by reading the file back through
the new link, and it rolls itself back if that fails. If something was already in place, it says so
and leaves it alone — the script is safe to re-run.

#### What you end up with

```
~/new-project/
├── .claude/
│   ├── hooks/                    → symlinks into skills/, so updating the skill updates the hook
│   │   ├── inject_session_log.sh
│   │   └── save_transcripts.sh
│   ├── memory/store/MEMORY.md    ← the real memory files now live here
│   ├── settings.json             ← the three hooks, registered
│   └── skills/
│       ├── setup-session-log/
│       └── sync-mem/
└── .gitignore                    ← ignores transcripts + memory store
```

Plus one thing outside the project: `~/.claude/projects/<...>/memory` is now a symlink pointing at
`~/new-project/.claude/memory/store`.

And one commit:

```
8de4f69 Initial commit: session-log + memory continuity system
```

`session_logs/` is deliberately **not** there yet — your first Claude Code session creates it. Its
absence at this point is expected, not a failed install.

#### Good to know

- **`--create` is a flag, not automatic.** A mistyped path would otherwise install into a new wrong
  directory and report success. It also refuses if the *parent* folder is missing — it makes a
  project, not a whole path.
- **It is the only mode that commits**, because it is the only one where the repo holds nothing but
  what the installer just put there. If the commit fails (no `user.name` / `user.email`) it says so
  instead of continuing quietly.
- **It runs `git init` for you** because the `SessionStart` hook warns when work happened without a
  session log being written for it. In a git repo it checks with `git status` — fast and exact.
  Without one it falls back to walking the file tree, which is slower and needs tuning on projects
  with big data folders. A repo also lets each log's "Done this session" sit next to real commits.

### Existing project

```sh
./claude-session-continuity/install.sh ~/existing-project
```

That is the whole setup here too — you are ready to work. Your first session creates and commits the
session-log chain in the background.

#### How it differs from a new project

- **The directory must already exist.** It does *not* need a `.claude/` directory — that gets
  created.
- **`settings.json` is merged, not overwritten.** Existing keys (`permissions`, `mcpServers`, other
  hooks) are preserved, and re-running adds nothing twice.
- **It never commits.** Your tree may hold unrelated in-flight work, and sweeping that into a commit
  nobody asked for is exactly the surprise this tool refuses to spring — the same rule `/sync-mem`
  follows when it reports git state but won't act on it. Commit the install yourself, alongside
  whatever else is in flight.

> This is the common case. The payoff here is long-horizon work, and long-horizon work usually
> already has a repo — which is also why this repo isn't a GitHub template. A template serves only
> brand-new projects, hands the clone this repo's README and identity, and leaves no path for
> upstream fixes to arrive.

#### Not a git repository yet?

Run `git init`, then commit soon after — between `init` and the first commit every file is
untracked, which needlessly widens the staleness check's candidate set. Initializing later is not
fatal: the hook probes for a repo at runtime every session and upgrades itself.

What to track, once you do:

- **Commit** `session_logs/` — the chain is the shareable layer.
- **Gitignore** `.claude-transcripts/` and `.claude/memory/store/` — both carry machine-specific
  paths, and the transcripts are the full verbatim conversation.

### What both modes do

Copy both skills, symlink the hooks into `.claude/hooks/`, merge `settings.json`, seed `.gitignore`,
and relocate the project's memory dir into the project (below). Both are re-runnable, and
`--dry-run` prints the plan without touching anything.

#### All the flags

| Flag | Effect |
|---|---|
| `--create` | Create the target directory, `git init` it, and make the initial commit |
| `--dry-run` | Print the plan and write nothing |
| `--no-invert-memory` | Leave the memory store in Claude's home folder |
| `--invert-memory` | Move it into the project — the default; accepted for explicitness |
| `--no-transcripts` | Don't copy session transcripts into the project |
| `--transcripts` | Copy them — the default; accepted for explicitness |
| `--retention-days N` | Delete mirrored transcripts older than N days (`0` = keep forever, the default) |
| `--nudge-turns N` | Remind to `/sync-mem` every N turns (default 25; `0` installs the hook but disables it) |
| `--no-sync-nudge` | No sync reminders at all |
| `-y`, `--yes` | Take every default; ask nothing, even on a terminal |
| `-h`, `--help` | Print usage and exit |

Any flag settles its question and suppresses the matching prompt.

#### What it asks you

On a terminal the installer asks about the choices that are genuinely yours. Piped or redirected — CI,
a script — it asks nothing and takes the defaults, so it never blocks an unattended run. Any flag you
pass settles that question and suppresses its prompt; `-y` takes every default silently.

| Question | Default | Flag |
|---|---|---|
| Where should this project's memory live — the project folder, or Claude's home folder? | **project folder** | `--no-invert-memory` |
| Keep a copy of session transcripts in the project? | **yes** | `--no-transcripts` |
| Delete transcripts older than N days? | **keep forever** | `--retention-days N` |

The third question is skipped if you decline the second — there is nothing to prune.

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

### Two things it does by default

Both are on unless you turn them off, and both write outside the obvious place. They exist for the
same reason: **anything Claude Code keeps under `~/.claude/` is on borrowed time.** In a container
that directory is the ephemeral half while your project is the persistent bind-mount, so a rebuild
takes it; on a host, a cleanup or a machine change does. Each default moves one kind of history into
the project, where it lives as long as the project does.

#### 1. The memory relocation

```
~/.claude/projects/<sanitized-target>/memory   ->   TARGET/.claude/memory/store/
```

The directory is moved into the project and replaced with a symlink pointing at it. Any memory
already there is carried across first; the original is kept as `.bak` until the new location is
verified by reading `MEMORY.md` back through the link, then removed. A failed verification rolls back
automatically. **Opt out with `--no-invert-memory`.**

**Why this direction.** The link runs harness → project, never the reverse. A `.claude-memory`
symlink in the project pointing out at `~/.claude/...` would embed an absolute host path in the
project tree, which breaks in a devcontainer, a remote workspace, a CI checkout, or on another
machine. Inverted, the project holds real files that resolve everywhere and the only symlink sits
under `~/.claude/`, where Claude Code — running on the host — resolves it fine.

> **⚠️ The risk, stated plainly.** `~/.claude/projects/<sanitized-cwd>/memory` is Claude Code's own
> internal layout. It is not a documented, promised-stable interface, and this project has no special
> standing to rely on it. If that layout changes in a future release, the symlink stops corresponding
> to anything the harness looks at — and the failure is **silent**: memory simply stops being read or
> written, with no error. Nothing here can detect that on your behalf.
>
> That is a real bet, made deliberately, because the alternative — memory living in the disposable
> half of a container — fails more often and more expensively. But it is a bet, and you should make
> it knowingly rather than inherit it from a default.

**Two related caveats.** The harness path is derived from the target path with `/` replaced by `-`,
so opening the project by a *different* route — another mount point, a symlinked path — makes Claude
Code compute a different directory that will not see this memory. And `store/` is gitignored, so
anything that deletes ignored files (`git clean -xdf`, a fresh clone) removes the link's target;
re-running `install.sh` detects that and repairs it.

**To undo it**, move the real files back and drop the link:

```sh
auto=~/.claude/projects/"$(pwd | tr / -)"/memory
rm "$auto"                                  # remove the symlink, not its target
mkdir -p "$(dirname "$auto")"
mv .claude/memory/store "$auto"             # put the real files back
```

The session-log chain in `.claude/memory/session_logs/` is unaffected — it never lived in the memory
directory, by design.

#### 2. The transcript mirror

```
~/.claude/projects/<sanitized-target>/*.jsonl   ->   TARGET/.claude-transcripts/
```

A `SessionEnd` + `Stop` hook copies the raw session transcripts into the project. This is a **copy**,
not a move — the originals are left alone, since one of them is the session currently being written.
Without it, every session log's `transcript:` field points into a directory that is not durable: in a
real devcontainer, a rebuild destroyed about four months of transcripts, and all 39 logs survived
while every pointer in them died.

> **⚠️ These are the full verbatim conversations**, including anything you pasted into them. They
> land in `.claude-transcripts/` inside your project. The installer gitignores that directory, which
> keeps it out of the repo — but *not* out of a zip, a backup, a container image built from the
> workspace, or a directory someone browses. On a work machine or a shared repo, decide whether you
> want that before installing, not after.

**Opt out of the mirror entirely with `--no-transcripts`**, or at the second prompt. Nothing else
depends on it; you lose only the ability to drill from a session log into its raw transcript.

**Retention is off by default** — nothing deletes them, and the `Stop` hook refreshes after every
assistant turn, so the directory only grows. Pass **`--retention-days N`** at install time to wire a
`SessionEnd` prune hook that deletes mirrored transcripts older than N days while always keeping the
3 most recent; the knobs then live in `.claude/hooks/transcript-retention.conf`. Decline and no
deletion code is installed at all.

**To turn it off**, remove the two `save_transcripts.sh` registrations from `.claude/settings.json`
(`SessionEnd` and `Stop`) and delete `.claude-transcripts/`. Nothing else depends on it; you lose only
the ability to drill from a session log into its raw transcript.

### Sync reminders, and where to change the cadence

`/sync-mem` is invoked, not automatic, so the obvious failure is forgetting — and losing a session's
findings. A `Stop` hook nudges the agent every N turns.

**The cadence lives in one file, and you can change it whenever you like:**

```sh
.claude/hooks/sync-nudge.conf
```

```ini
# remind every N turns; 0 disables the reminder entirely
NUDGE_EVERY_TURNS=25

# on a compaction, record that it happened so the next sync can flag lost detail
NOTE_COMPACTIONS=1
```

**It is read at runtime, so edits take effect immediately — no reinstall, no touching
`settings.json`.** Set it at install time with `--nudge-turns N` if you already know what you want;
change your mind later by editing the file. The hook is registered even when the count is `0`, so
turning the reminder back on is a one-line edit rather than a reinstall.

| You want | Set |
|---|---|
| Frequent prompting on short, dense sessions | `NUDGE_EVERY_TURNS=10` |
| The default — occasional, rarely intrusive | `NUDGE_EVERY_TURNS=25` |
| Long sessions where you sync by habit | `NUDGE_EVERY_TURNS=40` |
| No reminders, fully manual | `NUDGE_EVERY_TURNS=0` |
| Never install the hook at all | `--no-sync-nudge` at install |

**Why a turn count.** A turn boundary is the one moment a reminder can be used: the agent has a turn,
and context to spare. Keep N highish — a turn count cannot tell a natural checkpoint from the middle
of a debugging chain, and a sync forced with nothing durable to save is churn. The counter resets
whenever the chain head is written, so a session that syncs on its own is never nagged, and the nudge
never blocks: it says explicitly not to interrupt what you asked for in order to sync.

**When a compaction happens anyway**, a `PreCompact` hook appends a line to
`.claude/hooks/.compactions` recording it. It deliberately does *not* ask for a sync there — the
hooks reference states there is **no turn between the `PreCompact` hook running and compaction
happening**, so any request made there is unreachable until the detail it wanted is already gone. The
note is the useful part: the next `/sync-mem` reports how many compactions occurred and marks which
findings are reconstructed rather than remembered, then clears the file.

> **Why a note and not a reminder.** The danger after a compaction is not only lost detail — it is a
> later entry written from a summary but presented as if it were first-hand. The chain is only worth
> reading if its entries can be trusted, so turning a silent loss into a stated one is worth more
> than a prompt that arrives too late. `PostCompact` was tried too, and prompting a sync after the
> fact just produces the confident-looking degraded entry this is meant to prevent.
>
> "Remind me at 40% context" is not implementable at all: **no hook event receives context-window
> usage or token counts.** Turn count is the honest approximation.

Both files the hooks write — `.sync-nudge.state` (the counter) and `.compactions` — are gitignored;
they are per-machine, per-session scratch.

### From here on

Work normally. Run **`/sync-mem`** at checkpoints — when something is worth keeping, or before you
step away — and it appends a log for the session and saves what is durable to memory. From your
second session onward, the previous session's summary and planned next steps are loaded before you
type anything.

You never need to restart a session for any of this, and you never need to run `/setup-session-log`
by hand — though you can, and it is idempotent.

> **Installing by hand instead of with `install.sh`?** Skills and hooks are registered when a session
> **starts**, not when their files appear on disk, so a skill copied into a session that is already
> running is not invocable in it — invoking it fails with `Unknown skill`. That is this rule showing
> up, not a broken install: start a session, or restart the open one, and it works. `install.sh`
> avoids this entirely by finishing before any session starts.

## License

MIT — see [LICENSE](LICENSE).
