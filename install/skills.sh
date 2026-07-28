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
SKILLS="$HOME/.agents/skills"
# `npx skills` wants agents space-separated after -a (a comma list is rejected).
AGENTS=(claude-code codex pi antigravity-cli)

restore() {
  local repo
  local -a fields selectors
  # Read on fd 3: `npx` drains stdin, which would end the loop after one line.
  while read -r -a fields <&3; do
    [ "${#fields[@]}" -eq 0 ] && continue
    repo="${fields[0]}"
    case "$repo" in \#*) continue ;; esac
    selectors=("${fields[@]:1}")
    [ "${#selectors[@]}" -gt 0 ] || selectors=('*')
    echo "==> $repo (${selectors[*]})"
    npx skills@latest add "$repo" -g -s "${selectors[@]}" -a "${AGENTS[@]}" -y
  done 3< "$MANIFEST"

  if [ -d "$CUSTOM" ]; then
    echo "==> custom skills ($CUSTOM)"
    npx skills@latest add "$CUSTOM" -g -s '*' -a "${AGENTS[@]}" -y
  fi
}

# Rebuild manifest.txt from the globally installed skills: refresh each listed
# repo's selectors and append repos the manifest doesn't cover yet. Comment and
# blank lines keep their position, a commented-out repo stays commented out, and a
# repo listed without selectors keeps its implicit '*'.
generate() {
  [ -f "$LOCK" ] || { echo "no lock file at $LOCK" >&2; exit 1; }
  local table tmp line repo rest selectors listed

  # "repo<TAB>skill skill ..." for locked skills that are still on disk; the lock
  # keeps rows for skills that have since been uninstalled.
  table="$(
    jq -r '.skills | to_entries[] | "\(.value.source)\t\(.key)"' "$LOCK" |
      while IFS=$'\t' read -r repo selectors; do
        if [ -e "$SKILLS/$selectors" ]; then printf '%s\t%s\n' "$repo" "$selectors"; fi
      done | sort -u |
      awk -F'\t' '{ s[$1] = s[$1] " " $2 } END { for (r in s) print r "\t" substr(s[r], 2) }' |
      sort
  )"

  tmp="$(mktemp "${TMPDIR:-/tmp}/manifest.XXXXXX")"
  listed=""
  while IFS= read -r line || [ -n "$line" ]; do
    read -r repo rest <<<"$line"
    case "$repo" in
      \#*)
        # A commented-out repo is disabled: record it so it is not re-appended.
        read -r repo _ <<<"${line#*#}"
        case "$repo" in */*) listed="$listed$repo"$'\n' ;; esac
        printf '%s\n' "$line" >> "$tmp"; continue ;;
      '') printf '%s\n' "$line" >> "$tmp"; continue ;;
    esac
    listed="$listed$repo"$'\n'
    selectors="$(printf '%s\n' "$table" | awk -F'\t' -v r="$repo" '$1 == r { print $2 }')"
    # Keep the line as written when it selects '*' or when nothing is installed.
    if [ -z "$rest" ] || [ -z "$selectors" ]; then
      printf '%s\n' "$line" >> "$tmp"
    else
      printf '%s %s\n' "$repo" "$selectors" >> "$tmp"
    fi
  done < "$MANIFEST"

  printf '%s\n' "$table" | while IFS=$'\t' read -r repo selectors; do
    [ -n "$repo" ] || continue
    if printf '%s\n' "$listed" | grep -qxF "$repo"; then continue; fi
    printf '%s %s\n' "$repo" "$selectors" >> "$tmp"
  done

  mv "$tmp" "$MANIFEST"
  echo "regenerated $MANIFEST"
}

case "${1:-}" in
  --generate) generate ;;
  "") restore ;;
  *) echo "usage: skills.sh [--generate]" >&2; exit 2 ;;
esac
