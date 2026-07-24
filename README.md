# dotfiles

Personal macOS dotfiles — shell, git, terminal, and a curated CLI toolchain.

## Install

```bash
git clone https://github.com/feelepxyz/dotfiles.git ~/.dotfiles && cd ~/.dotfiles
script/strap
```

## Tools

These replace the common defaults — prefer the right column.

| Instead of          | Use              | Notes                                              |
| ------------------- | ---------------- | -------------------------------------------------- |
| `cat`               | `bat`            | aliased to `cat`; syntax highlight + paging        |
| `ls`                | `eza` (`l`)      | `l` = `eza -lha --no-user --color=always`          |
| `find`              | `fd`             |                                                    |
| `grep`              | `ripgrep` (`rg`) | flags in `home/.config/ripgrep/config`             |
| `cd`                | `zoxide` (`z`)   | learns your dirs; inited in `.zsh/config`          |
| `tmux`              | `herdr`          | primary multiplexer, prefix `C-;`; tmux kept for Moshi |
| `top`               | `htop`           |                                                    |
| `dig` / `nslookup`  | `doggo`          | DNS client                                         |
| `netstat` / `lsof -i` | `somo`         | sockets / connections                              |
| `git diff`          | `delta`          | pager, side-by-side (in `.gitconfig`)              |
| shell prompt        | `starship`       | config `home/.config/starship.toml`                |
| `ssh` (flaky net)   | `mosh`           | resilient mobile shell                             |

Plus core dev tools: `gh` (GitHub CLI + git credentials/auth), `jj` (Jujutsu,
git-compatible VCS), `direnv` (per-dir `.envrc`), `asdf` (runtime versions from
`.tool-versions`), `doppler` (secrets), `jq`, `shellcheck`.

## Reinstalling AI tooling

These CLIs, runtimes, and agent skills aren't part of `script/strap` (they're
interactive and need logins). Reprovision them on demand:

```bash
brew bundle --global      # base toolchain (asdf, etc.)
install/runtimes.sh       # latest node/ruby/rust via asdf; Python via uv
install/ai.sh             # claude, codex, plannotator, pi (curl) + agent skills
```

- **Runtimes**: `asdf` manages node/ruby/rust/uv from `home/.tool-versions`.
  **Python is uv-managed** — use `uv python`, `uv venv`, `uvx`, `uv tool install`.
- **Skills**: restored from `skills/manifest.txt` via `npx skills`. Regenerate the
  manifest from what's installed with `install/skills.sh --generate`. Personal
  skills live in `skills/custom/` (symlinked in); add one with the
  `add-dotfiles-skill` skill.
- **codex**: run `codex` once to sign in. The **plannotator** Claude plugin loads
  from `home/.claude/settings.json`.

## Layout

- `home/` — dotfiles; each is symlinked into `$HOME` by `script/setup`.
- `home/.zsh/` — `config`, `aliases`, `scripts`, `autocompletion`.
- `home/.config/` — `starship.toml`, `herdr/`, `ghostty/`, `ripgrep/`.
- `install/`, `script/` — provisioning and bootstrap.

See `AGENTS.md` for how the repo works and tool-preference rules when coding here.
