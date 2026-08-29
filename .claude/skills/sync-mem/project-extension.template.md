# /sync-mem project extension

Skeleton, copied here by `/sync-mem` when you asked for one. It reads this file after its generic
memory write and follows whatever it declares — so an entry takes effect at the next sync, and a
section left empty simply declares nothing. Delete the file if you change your mind; the generic
sync works fine without it.

Three things belong here, and nothing else: files that **carry results** and so fall behind findings
silently; **guards** deciding whether a save is admissible in this project; and state that **dies
quietly** unless the session log names it.

📖 **Before filling this in, read `.claude/skills/sync-mem/project-extension-guide.md`** — the
admission test for what belongs (and what belongs in `CLAUDE.md`, memory, or the chain instead),
worked entries, and the failure each rule prevents.

## 1. Files that carry results

<!-- A standing declaration, not a to-do list: most sessions touch none of them.
**`docs/PLAN.md`** — a required write when a phase is added, completed or reordered.
-->

## 2. Guards

<!-- Checks, not writes; surface failures in the report's "Open / ambiguous" block.
- **G1 — <rule>.** Flag <what>, citing the criterion from `CLAUDE.md` rather than restating it.
-->

## 3. Carry-over

<!-- What the session log must name because it dies quietly otherwise.
- **Running work** and the rule it will be judged by — stated before the result is read.
-->

---

Keep it lean; if a check stops earning its keep, delete the line rather than working around it.
