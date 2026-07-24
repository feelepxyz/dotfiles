#!/usr/bin/env bash
# Reinstall the AI CLIs via their self-updating standalone installers, then
# restore agent skills. Re-runnable: each installer updates in place. Not run by
# strap (interactive + needs logins) — invoke manually when reprovisioning.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> claude"
curl -fsSL https://claude.ai/install.sh | bash

echo "==> codex"
curl -fsSL https://chatgpt.com/codex/install.sh | sh

echo "==> plannotator"
curl -fsSL https://plannotator.ai/install.sh | bash

echo "==> pi"
curl -fsSL https://pi.dev/install.sh | sh

echo "==> pi extensions"
( cd "$DIR/../home/.pi" && npm install )

echo "==> skills"
"$DIR/skills.sh"

cat <<'EOF'

Done. Follow-ups:
  - Run `codex` once to sign in.
  - Open Claude; the plannotator plugin loads from ~/.claude/settings.json.
    If it doesn't, run inside Claude:
      /plugin marketplace add backnotprop/plannotator
      /plugin install plannotator@plannotator
EOF
