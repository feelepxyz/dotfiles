---
name: setup-git-hooks
description: Set up, change, or repair a repository's git hooks with prek. Use when the user wants git hooks installed or reconfigured, mentions prek or pre-commit, or reports that hooks stopped running.
disable-model-invocation: true
---

# Set up git hooks

`setup-git-hooks.sh` is the skill. It reads the repository, proposes a hook set
matched to what the project can actually run, and — once the user has confirmed —
writes `prek.toml` and installs the shims.

Yours are the two jobs the script cannot do: getting the user's confirmation, and
wording the README.

## Run it

    bash ~/.agents/skills/setup-git-hooks/setup-git-hooks.sh

Run through `bash` — skills install without the exec bit. No flags inspects and
prints the candidate table; `--apply` writes `prek.toml` and the shims, `--heal`
repairs an existing setup, `--scan` widens detection, `--status` reports. `--help`
lists every flag.

## The main line

1. **Plan.** Run the script with no flags.
2. **Confirm.** Relay the two tables verbatim — the user is choosing from them —
   then ask one `AskUserQuestion` with four options: _Accept recommended_,
   _Customize pre-commit_, _Customize pre-push_, _Customize both_. To customize,
   follow up with a multi-select of that stage's ids, recommended ones first.
3. **Apply.** `--apply --accept`, or `--apply --pre-commit=<ids> --pre-push=<ids>`.
4. **README.** The script reports whether hooks are documented and hands you a
   snippet. Place it to match the README's existing voice and heading style.
   Skip this when the report already says `hooks already documented`.
5. **Verify.** Run `prek run --all-files` and report what it found. Hooks that
   fail here would have blocked the user's next commit, so say so plainly.

Done when `prek.toml` exists, the shims are installed, and step 5 has actually
been run — not merely suggested.

**Apply is declarative.** It writes exactly the ids you name and drops the rest,
so pass the complete list for both stages. Naming no ids for a stage empties it.

**`--extra` offers hooks; the selection still decides.** An extra joins the
candidate table as recommended, so `--accept` takes it. With an explicit
`--pre-commit=`/`--pre-push=` list you must name it there too — passing an extra
you do not name is an error, not a silent drop. Its `stage` field says which list
it belongs in.

**The placement rule:** correctness blocks the commit — formatters, linters,
typecheck, hygiene, secrets. Running the code blocks the push — tests, build.
Use it when the user asks why something sits where it does.

## Heal

When a repo already has prek and something is quietly wrong, `--heal` names the
drift: a stage with hooks but no shim, a shim belonging to husky or another
manager, a hook pointing at an npm script or make target that no longer exists,
a tool missing from PATH, a config that won't parse.

Relay the findings, ask before repairing, then `--heal --fix`.

`--fix` installs and removes shims freely, but it edits the config only when this
skill wrote it. On someone else's config it reports the dead entry and leaves the
file byte-identical — say that rather than editing by hand.

## Scan, and closing the loop

`--scan` is for a repo whose real checks the heuristics miss — a bespoke
`script/` directory, an unfamiliar task runner, a monorepo boundary. Reach for it
when `--plan` finds only builtin hygiene hooks, or when the user says the
proposal missed something.

It prints two extra tables: `detected`, and `probed`. In `probed`, `absent` means
the script looked and found nothing; **`not-probed` means it has no detector for
that marker at all** — that is the gap worth spending a scan on.

Then:

1. Explore the repo yourself and find the checks it really runs.
2. Write them to a JSON array of `{id, name, entry, stage, files, pass_filenames}`
   and apply with `--extra=<file.json>`.
3. **Fold the gap back in** — teach the detectors what the scan found, following
   `references/extending.md`.

## When it reports an error

Every error carries `cause:` and `help:` — act on the `help:` line.

Two are refusals rather than failures, and both are correct:

- **`prek.toml` exists and was not written by this skill**, or the repo already
  uses husky, lefthook, or `.pre-commit-config.yaml`. Nothing was touched.
  Offer `--heal`, the migration path, or `--apply --force` — and let the user
  choose, since `--force` discards their existing setup.
- **unknown hook id** — the valid ids for both stages are printed with it.

## Boundary

Setting hooks up is the whole job. Running them beyond the one verification pass,
authoring new linters, and changing CI happen when the user asks.

For anything about prek itself — its config reference, workspace mode, language
support — use the `prek` skill.
