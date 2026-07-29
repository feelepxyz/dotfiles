---
name: pr
description: Open a pull request for the current branch, watch its checks, and land it — squash, rebase, run hooks, push, then merge and clear the worktree away. Use when the user wants to open or update a pull request, ship a branch, check whether CI passed, or merge a request that is ready.
---

# Pull request

Two scripts, one arc. `pr.sh` runs worktrunk's merge pipeline with the landing
swapped for a pull request — pre-commit hooks, squash, rebase onto the default
branch, pre-merge hooks, push, `gh pr create`. `checks.sh` watches what CI makes
of it. `pr.sh --merge` lands the request and takes the worktree with it.

## Run it

    bash ~/.agents/skills/pr/pr.sh

Run through `bash` — skills install without the exec bit. `--merge` lands an
already-open request and has its own section below; `--help` lists the rest.

Opening a request leaves the worktree standing. Nothing to `cd` to, nothing
gone — the checkout stays until the request merges, because that is where a red
run gets investigated.

## Relay what it returns

Report the pipeline lines, the `pr:` URL, and the `next:` line as they come —
the script re-reads git and gh after acting, so its output is already reality.

A branch carrying nothing the base lacks is a complete answer: say so and stop.

## Watch the checks

The run ends with a `watch:` line naming the exact command. Run it in the
background and carry on with something else — do not poll it by hand, and do not
sit waiting on it.

Under Claude Code, use `Monitor`: the `watch:` line as `command`, a description
like `CI checks on PR #412`, `timeout_ms: 1380000`, `persistent: false`. The
script prints progress to stderr and exactly one block to stdout when it
settles, so one notification carries the whole verdict. Anywhere else, run it in
the foreground and wait.

`checks.sh` probes immediately, then polls every 5 minutes and gives up after
20. Its flags — `--interval`, `--deadline`, `--grace`, `--once` — take seconds
and exist for tighter loops; `--once` polls a single time and reports.

## Act on the verdict

The `checks:` line says which of four things happened.

**`checks: pass`** — open the request: `gh pr view <url> --web`. Then offer to
land it with `bash ~/.agents/skills/pr/pr.sh --merge` and wait for an answer.
Review is the user's gate; do not walk through it for them.

**`checks: fail`** — open the request the same way, then investigate. Invoking
this skill is the request for it: launch one `general-purpose` agent with the
failing check names from the `failed[...]` block and the `log:` path, and tell
it to:

- read the log and the branch's diff against the base;
- name the root cause of each failing check;
- propose a fix as `file:line` plus a diff sketch, with a confidence; and
- change nothing — no edits, no commits, no PR comments.

The worktree is still there, so it can read the code the failure is about.
Relay its report and ask before applying anything.

**`checks: timeout`** — report what was still pending and the `help:` line that
restarts the watch. Do not launch an agent; nothing has failed yet.

**`checks: none`** — the repository reports no checks. Say so and stop.

## Land it

    bash ~/.agents/skills/pr/pr.sh --merge

Squash-merges the open request, removes the worktree, deletes the branch local
and remote, and fast-forwards the local default branch. This is the one path
that deletes the directory it ran in: when the output carries a `cwd:` line,
`cd` there before running anything else — every later command fails otherwise.

Processes the worktree started — dev servers, watchers — outlive it. `wt remove
--reap <branch>` takes them down, but only run it by hand: it kills every
process whose working directory is under the worktree, which includes the shell
that ran it.

Run it when the user asks, or when they accept the offer after a green run.
Never on your own initiative.

## When it reports an error

Every error carries a `cause:` and a `help:` line — act on the `help:` line.
`published:` says whether anything reached the remote, so you know what is left
behind. On a failed `--merge`, `removed:` says the same about the cleanup.

Two cases stay with the user:

- `approval:` — hand them `wt config approvals add`; never run it yourself.
- The default branch is refused with two runnable options. Ask which they want
  rather than choosing.

## Boundary

`wt merge` has no part in this — it fast-forwards the default branch, so the
work would sit unmerged on local `main` and every branch cut in the meantime
would inherit it. `--merge` catches the default up only after GitHub has merged.

Reviewing the request, re-running failed checks, and fixing what an
investigation proposes are all separate asks.
