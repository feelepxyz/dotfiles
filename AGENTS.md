# Working in this repo

This repo provisions a macOS dev environment. Prefer the installed modern tools
over the common defaults.

## Prefer these tools

- Search / nav: `rg` over grep, `fd` over find, `eza` / `l` over ls, `bat` over
  cat, `z` (zoxide) over cd.
- Git: `delta` is the diff pager; `main` is the default branch; rebase-by-default;
  commits are SSH-signed via 1Password. Handy aliases: `g`, `git c/com/s/co/cob/l/lg`.
  `jj` (Jujutsu) is available as a git-compatible alternative.
- Multiplexer: use `herdr` (prefix `C-;`), not tmux. tmux stays only for Moshi.
- GitHub: `gh`. Secrets: `doppler`. JSON: `jq`. Lint shell: `shellcheck`.
- Runtimes come from `asdf` + `home/.tool-versions` (ruby / node / rust / uv);
  Python is uv-managed (`uv python`), not asdf. See README "Reinstalling AI tooling".
- Prompt and env: starship + direnv are already inited in `.zsh/config`.

## How this repo works

- Edit files under `home/`; they are symlinked into `$HOME`, so edits are live.
- Relink after adding files: `script/setup`. Full bootstrap: `script/strap`.
- Add a tool: add it to `home/.Brewfile`, then `brew bundle --global`
  (or `script/brewfile-update`). Don't commit `home/.Brewfile.lock.json` (gitignored).
- Shell scripts: run `shellcheck` before committing.
- Commits: terse, imperative, sentence-case (e.g. "Update brew", "Fix eza").
  This repo does not use conventional-commit prefixes.

See `README.md` for the full default→modern tool table and repo layout.
