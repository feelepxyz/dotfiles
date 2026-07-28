---
name: setup-repo
description: Set a repository up across all four areas — Entire, git hooks, worktrunk and GitHub housekeeping — in one pass and one commit. Use when the user wants a repo set up or configured, asks what setup a repo is missing, or is starting work in an unfamiliar repo.
disable-model-invocation: true
---

# Set up a repository

Four skills each converge one area. This one runs them in the order that costs
the user the fewest decisions and the fewest commits.

`setup-repo.sh` is the roll-up: one call that reports all four areas instead of
four calls that report one each. It only reads — two of the four areas need the
user to choose from a table first, so converging stays with the individual
skills.

Those four carry `disable-model-invocation` (and `allow_implicit_invocation:
false` for the OpenAI agents), so they cost nothing in a session that is not
setting a repo up, and no agent fires one on its own. **That is why this skill
drives them by reading their `SKILL.md` and following it, rather than invoking
them as skills** — the read delivers exactly what a skill invocation would have,
and it works the same in every agent. Only the user typing `/setup-git-hooks`
reaches one directly.

## Run it

    bash ~/.agents/skills/setup-repo/setup-repo.sh

The script sits beside this file; run it through `bash`, since skills install
without the executable bit. It finds its siblings as sibling directories, so it
works from the installed copy and from `~/.dotfiles/skills/custom/` alike.

| Area | Skill | Asks the user? |
| --- | --- | --- |
| entire | `setup-entire` | no — `--apply` is autonomous |
| git-hooks | `setup-git-hooks` | yes — which hooks, per stage |
| worktrunk | `setup-worktrunk` | yes — which panes and steps |
| github | `setup-github` | yes — which settings |

## The main line

1. **Roll up.** Run the script. Relay the `areas[]` table, and tell the user up
   front how many questions are coming — one per pending area that asks.
2. **Hooks.** Read `~/.agents/skills/setup-git-hooks/SKILL.md` and follow it.
   Hooks go first because of who chains: prek's shim does **not** call a hook it displaced,
   while Entire's does. Whichever installs last has to be the chaining one, so
   prek lands first and Entire wraps it. Hooks also come before worktrunk,
   because they govern the commits made inside the worktrees worktrunk opens.
3. **Entire.** `bash ~/.agents/skills/setup-entire/setup-entire.sh --apply`.
   It asks nothing, so it needs no question of its own.
4. **Worktrunk.** Read `~/.agents/skills/setup-worktrunk/SKILL.md` and follow it.
5. **Commit once, by pathspec.** Steps 2–4 each wrote files, and each of those
   skills asks for its own commit. **Override that** — the setup is one change to
   the repo, not three:

       git status --porcelain    # look before staging
       git commit -m "…" -- .entire .claude .codex .gemini .pi prek.toml .config/wt.toml

   **Never `git add -A` here.** A repo that needed setting up is usually a repo
   being worked in: the tree may hold uncommitted work, and the index may already
   hold staged changes that are not yours. The pathspec form commits exactly
   those paths and leaves the rest of the index untouched. If `git status` shows
   work you did not create, say so — do not fold it in, and do not stash it.

   The hooks installed in step 2 run on this commit. If they reformat a file,
   re-stage and commit again rather than passing `--no-verify`.
6. **GitHub.** Read `~/.agents/skills/setup-github/SKILL.md` and follow it. It
   writes nothing local, which is why it sits after the commit rather than
   inside it.
7. **Verify.** Re-run the roll-up.

Done when the roll-up reports `pending: 0 of 4 areas`. Worktrunk stays `pending`
until its hooks are approved, so reaching zero already means the user has run the
`wt config approvals add` command it hands over — hand it to them and wait rather
than calling the run finished without it. An area the user chose to skip is
finished too — say which, rather than leaving it looking unfinished.

## Reading the roll-up

The `state` column decides what happens next:

- **converged** / **configured** — done. Two words for one outcome: `converged`
  is what the areas that reconcile settings report (entire, github),
  `configured` what the areas that write a config file report (git-hooks,
  worktrunk). Nothing to do either way.
- **pending** — the area has never been set up, or it is set up but still needs
  something from the user. Follow the step in `next[]`.
- **drifted** / **unmanaged** — a config exists but is wrong or belongs to
  someone else. The skill's `--heal` names it; ask before repairing.
- **skipped** — no GitHub remote. Nothing to do, and not a failure.
- **blocked** — the sibling ran fine but cannot act: no admin on the GitHub repo.
  Normal on a repo the user does not own. Only they can resolve it, by getting
  admin or deciding to skip GitHub.
- **error** — the sibling exited non-zero. The detail carries its `error:` line;
  act on that, not on this table.
- **unavailable** — that sibling skill is not installed. Re-run
  `~/.dotfiles/install/skills.sh`.
- **unknown** — the roll-up could not parse that sibling. Run the sibling
  directly and trust its own output over this table.

Only `converged`, `configured` and `skipped` count as done. Everything else adds
to the pending tally and carries a `next[]` entry.

A `next[]` entry naming a `SKILL.md` to read is a step that asks the user a
question. A `next[]` entry that is a shell command does not.

## Boundary

Sequencing the four areas is the whole job. What each area proposes, how it heals
drift, and how it explains itself belong to that area's own skill — read those
rather than second-guessing them from here.
