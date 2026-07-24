#!/usr/bin/env bash
# Provision language runtimes. Interactive: installs the latest node/ruby/rust
# (and uv) via asdf and pins them in ~/.tool-versions. Python is managed by uv,
# not asdf — installed after uv is in place.
set -euo pipefail

confirm() {
  read -r -p "$1 [Y/n] " reply
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

asdf_latest() {
  local plugin="$1" version
  asdf plugin list 2>/dev/null | grep -qx "$plugin" || asdf plugin add "$plugin"
  asdf plugin update "$plugin"
  version="$(asdf latest "$plugin")"
  if confirm "Install $plugin $version (latest) and pin it?"; then
    asdf install "$plugin" "$version"
    asdf set -u "$plugin" "$version"
    echo "pinned $plugin $version"
  else
    echo "skipped $plugin"
  fi
}

for plugin in nodejs ruby rust uv; do
  asdf_latest "$plugin"
done

echo "==> python (via uv)"
if confirm "Install the latest CPython with uv?"; then
  asdf reshim uv &>/dev/null || true
  uv python install
  uv python list
fi

echo
echo "Python is uv-managed: use uv python, uv venv, uvx, uv tool install."
