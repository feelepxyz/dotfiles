# Working in this repo

This repo provisions macOS and Omarchy dev environments. Prefer installed modern tools
over the common defaults.

## Prefer these tools

- Search / nav: `rg` over grep, `fd` over find, `eza` / `l` over ls, `bat` over
  cat, `z` (zoxide) over cd.
- Git: `hunk pager` is the diff pager; `main` is the default branch; rebase-by-default;
  commits are SSH-signed via 1Password. Handy aliases: `g`, `git c/com/s/co/cob/l/lg`.
  `jj` (Jujutsu) is available as a git-compatible alternative.
- Multiplexer: use `herdr` (prefix `C-;`), not tmux.
- GitHub: `gh`. Secrets: `doppler`. JSON: `jq`. Lint shell: `shellcheck`.
- macOS runtimes come from `asdf` + `home/.tool-versions` (ruby / node / rust / uv);
  Omarchy uses its existing `mise` installation.
  Python is uv-managed (`uv python`), not asdf. See README "Reinstalling AI tooling".
- Prompt and env: starship + direnv are already inited in `.zsh/config`.

## How this repo works

- Edit files under `home/`; they are symlinked into `$HOME`, so edits are live.
- Stage new files before relinking: `script/setup` links tracked files and restores
  skills. Use `--skip-skills` for offline relinking, `--packages` for native packages.
  Full macOS bootstrap: `script/strap`.
- Add macOS tools to `home/.Brewfile`; Omarchy additions go in
  `install/omarchy.packages` or `install/omarchy-aur.packages`. Keep native formats.
  Don't commit `home/.Brewfile.lock.json` (gitignored).
- Shell scripts: run `shellcheck` before committing.

See `README.md` for the full default→modern tool table and repo layout.
