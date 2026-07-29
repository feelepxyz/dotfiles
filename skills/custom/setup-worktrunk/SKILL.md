---
name: setup-worktrunk
description: Set up, change, or repair a repository's worktrunk hooks so a new worktree opens a herdr workspace with the agent and dev servers already running. Use when the user wants `.config/wt.toml` written or fixed, mentions worktrunk project hooks, or reports that `wta` opens a worktree with nothing in it.
disable-model-invocation: true
---

# Set up worktrunk

`setup-worktrunk.sh` is the skill. It reads the repository, proposes the panes a
fresh worktree should open, and — once the user has confirmed — writes
`.config/wt.toml`.

The config has to exist because `wta` steps aside for it: in a repo carrying
`.config/wt.toml`, `wta` launches no agent at all and leaves that to worktrunk's
`post-start` hooks. A config without an agent pane opens a worktree with nothing
running in it.

Yours are the three jobs the script cannot do: getting the user's confirmation,
wording the README, and handing over the approval command.

## Run it

    bash ~/.agents/skills/setup-worktrunk/setup-worktrunk.sh

Run through `bash` — skills install without the exec bit. No flags inspects and
prints the pane and step tables; `--apply` writes `.config/wt.toml`, `--heal`
repairs drift, `--scan` widens detection, `--status` reports. `--help` lists
every flag.

## The main line

1. **Plan.** Run the script with no flags.
2. **Confirm.** Relay both tables verbatim — the user is choosing from them —
   then ask one `AskUserQuestion` with four options: _Accept recommended_,
   _Customize panes_, _Customize steps_, _Customize both_. To customize, follow
   up with a multi-select of that table's ids, recommended ones first.
3. **Apply.** `--apply --accept`, or `--apply --panes=<ids> --steps=<ids>`.
4. **README.** When the report says `worktrees not documented`, the script hands
   you a snippet. Place it to match the README's existing voice and heading
   style.
5. **Approve.** The script ends on `wt config approvals add`. Give the user that
   command and say what it grants. The first `wta <branch>` is the real proof the
   config works, and it is theirs to run — approval has to land first.

Done when `.config/wt.toml` exists, `--status` lists the hooks, and the user has
the approvals command in hand — not merely been told one exists.

**`--extra` offers panes; the selection still decides.** An extra joins the
candidate table as recommended, so `--accept` takes it. With an explicit
`--panes=` list you must name it there too — passing an extra you do not name is
an error, not a silent drop.

**Apply is declarative.** It writes exactly the ids you name and drops the rest,
so pass the complete list. Naming no panes is an error rather than an empty
workspace.

**The layout rule:** the agent owns the root pane and every service splits off
it, because focus is decided at creation — herdr has no `pane focus <id>` verb,
so the agent pane is the one the user lands on. Use this when the user asks why a
pane sits where it does.

## Heal

When a repo already has a config and something is quietly wrong, `--heal` names
the drift: a pane whose directory is gone, a pane running an npm script its own
`package.json` no longer defines, a binary missing from PATH, a component the
repo has grown that no pane covers, a key the installed `wt` has deprecated, a
managed block written before the current generator.

Relay the findings, ask before repairing, then `--heal --fix`.

`--fix` regenerates the config from what the repo runs today, but only when this
skill wrote it. On someone else's config it reports the drift and leaves the file
byte-identical — say that rather than editing by hand.

## Scan, and closing the loop

`--scan` is for a repo whose services the heuristics miss — a bespoke runner, an
unfamiliar framework, a process defined only in CI. Reach for it when `--plan`
finds only the agent pane, or when the user says the proposal missed a service.

It prints a `probed` table. `absent` means the script looked and found nothing;
**`not-probed` means it has no detector for that marker at all** — that is the
gap worth spending a scan on.

Then:

1. Explore the repo yourself and find the processes it really runs.
2. Write them to a JSON array of `{id, dir, command}` and apply with
   `--extra=<file.json>`.
3. **Fold the gap back in** — teach the detectors what the scan found, following
   `references/extending.md`.

## When it reports an error

Every error carries `cause:` and `help:` — act on the `help:` line.

Three are refusals rather than failures, and all three are correct:

- **`.config/wt.toml` exists and this skill did not write it.** Nothing was
  touched. Offer `--heal` or `--apply --force`, and let the user choose, since
  `--force` discards their config.
- **unknown pane id** — the valid ids are printed with it.
- **`approval:` on any run.** The script never approves hooks itself — hand the
  user `wt config approvals add`; never run it yourself.

## Boundary

Writing the config is the whole job. Creating worktrees, running the hooks, and
tuning what the dev servers do happen when the user asks.

For worktrunk itself — its config reference, hook semantics, template filters —
use the `worktrunk` skill. For driving panes in a live session, use the `herdr`
skill.
