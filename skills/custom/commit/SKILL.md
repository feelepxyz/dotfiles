---
name: commit
description: Commit the working tree with a generated Conventional Commits message, then name the next step. Use when the user wants to commit or check in their work, or asks what is uncommitted.
---

# Commit

`commit.sh` is the whole skill. It classifies the repository, commits dirty
work through `wt step commit`, and names the next destination — one call, a
handful of lines back.

## Run it

    bash ~/.claude/skills/commit/commit.sh

The script sits beside this file; run it through `bash`, since skills install
without the executable bit. Three flags narrow the job:

- `--status` — report state only, commit nothing
- `--dry-run` — preview the generated message, commit nothing
- `--push` — after committing, run the pull request skill

`--push` hands off to /pr rather than naming it as the next step, so one call
commits and ships. A clean tree still hands off: on a branch that already
carries commits, pushing means shipping what is there. Flags do not travel —
`--draft` and `--keep` mean running /pr yourself.

## Relay what it returns

The output is the answer. Report the `state`, the commit, and the `next` line.
The script reads its result back from git after committing, so it already
reflects reality — go straight to reporting it.

Three states, three destinations:

| `state:` | Where you are | `next:` |
| --- | --- | --- |
| `default-branch` | the repository's default branch | a runnable push command, or a note that there is nothing to push |
| `branch` | a non-default branch in the main worktree | `/pr` |
| `worktree` | a linked git worktree | `/pr` |

A clean tree is a complete answer: say so and stop.

## When it reports an error

Every error carries a `cause:` and a `help:` line — act on the `help:` line.

An unapproved hook is the exception: it asks the user to run
`wt config approvals add`, and that stays with the user. Approving a
repository's hooks decides whether it may run arbitrary commands on their
machine, so hand them the command and let them review it.

`fallback:` marks the cases where writing a Conventional Commits message
yourself and running `git commit` is the reasonable recovery.

## Boundary

Committing is the whole job. Pushing, merging, and opening the pull request
happen when the user asks for them — or when `--push` is passed.
