---
name: hunk
description: Open the working diff, last commit, or branch range in the Hunk terminal viewer — and with `auto`, review it inline.
disable-model-invocation: true
argument-hint: "[auto]"
---

# Hunk

`hunk.sh` is the whole mechanism. It resolves what is worth reviewing, opens it
in a focused Herdr tab under `--watch`, and reports the live session — one
call, a handful of lines back.

## Run it

    bash ~/.claude/skills/hunk/hunk.sh $ARGUMENTS

The script sits beside this file; run it through `bash`, since skills install
without the executable bit.

It picks the target from the repository's own state, so pass nothing else:

| State | What opens |
| --- | --- |
| unstaged or untracked work | the working tree, untracked files included |
| staged work only | the staged changes |
| clean, on the default branch | the last commit |
| clean, on a branch | `<default>...HEAD` |
| clean, branch adds no commits | the last commit, with a `note:` saying why |

A live Hunk session for this repo is reloaded rather than duplicated. Outside
Herdr the script opens nothing and prints a `run:` line — hand that command to
the user, since the viewer is theirs.

## Follow the mode it reports

**`mode: open`** — report the `target:` and stop. The user reviews it.

**`mode: auto`** — you review it:

1. Read the Hunk skill at `$(hunk skill path)` and follow it for every session
   command below.
2. `hunk session review --repo . --json` for the file and hunk structure. Add
   `--include-patch` only for files whose diff text you actually need to read.
3. Review against `~/.claude/CLAUDE.md` — root causes over symptoms, the
   repository's existing conventions, the smallest coherent change.
4. Batch every finding into one `hunk session comment apply --repo . --stdin`
   call, each anchored to the line it concerns.
5. Report the count and the single most consequential finding.

Comment where you carry information the user does not: a root cause, a broken
invariant, a case the change misses. Silence on a hunk is a valid review.

Done when every file in the `session review` listing has been read and judged,
and the batch has landed.

## When it reports an error

Every error carries a `cause:` and a `help:` line — act on the `help:` line.

## Boundary

Reviewing is the whole job. Fixing what the review finds happens when the user
asks for it.
