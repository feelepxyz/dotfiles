# dotfiles

Personal macOS and Omarchy dotfiles — shared Zsh, Git, Ghostty, editor configs,
and agent skills, with native package lists for each OS.

## Install

```bash
git clone https://github.com/feelepxyz/dotfiles.git ~/.dotfiles && cd ~/.dotfiles
script/setup
```

Requires Git and Node.js/npm for skills. On macOS, install Node via Homebrew or
the existing runtime installer. On Omarchy, `--packages` includes Node and npm.

```bash
script/setup --packages     # also install Homebrew or Arch/OPR + AUR packages
script/setup --skip-skills  # just link dotfiles, offline
```

Setup links tracked files from `home/` at any depth and restores both
`skills/manifest.txt` and `skills/custom/` through `install/skills.sh`. Stage new
files with `git add` before relinking. Existing files and conflicting directories
are moved to `~/.dotfiles-backup.XXXXXX/`; rerunning leaves correct links alone.
Neovim and Pi extensions are linked as whole directories. Other config
directories are kept so unrelated files and agent credentials survive.

Package lists stay in their native formats:

- macOS: `home/.Brewfile` (Homebrew Bundle).
- Omarchy: `install/omarchy.packages` (Arch/OPR) and
  `install/omarchy-aur.packages` (AUR), one package per line, with `#` comments.
  Setup passes them to `omarchy pkg add` and `omarchy pkg aur add`. These are
  personal additions to an existing Omarchy install, not a full system manifest.
  Mac-only apps and tools without a listed Linux package, such as Moshi's hook
  and Doppler, remain separate installs; the Moshi hook runs only when available.

Both platforms use the same Zsh and Ghostty configs. Ghostty starts Zsh directly;
setup does not change your login shell or Omarchy's default terminal selection.
To use Zsh elsewhere too, run `chsh -s "$(command -v zsh)"` and log in again.
Omarchy keeps mise for runtimes; macOS keeps asdf and `home/.tool-versions`.
The Brewfile and `.tool-versions` are only linked on macOS. Input Mono remains the
preferred font, with Omarchy's JetBrainsMono Nerd Font as a fallback.

Git settings are shared, with one small platform include for 1Password signing
and macOS credentials. Enable the 1Password SSH agent and run `gh auth login`
after provisioning a new machine.

`script/strap` remains available for the older full macOS bootstrap (system
settings, Homebrew installation, etc.). It is not needed to link dotfiles.

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
git-compatible VCS), `direnv` (per-dir `.envrc`), `asdf` on macOS / `mise` on
Omarchy (runtime versions), `doppler` (secrets), `jq`, `shellcheck`.

## Reinstalling AI tooling

AI CLIs and runtimes remain separate from dotfile setup. Reprovision them on
demand; skills are also restored by `script/setup`:

```bash
script/setup --packages   # native toolchain + dotfiles + skills
install/runtimes.sh       # macOS: latest node/ruby/rust via asdf; Python via uv
install/ai.sh             # claude, codex, plannotator, pi (curl) + agent skills
```

- **Runtimes**: on macOS, `asdf` manages node/ruby/rust/uv from `home/.tool-versions`.
  On Omarchy, use its existing mise setup (`mise use --global node@lts`, etc.).
  **Python is uv-managed** — use `uv python`, `uv venv`, `uvx`, `uv tool install`.
- **Skills**: restored from `skills/manifest.txt` via `npx skills`. Regenerate the
  manifest from what's installed with `install/skills.sh --generate`. Personal
  skills live in `skills/custom/` (copied by the skills CLI); add one with the
  `add-dotfiles-skill` skill.
- **codex**: run `codex` once to sign in. The **plannotator** Claude plugin loads
  from `home/.claude/settings.json`.

## Setting a repo up

The `setup-repo` skill is the entry point: it reports git hooks, worktrunk and
GitHub settings in one pass, then converges each in the order that costs the
fewest decisions — and lands the local changes in a single commit.

Each area is also its own skill, for when only one of them needs attention:
`setup-git-hooks`, `setup-worktrunk`, `setup-github`.

## Worktrees

`wta` builds a git worktree for agent work and drops the shell in it. Worktrunk
(`wt`) makes the worktree, and the agent is launched for you.

In a repo with `.config/wt.toml`, `wta` launches no agent: that project's
worktrunk hooks open a herdr workspace instead, with the agent and dev servers
already running in their own panes. Write that config with the
`setup-worktrunk` skill.

## Layout

- `home/` — dotfiles; each is symlinked into `$HOME` by `script/setup`.
- `home/.zsh/` — `config`, `aliases`, `scripts`, `autocompletion`.
- `home/.config/` — `starship.toml`, `herdr/`, `ghostty/`, `ripgrep/`.
- `install/`, `script/` — provisioning and bootstrap.

Check setup changes with `python3 script/test-setup.py` and
`shellcheck script/setup install/skills.sh`.

See `AGENTS.md` for how the repo works and tool-preference rules when coding here.
