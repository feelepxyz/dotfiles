---
name: branch
description: Land on a branch worth working on — fetch, cut off the fresh default, carry uncommitted work across, or report the branch already here. Use when the user wants a new branch, is starting a piece of work, or is sitting on a stale or already-merged branch.
---

# Branch

`branch.sh` is the whole skill. It assesses the repository, lands on a branch
worth working on, and names the next step — one call, a handful of lines back.

## Run it

    bash ~/.agents/skills/branch/branch.sh <name>

Run through `bash` — skills install without the exec bit.

**Always pass a name**, with the one exception noted under `--rebase`. The
repository state decides what happens; the name is consumed only when a fresh
cut is actually needed. On a branch that already carries live work the script
reports it and changes nothing, whatever name you passed — so passing one is
always safe. Derive it in kebab-case from the work this session is about to do.

Three flags carry more than `--help` says; `--help` lists all six:

- `--status` — assess and report the plan, change nothing. Every refusal a run
  would raise comes back as a `plan:` line instead, so this always reports.
- `--rebase` — replay a branch that is behind onto the fresh default. Standing
  on the default branch this is the exception to passing a name: **omit** it to
  bring the default up to date and stay there. Pass one and it cuts as usual,
  which fast-forwards the default on the way past.
- `--new` — cut a fresh branch even when this one carries live work. It does
  not override the unpushed-commits refusal below.

## Relay what it returns

Report the outcome line and the `next:` line as they come — the script re-reads
git after acting, so its output is already reality.

| Outcome | What happened |
| --- | --- |
| `branched:` | a fresh branch, cut off the fetched default |
| `updated:` | fast-forwarded — either the branch carried nothing of its own and kept its name, or the default was brought current on the way to a cut |
| `rebased:` | `--rebase` replayed the branch onto the fetched default |
| `ready:` | the branch here is already worth working on; nothing changed |

`merged:` accompanies a `branched:` line when the old branch had already landed
— it carries a `cleanup:` command, which stays with the user.

A `ready:` line is a complete answer: say so and stop.

## When it reports an error

Every error carries a `cause:` and a `help:` line — act on the `help:` line.

Two cases stay with the user:

- A local default branch carrying unpushed commits is refused with two runnable
  options. Ask which they want rather than choosing — one rewrites where the
  default branch points, the other publishes without review.
- A conflicting stash pop stops the run with the entry retained. The branch
  exists and the changes are still in the stash; resolve before doing anything
  else.

## Boundary

Landing on the branch is the whole job. Building a *worktree* is `wta`'s, and
committing and shipping happen through /commit and /pr — or through `--push`,
which runs both.
