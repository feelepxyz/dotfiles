---
name: add-dotfiles-skill
description: Scaffold a new personal skill in this dotfiles repo (skills/custom/) and symlink it into Claude via npx skills. Use when the user wants to create, add, or author a custom or personal agent skill that should live in their dotfiles.
---

# Add a dotfiles skill

Create a new personal skill that lives in this dotfiles repo under
`skills/custom/<name>/` and is symlinked into `~/.claude/skills` by `npx skills`.

## Steps

1. Ask for the skill's purpose and a short kebab-case `<name>` if not given.
2. Draft it by invoking the `writing-great-skills` skill (from mattpocock/skills)
   for structure and quality — a tight `description` that says *when* to use the
   skill, and a focused body.
3. Create `~/.dotfiles/skills/custom/<name>/SKILL.md` with YAML frontmatter
   (`name`, `description`) and the drafted body. Put any supporting files in the
   same directory.
4. Symlink it into the agents:

       ~/.dotfiles/install/skills.sh

   (this runs `npx skills add ~/.dotfiles/skills/custom -g -s '*' -a
   claude-code codex pi antigravity-cli`).
5. Confirm: `ls -la ~/.claude/skills/<name>` and `npx skills ls -g`.

`npx skills` copies local skills into the shared store (`~/.agents/skills`) and
symlinks that into each agent, so after editing `SKILL.md` re-run
`~/.dotfiles/install/skills.sh` to resync. Commit the new directory to version it.
