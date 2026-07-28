---
name: setup-github
description: Converge a GitHub repository's settings — merge hygiene, a guardrail ruleset on the default branch, Dependabot and secret scanning. Use when the user wants branch protection or a ruleset on a repo, asks for GitHub repo housekeeping, or reports that merged branches are not being deleted.
disable-model-invocation: true
---

# Set up GitHub housekeeping

`setup-github.sh` is the skill. It probes what the repository already has and
converges the items the user picks.

Yours is the one job the script cannot do: getting the user's confirmation.
These settings live on GitHub, not in the repo, so everyone with access sees
them the moment they land — `--apply` therefore refuses to imply a set.

## Run it

    bash ~/.agents/skills/setup-github/setup-github.sh

The script sits beside this file; run it through `bash`, since skills install
without the executable bit.

| Mode | Writes | Job |
| --- | --- | --- |
| _(none)_ / `--plan` | nothing | Probe and print the item table |
| `--apply --accept` | GitHub settings | Take the recommended set |
| `--apply --items=a,b` | GitHub settings | Take an exact selection |
| `--status` | nothing | What is set right now |

`--repo=owner/name` acts on a repo you are not sitting in. `--force` adds the
ruleset alongside a foreign one that already governs the default branch.

## The main line

1. **Plan.** Run the script with no flags.
2. **Confirm.** Relay the item table verbatim — the user is choosing from it —
   then ask one `AskUserQuestion` with three options: _Accept recommended_,
   _Customize items_, _Skip GitHub_. To customize, follow up with a multi-select
   of the ids, recommended ones first.
3. **Apply.** `--apply --accept`, or `--apply --items=<ids>`.
4. **Verify.** The script re-reads the repo and prints an `achieved[]` table.
   Report it. Any row that did not reach its target is a failure to say plainly.

Done when step 4 has actually been run, not merely suggested. Nothing here needs
committing — say so, rather than leaving the user looking for a diff.

**Apply is declarative per item, convergent overall.** It writes only the items
you name and leaves the rest untouched; it never turns a setting off.

## Four facts worth not re-deriving

**Signing is deliberately not required.** The ruleset carries `deletion` and
`non_fast_forward` — nothing else. Adding `required_signatures` would gate agent
commits on a signing key being present, which is the opposite of what this setup
is for. If the repo also has classic protection requiring signatures, the script
says so: classic and rulesets both enforce, and the stricter one wins.

**Rulesets, not classic branch protection.** Classic protection needs a paid plan
on a private repo; rulesets work on every repo this account owns. Classic
protection that already exists is reported in full and **never touched** —
removing it is the user's call, not `--apply`'s.

**`unknown` is not `off`.** Without admin, the API omits `security_and_analysis`
and 404s both Dependabot endpoints, which looks exactly like those features being
disabled. The script reports `unknown` instead of proposing changes it cannot
verify. Relay that distinction rather than flattening it to "off".

**Ownership is the ruleset's name.** Rulesets carry no comment field, so
`default-branch-guardrails` is the only handle this skill has. A ruleset by that
name is treated as ours and converged; any other one reaching the default branch
blocks `--apply` until the user chooses `--force`.

## When it reports an error

Every error carries `cause:` and `help:` — act on the `help:` line. The ones you
will actually hit:

- **no admin permission** — `--plan` still works and reports read-only. Nothing
  short of the user getting admin will change that.
- **a foreign ruleset governs the default branch** — a refusal, and a correct
  one. Show the user what it is and let them choose `--force`.
- **`gh` not found / not logged in** — `brew install gh`, then `gh auth login`.

`github: skipped — no github remote` is not an error. The repo simply has no
GitHub side to converge; the exit code is 0.

## Boundary

Converging an existing repo's settings is the whole job. Creating the repository,
authoring workflows, changing org-level settings, and removing classic branch
protection happen when the user asks.
