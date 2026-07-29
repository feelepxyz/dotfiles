---
name: setup-repo
description: Set a repository up across all three areas — git hooks, worktrunk and GitHub housekeeping — in one pass and one commit. Use when the user wants a repo set up or configured, asks what setup a repo is missing, or is starting work in an unfamiliar repo.
disable-model-invocation: true
---

# Set up a repository

Three skills each converge one area. This one runs them in the order that costs
the user the fewest decisions and the fewest commits.

`setup-repo.sh` is the roll-up: one call that reports all three areas instead of
three calls that report one each. It only reads — two of the three areas need the
user to choose from a table first, so converging stays with the individual
skills.

Those three carry `disable-model-invocation`, so they cost nothing in a session
that is not setting a repo up and no agent fires one on its own. **That is why
this skill drives them by reading their `SKILL.md` and following it rather than
invoking them as skills** — the read delivers what a skill invocation would
have, and works the same in every agent. Only the user typing `/setup-git-hooks`
reaches one directly.

## Run it

    bash ~/.agents/skills/setup-repo/setup-repo.sh

Run through `bash` — skills install without the exec bit. It finds its siblings
as sibling directories, so it works from the installed copy and from
`~/.dotfiles/skills/custom/` alike.

| Area | Skill | Asks the user? |
| --- | --- | --- |
| git-hooks | `setup-git-hooks` | yes — which hooks, per stage |
| worktrunk | `setup-worktrunk` | yes — which panes and steps |
| github | `setup-github` | yes — which settings |

## The main line

1. **Roll up.** Run the script. Relay the `areas[]` table, and tell the user up
   front how many questions are coming — one per pending area that asks.
2. **Hooks.** Read `~/.agents/skills/setup-git-hooks/SKILL.md` and follow it.
   Hooks go before worktrunk because they govern the commits made inside the
   worktrees worktrunk opens — a worktree opened before the hooks exist gets
   commits nothing checked.
3. **Worktrunk.** Read `~/.agents/skills/setup-worktrunk/SKILL.md` and follow it.
4. **Commit once, by pathspec.** Steps 2–3 each wrote a file, and each of those
   skills asks for its own commit. **Override that** — the setup is one change to
   the repo, not two:

       git status --porcelain    # look before staging
       git commit -m "…" -- prek.toml .config/wt.toml

   **Never `git add -A` here.** A repo that needed setting up is usually a repo
   being worked in: the tree may hold uncommitted work, and the index may already
   hold staged changes that are not yours. The pathspec form commits exactly
   those paths and leaves the rest of the index untouched. If `git status` shows
   work you did not create, say so — do not fold it in, and do not stash it.

   The hooks installed in step 2 run on this commit. If they reformat a file,
   re-stage and commit again rather than passing `--no-verify`.
5. **GitHub.** Read `~/.agents/skills/setup-github/SKILL.md` and follow it. It
   writes nothing local, which is why it sits after the commit rather than
   inside it.
6. **Verify.** Re-run the roll-up.

Done when the roll-up reports `pending: 0 of 3 areas`. Worktrunk stays `pending`
until its hooks are approved, so reaching zero already means the user has run the
`wt config approvals add` command it hands over — hand it to them and wait rather
than calling the run finished without it. An area the user chose to skip is
finished too — say which, rather than leaving it looking unfinished.

## Reading the roll-up

The `state` column decides what happens next, and the run prints a `legend[]`
for the states it actually produced — read the meanings there. Only `converged`,
`configured` and `skipped` count as done; everything else adds to the pending
tally and carries a `next[]` entry.

A `next[]` entry naming a `SKILL.md` to read is a step that asks the user a
question. A `next[]` entry that is a shell command does not.

## Boundary

Sequencing the three areas is the whole job. What each area proposes, how it heals
drift, and how it explains itself belong to that area's own skill — read those
rather than second-guessing them from here.
