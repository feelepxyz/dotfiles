#!/usr/bin/env bash
# Restore agent skills from skills/manifest.txt via `npx skills`, then install the
# repo's own custom skills. Skills install globally and symlink into ~/.claude/skills.
#   install/skills.sh             restore from manifest + custom skills
#   install/skills.sh --generate  rebuild manifest.txt from currently installed skills
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES="$(dirname "$DIR")"
MANIFEST="$DOTFILES/skills/manifest.txt"
CUSTOM="$DOTFILES/skills/custom"
LOCK="$HOME/.agents/.skill-lock.json"
# `npx skills` wants agents space-separated after -a (a comma list is rejected).
AGENTS=(claude-code codex pi antigravity-cli)

restore() {
  local repo
  local -a fields selectors
  while read -r -a fields; do
    [ "${#fields[@]}" -eq 0 ] && continue
    repo="${fields[0]}"
    case "$repo" in \#*) continue ;; esac
    selectors=("${fields[@]:1}")
    [ "${#selectors[@]}" -gt 0 ] || selectors=('*')
    echo "==> $repo (${selectors[*]})"
    npx skills@latest add "$repo" -g -s "${selectors[@]}" -a "${AGENTS[@]}" -y
  done < "$MANIFEST"

  if [ -d "$CUSTOM" ]; then
    echo "==> custom skills ($CUSTOM)"
    npx skills@latest add "$CUSTOM" -g -s '*' -a "${AGENTS[@]}" -y
  fi
}

# Rebuild manifest.txt as the union of its current repos and the live global lock,
# preserving comment lines and dropping anything listed in the `# excluded:` header.
generate() {
  [ -f "$LOCK" ] || { echo "no lock file at $LOCK" >&2; exit 1; }
  local header excluded body repo
  header="$(grep '^#' "$MANIFEST")"
  excluded="$(sed -n 's/^# excluded: *//p' "$MANIFEST")"
  body="$(
    { grep -vE '^#|^[[:space:]]*$' "$MANIFEST" | awk '{print $1}'
      jq -r '.skills[].source' "$LOCK"
    } | sort -u
  )"
  for repo in $excluded; do
    body="$(printf '%s\n' "$body" | grep -vxF "$repo" || true)"
  done
  printf '%s\n%s\n' "$header" "$body" > "$MANIFEST"
  echo "regenerated $MANIFEST"
}

case "${1:-}" in
  --generate) generate ;;
  "") restore ;;
  *) echo "usage: skills.sh [--generate]" >&2; exit 2 ;;
esac
