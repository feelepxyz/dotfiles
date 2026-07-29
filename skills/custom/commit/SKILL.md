---
name: commit
description: Commit the working tree with a generated Conventional Commits message, then name the next step. Use when the user wants to commit or check in their work, or asks what is uncommitted.
---

# Commit

`commit.sh` is the whole skill. It classifies the repository, commits dirty
work through `wt step commit`, and names the next destination — one call, a
handful of lines back.

## Run it

    bash ~/.agents/skills/commit/commit.sh

Run through `bash` — skills install without the exec bit. `--help` lists the
flags.

`--push` hands off to /pr rather than naming it as the next step, so one call
commits and ships. A clean tree still hands off: on a branch that already
carries commits, pushing means shipping what is there. Flags do not travel —
`--draft` and `--base` mean running /pr yourself.

## Relay what it returns

Report the `state`, the commit, and the `next` line as they come — the script
re-reads git after committing, so its output is already reality.

Three states, three destinations:

| `state:` | Where you are | `next:` |
| --- | --- | --- |
| `default-branch` | the repository's default branch | a runnable push command, or a note that there is nothing to push |
| `branch` | a non-default branch in the main worktree | `/pr` |
| `worktree` | a linked git worktree | `/pr` |

A clean tree is a complete answer: say so and stop.

## When it reports an error

Every error carries a `cause:` and a `help:` line — act on the `help:` line.

`approval:` is the exception — hand the user `wt config approvals add`; never
run it yourself.

`fallback:` marks the cases where writing a Conventional Commits message
yourself (no AI attribution) and running `git commit` is the reasonable
recovery.

## Boundary

Committing is the whole job. Pushing, merging, and opening the pull request
happen when the user asks for them — or when `--push` is passed.
