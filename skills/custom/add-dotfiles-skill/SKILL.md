---
name: add-dotfiles-skill
description: Scaffold a new personal skill in this dotfiles repo (skills/custom/) and install it into Claude/Codex/pi via npx skills. Use when the user wants to create, add, or author a custom or personal agent skill that should live in their dotfiles.
disable-model-invocation: true
---

# Add a dotfiles skill

## Steps

1. Ask for the skill's purpose and a short kebab-case `<name>` if not given.
2. Draft it by invoking `skill-creator` and `writing-great-skills`.
3. Create `~/.dotfiles/skills/custom/<name>/SKILL.md` with YAML frontmatter
   (`name`, `description`) and the drafted body. Put any supporting files in the
   same directory.
   - Add `disable-model-invocation: true` unless the skill should fire on its
     own. Only a model-invocable skill's description is loaded into every
     session; a disabled one costs nothing until the user types `/<name>`.
4. Add `agents/openai.yaml`, with `allow_implicit_invocation` matching that
   choice.
5. When logic can move into a script to cut tokens, follow the `axi` skill.
6. Install it:

       ~/.dotfiles/install/skills.sh

   (this runs `npx skills add ~/.dotfiles/skills/custom -g -s '*' -a
   claude-code codex pi antigravity-cli`).
7. Confirm: `ls -la ~/.agents/skills/<name>` and `npx skills ls -g`.

Install **copies** the source into `~/.agents/skills/<name>` and symlinks the
per-agent directories at it — so after every edit to a `SKILL.md` or a script,
re-run `~/.dotfiles/install/skills.sh` or you are testing the old copy.
