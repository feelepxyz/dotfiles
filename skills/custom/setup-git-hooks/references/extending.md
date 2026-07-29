# Folding a scan gap back into the detectors

Read this after a `--scan` turned up a hook the script's own detection missed.

For each hook you found that the script did not, ask whether a file or naming
rule would catch it in *any* repo:

- **Generalizes** — add a detector to `setup-git-hooks.sh` beside the
  neighbouring ones, drop the marker from `UNKNOWN_MARKERS`, and prove it by
  re-running plain `--plan`. It must find the hook with no scan.
- **Peculiar to this repo** — say so and change nothing.

The script lives in the user's dotfiles, so propose the edit and get consent
before making it.

Edit the source at `~/.dotfiles/skills/custom/setup-git-hooks/`, then re-run
`~/.dotfiles/install/skills.sh` before testing. The installed skill is a
**copy**, not a symlink — an unsynced edit leaves you testing the old script and
reading the result as a failed detector.
