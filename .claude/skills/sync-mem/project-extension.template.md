# /sync-mem project extension

**This is an inert stub.** `/sync-mem` reads this file after its generic memory write and follows
whatever it declares. Nothing below is active — everything is commented out. Until you uncomment or
write something, `/sync-mem` should report *"project extension: stub, nothing declared"* and move on.
Delete the file if you don't want one; the generic sync works fine without it.

## What it's for

The generic sync writes memory entries and the session log. It does not know about **files in your
project that go stale when a finding changes** — a plan, a spec, a caption, a results write-up, a
generated table — nor about project-specific guards on what may be saved. Declare those here and
they get maintained at the same checkpoint, and audited alongside the memory entries.

Extensions add work; they never replace or override the generic procedure.

## Rules for maintaining this file

An extension that is allowed to grow becomes a second, unmaintained memory store. Three rules keep
it from rotting — each one is a failure observed in a real long-running project:

1. **Procedure, never findings.** A fact worth keeping is a memory entry. Cite it; don't restate it.
   Restated content is the only thing here that can silently contradict its source — and when the
   source is later revised or garbage-collected, the copy here is what survives and misleads.
2. **Never re-specify what the skills already do.** The chain protocol, the audit, and the report
   format live in the skills. A second copy here is free to diverge from them. Refer to steps by
   *name* ("the audit", "the final report"), never by number — numbers shift when a skill gains a step.
3. **Cite by identifier, not by location.** Name a flag, a config key, a function, a file. Never a
   section heading or a line number: those move, and the pointer rots with nothing to notice.

A fourth, if this file ever cites paths: **check that its own citations still resolve** as one of
your checks. The generic audit verifies paths inside memory entries — not paths inside this file.

## Files to maintain — uncomment and fill in

<!--
| File | When to touch it |
|---|---|
| `docs/PLAN.md`      | a phase is added, completed, or reordered |
| `docs/RESULTS.md`   | an analysis lands a finding worth recording canonically |
| `README.md`         | a user-facing flag, command, or default changed |
-->

## Project-specific guards — uncomment and fill in

<!--
These are the project's equivalent of the generic "do not save" rules.

- **Name the filter.** Any saved numeric claim must state which filter/version produced it;
  flag it as ambiguous rather than saving a bare number.
- **Prefer the canonical source.** If a finding was produced with superseded scaffolding,
  convert it before saving, or save both clearly labelled.
-->

## Report augmentation — uncomment and fill in

<!--
Add a "Project files" block to the final report so both layers are visible: one line per file
touched, plus anything skipped deliberately and anything left open.
-->
