# Writing a `/sync-mem` project extension

Reference for filling in `.claude/sync-mem-project.md`. Not read automatically — the extension
itself is, at the extension step of `/sync-mem`. Read this before writing one, or when deciding
whether something belongs in it.

## An empty extension is a correct extension

A new project has produced no results, so it has nothing to declare. The stub `install.sh` writes is
inert on purpose; it is not a placeholder for content someone owes. Fill it in as records
accumulate — that is also when you will know what belongs.

## The three questions it answers

Each answer depends on the project's shape, which is why it can live nowhere else.

**1. What else carries results?** Files whose content is downstream of findings — a plan, a spec, a
results write-up, figure captions, a README documenting behaviour. They fall behind silently: a
session that changes a result but not its record leaves the two disagreeing with nothing to notice.

This is a **standing declaration, not a to-do list.** A file is listed because it carries results,
not because this session touched it. Most sessions will touch none of them; the trigger decides when
one fires.

**2. What makes a save inadmissible here?** Guards — on *form* ("a numeric claim needs a script that
produces it") or on *relevance* ("does this serve a stated goal"). Guards are checks, not writes:
surface failures in the report's *Open / ambiguous* block. A guard **cites** its criterion from
`CLAUDE.md`; it never restates it, because the copy outlives the original.

**3. What dies quietly if the session log doesn't name it?** External state memory can't hold — a
running job and the rule it will be judged by (stated *before* the result is read), a pinned version
or digest, work committed in another repo.

## The admission test

| If it… | it belongs in… |
|---|---|
| fires *while working* | `CLAUDE.md` — loaded every turn. The extension is read at a sync, too late to prevent the edit it would have stopped. |
| is the same for *every* project | the skill itself |
| is a fact, not an instruction | a memory entry |
| **applies only at a checkpoint, and only here** | **the extension** |

Goals go in `CLAUDE.md`. Findings and numbers go in memory. Current status goes in the session-log
chain. Generic memory hygiene belongs to the skill. Content that drifts in from those categories is
what turns an extension into a second, unmaintained memory store that contradicts its own sources.

## Worked entries

Files that carry results — name the file, then the trigger, then what makes the write good:

> **`docs/RESULTS.md`** — a required write when an analysis lands a finding worth recording
> canonically. Persist the raw output first and cite it; a derived number with no source rots.

> **`CLAUDE.md`** — a required write when the session changed the layout, a convention, or what is
> canonical about working here. Test: *could a fresh session, reading only `CLAUDE.md` and the chain
> head, orient to the current program?* If no, `CLAUDE.md` is the write — not another memory entry.
> It must gain no mutable status. **Never auto-edit it**; show the proposed change first, because it
> is read at every session start, so a wrong line there misleads all of them.

> **`shared/manuscript.md`** — **never written from a sync.** If a finding implies an edit, record it
> as a next-step in the log. Listing a file precisely to forbid writing it is a legitimate entry.

Guards — one line, with the criterion cited rather than restated:

> **G1 — every new numeric claim has a script that produces it.** Flag any asserted number without
> one (`CLAUDE.md`: *a claim needs a script in `code/` that produces it*).

## Four rules that keep it from rotting

1. **Procedure, never findings.** Cite a memory entry; don't restate it.
2. **Never re-specify what the skills do.** Name their steps ("the audit", "the carry-over") rather
   than numbering them — numbers shift when a skill gains a step.
3. **Cite by identifier, not location.** A flag or a config key, never a section heading or a line
   number; those move and the pointer rots with nothing to notice.
4. **Keep it lean.** If a check stops earning its keep, delete the line rather than working around it.

## Why those four

Field evidence, from real installs of this tool. An extension that grew to 151 lines without a
leanness rule accumulated five decay modes: a stale step number; a section re-specifying the chain
protocol, obsolete once that moved into the skills; two citations to memory entries a garbage
collection had deleted — one of them a repeat of a repair documented in the same file; a declared
write target whose own banner marks it superseded; and its own stated index budget exceeded. Two
extensions that stayed near 45 lines, both ending with the leanness rule, show none of these.
