---
name: stay-in-project
description: Guardrail that keeps every file-writing action scoped to this project's own repository. Consult this BEFORE calling Write, Edit, or NotebookEdit, and BEFORE any Bash/PowerShell command that creates, deletes, moves, renames, or overwrites a file or directory (mkdir, rm, mv, cp -T, Remove-Item, Set-Content, redirects like `>`, installers, config edits) — even when the user's request never mentions "outside the project" and the action looks routine. Also use it when a task needs an external tool (an engine, an SDK, a CLI) whose install location is unknown, since finding it is a common way file operations quietly drift outside the repo. Does not apply to read-only actions (Read, Grep, Glob, `git status`, launching an existing executable, `git config --get`) — only to actions that change something on disk.
---

# Stay inside the project

## Why this exists

This project's working directory is the repository root — everything the
simulation, the tests, and the balance data depend on lives there. Nothing
about the game requires touching a file anywhere else, so any write outside
that boundary is either a mistake (a relative path that resolved wrong, a
command run from the wrong cwd, a stray `..`) or something that genuinely
needs the user's sign-off (installing a dependency, editing a global config,
saving a file to their Desktop).

The risk isn't usually a direct "let me go edit some random file elsewhere" —
it's drift. A task that starts as "find where Godot is installed" is a
read-only search, perfectly fine on its own. But once a tool's location is
unknown and a broad search across drives feels natural, it's an easy next
step to also treat a write the same way — create a scratch file next to what
you found, "fix" a config in that other install, drop an output file
wherever seemed convenient at the time. This skill exists to catch that
transition, at the moment right before a write happens, not after.

## What counts as "the project"

The project root is this repository's root — resolve it dynamically (the
directory containing `project.godot` / `.git`, or the cwd reported in your
environment info), never a hardcoded absolute path. The repo can be checked
out on a different drive or a different machine, and the rule must still
hold there.

## Before any write, check the target path

Before calling `Write`, `Edit`, `NotebookEdit`, or running a `Bash`/
`PowerShell` command whose effect is to create, delete, move, rename, or
overwrite something, resolve the actual target path (relative paths resolve
against the current cwd — if a `cd` or `Set-Location` happened earlier in
the session, account for that) and ask: **does it land inside the project
root?**

Two things are automatically in-bounds, not exceptions to argue about:
- The scratchpad/temp directory your environment already designates for
  scratch output — that's what it's for.
- Reading, listing, or launching something outside the project (running an
  already-installed engine/tool, `git config --get`, inspecting a path to
  find where a dependency lives) — none of that writes anything.

If the target is genuinely outside both of those, stop before running the
write and tell the user exactly which path it is and why the task needs it,
then wait for a clear yes — *unless* the user's own message already named
that exact path (they pasted it, or said "save it to my Desktop" and the
Desktop is the target). Naming a path themselves is consent for that path;
it is not blanket consent for other paths a related task might also touch.

## Examples

**Needs a pause:** a task requires finding an external SDK to check its
version, and the natural next step is regenerating one of its config files
in place. That config lives outside the repo — say so, name the file, and
ask before writing it, even though the user asked for the SDK check.

**No pause needed:** searching `C:\` for where an executable lives (read-
only), then launching it to test something. Nothing is written outside the
project by either step.

**No pause needed:** the user says "drop a copy of the report on my
Desktop" — they named the destination themselves, so writing there is
already authorized.

**Needs a pause:** a balance-tuning script wants to write its output next to
a template it found in an unrelated folder outside the repo, instead of into
`tools/` or the scratchpad — outside the project, and the user never named
that folder.
