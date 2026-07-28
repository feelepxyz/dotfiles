---
name: add-dotfiles-skill
description: Scaffold a new personal skill in this dotfiles repo (skills/custom/) and symlink it into Claude/Codex via npx skills. Use when the user wants to create, add, or author a custom or personal agent skill that should live in their dotfiles.
disable-model-invocation: true
---

# Add a dotfiles skill

## Steps

1. Ask for the skill's purpose and a short kebab-case `<name>` if not given.
2. Draft it by invoking `skill-creator` and `writing-great-skills`
3. Create `~/.dotfiles/skills/custom/<name>/SKILL.md` with YAML frontmatter
   (`name`, `description`) and the drafted body. Put any supporting files in the
   same directory.
4. Add agents/openai.yaml
4. When logic can be handled in a script to reduce token usage, look at the axi skill for principles.
5. Symlink it into the agents:

       ~/.dotfiles/install/skills.sh

   (this runs `npx skills add ~/.dotfiles/skills/custom -g -s '*' -a
   claude-code codex pi antigravity-cli`).
6. Confirm: `ls -la ~/.claude/skills/<name>` and `npx skills ls -g`.

After editing `SKILL.md` re-run `~/.dotfiles/install/skills.sh` to resync.
