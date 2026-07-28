---
name: setup-entire
description: Turn Entire on in a repository — session tracking, agent hooks, and commit linking. Use when the user wants Entire enabled or set up somewhere, mentions `entire enable`, or reports that their sessions or checkpoints are not being recorded.
disable-model-invocation: true
---

# Set up Entire

`setup-entire.sh` is the skill. It reads what Entire setup the repository already
has, and converges it to: enabled, hooks installed for `claude-code`, `codex`,
`pi` and `gemini`, and `commit_linking: always`.

Yours are the two jobs the script cannot do: deciding whether the repo should
get all four agents, and getting the resulting files committed.

## Run it

    bash ~/.agents/skills/setup-entire/setup-entire.sh

The script sits beside this file; run it through `bash`, since skills install
without the executable bit.

| Mode | Writes | Job |
| --- | --- | --- |
| _(none)_ / `--check` | nothing | Report current state and what is missing |
| `--apply` | `.entire/`, agent hook files | Converge |
| `--apply --agents=a,b` | same | Converge a different agent set |
| `--apply --force` | same | Reinstall hooks that are already present |

## The main line

1. **Check.** Run the script with no flags. It prints `pending[n]` — the exact
   list of what `--apply` would do.
2. **Apply.** `--apply`. It is additive and idempotent: agents already installed
   are left alone, and a converged repo reports a no-op rather than churning.
3. **Commit.** The script lists the changed paths under `changed[]`. Review them
   and commit — `.claude/`, `.codex/`, `.gemini/`, `.pi/` and
   `.entire/settings.json` all belong in the repo.
4. **Verify.** `entire status` should report `Enabled` and name the four agents.

Done when step 4 has actually been run, not merely suggested.

**`--apply` is convergent, not declarative.** Naming fewer agents with
`--agents=` installs fewer — it never removes one already there. Removing is
`entire agent remove <name>`.

## Three facts worth not re-deriving

These are why the script exists instead of four inline `entire enable` calls.

**Never run `entire enable` outside a git repository.** With `-y` it will
initialise a repo *and create a private GitHub repo* for it. The script refuses
outside a repo and passes `--no-init-repo` on every call, so running it is safe
where running the raw command is not.

**`entire enable` destroys `.entire/settings.local.json`.** If that file already
exists, enable replaces its entire contents with `{"enabled": true}` — it does
not merge, and `--project` does not stop it. So adding one agent to a repo that
already has `commit_linking: always` silently drops the setting. The script
snapshots the file before enabling and folds it back afterwards. If you ever run
the raw command against a repo with local settings, check that file afterwards.

**`commit_linking` is yours, not the team's.** It lives in that same
gitignored `.entire/settings.local.json`. The only accepted values are `always`
and `prompt` — any other makes *every* `entire` command fail to load settings,
which is why the script rejects a bad `--commit-linking=` before writing.

## When it reports an error

Every error carries `cause:` and `help:` — act on the `help:` line. The ones you
will actually hit:

- **not a git repository** — the safety refusal above. `cd` somewhere real.
- **not logged in** — `entire login`, then re-run.
- **`entire` not found** — `brew install entire`.
- **settings.local.json is not valid JSON** — the script refuses rather than
  discard whatever the user put there. Show them the file; let them decide.

## Boundary

Setting Entire up is the whole job. Diagnosing an existing setup that has
drifted is `entire doctor`. Reading history out of Entire — checkpoints,
sessions, prior intent — is the `using-entire`, `explain`, `recall` and `search`
skills, which are installed globally and need nothing per-repo.
