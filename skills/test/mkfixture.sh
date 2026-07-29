#!/usr/bin/env bash
# Build a throwaway git repo carrying every hazard the setup-* skills get wrong,
# and print its path. Nothing here is a skill — this directory sits beside
# skills/custom/ precisely so `install/skills.sh` never publishes it.
#
#   fixture=$(bash mkfixture.sh --foreign-pre-push)
#   ...
#   rm -rf "$fixture"
#
# The hazards, and what each one exists to catch:
#
#   root package.json with only `deploy`  a repo whose real checks all live in
#                                         sub-packages, so root-only detection
#                                         finds nothing
#   factory-model/, factory-model/web/    nested manifests at depth 1 and 2
#   Affärsplan/                           a non-ASCII path — `git ls-files`
#                                         octal-escapes it under the default
#                                         core.quotepath, hiding it completely
#   Affärsplan/vite.config.ts             a Vite app with no `dev` script
#   "Business Plan/"                      a space in a path, which any
#                                         `xargs`/word-splitting walk shreds
#   *.sh at root and under Affärsplan     shell detection across both
#
set -euo pipefail

FOREIGN_PRE_PUSH=false
FOREIGN_PRE_COMMIT=false
CHAINED_PRE_PUSH=false
MANAGED_PREK=false
EXTRA_JSON=false

# A string no generator would ever emit, so a test can assert the exact bytes
# survived rather than merely that *a* file is present.
FOREIGN_MARKER='FIXTURE_FOREIGN_HOOK_DO_NOT_DELETE'

usage() {
	cat <<'EOF'
usage: mkfixture.sh [options]
  --foreign-pre-push   install a non-prek .git/hooks/pre-push carrying a marker
  --foreign-pre-commit same, on pre-commit — the stage detection always fills,
                       so an apply genuinely contends for the slot
  --chained-pre-push   install a foreign pre-push that chains to a prek shim
  --managed-prek       write a MARKER'd prek.toml with one live + one dead entry
  --extra-json         write extra.json (backslash regex, embedded quote, exclude)
  --all                every option above
  -h, --help           this
prints: the fixture path on stdout, one line, nothing else
EOF
}

for arg in "$@"; do
	case "$arg" in
	--foreign-pre-push) FOREIGN_PRE_PUSH=true ;;
	--foreign-pre-commit) FOREIGN_PRE_COMMIT=true ;;
	--chained-pre-push) CHAINED_PRE_PUSH=true ;;
	--managed-prek) MANAGED_PREK=true ;;
	--extra-json) EXTRA_JSON=true ;;
	--all)
		FOREIGN_PRE_PUSH=true
		MANAGED_PREK=true
		EXTRA_JSON=true
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'mkfixture: unknown option %s\n' "$arg" >&2
		usage >&2
		exit 2
		;;
	esac
done

if $FOREIGN_PRE_PUSH && $CHAINED_PRE_PUSH; then
	printf 'mkfixture: --foreign-pre-push and --chained-pre-push are exclusive\n' >&2
	exit 2
fi

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sgh-fixture.XXXXXX")

pkg() {
	# $1 = dir (may be "."), $2 = name, $3.. = "script:command" pairs.
	# Commands may contain double quotes (a real eslint invocation does), so they
	# are escaped on the way in — an unescaped one silently produces invalid JSON
	# and every assertion downstream then fails for the wrong reason.
	local dir=$1 name=$2
	shift 2
	mkdir -p "$ROOT/$dir"
	{
		printf '{\n  "name": "%s",\n  "private": true,\n  "scripts": {\n' "$name"
		local first=true pair cmd
		for pair in "$@"; do
			$first || printf ',\n'
			first=false
			cmd=${pair#*:}
			printf '    "%s": "%s"' "${pair%%:*}" "${cmd//\"/\\\"}"
		done
		printf '\n  }\n}\n'
	} >"$ROOT/$dir/package.json"
}

# Root: the only script is a deploy wrapper. Nothing here is a check, which is
# the whole point — a root-only detector reports an empty repo.
pkg . fixture-root 'deploy:bash deploy/deploy.sh'

pkg factory-model factory-model \
	'test:vitest run' 'typecheck:tsc --noEmit' 'lint:eslint "src/**/*.ts"'

pkg factory-model/web factory-model-web \
	'dev:vite' 'build:vite build' 'typecheck:tsc --noEmit' 'test:vitest run'

# No `dev`/`start`/`serve`/`develop` — the command has to be inferred from the
# vite config beside it.
pkg 'Affärsplan' affarsplan \
	'test:vitest run' 'typecheck:tsc --noEmit' 'build:vite build'

mkdir -p "$ROOT/factory-model/src" "$ROOT/factory-model/web/src" \
	"$ROOT/Affärsplan/src" "$ROOT/Business Plan" "$ROOT/deploy"

printf 'export default {}\n' >"$ROOT/Affärsplan/vite.config.ts"
printf 'export const a = 1\n' >"$ROOT/factory-model/src/index.ts"
printf 'export const b = 2\n' >"$ROOT/factory-model/web/src/main.ts"
printf 'export const c = 3\n' >"$ROOT/Affärsplan/src/app.ts"
printf '# notes\n' >"$ROOT/Business Plan/notes.md"
printf '#!/bin/sh\necho root\n' >"$ROOT/tool.sh"
printf '#!/bin/sh\necho nested\n' >"$ROOT/Affärsplan/tool.sh"
printf '#!/bin/sh\necho deploy\n' >"$ROOT/deploy/deploy.sh"
printf '# Fixture\n\nA throwaway repo.\n' >"$ROOT/README.md"
chmod +x "$ROOT/tool.sh" "$ROOT/Affärsplan/tool.sh" "$ROOT/deploy/deploy.sh"

if $MANAGED_PREK; then
	# One entry naming a script that exists, one naming a script that does not.
	# A correct --heal reports exactly one dead hook.
	cat >"$ROOT/prek.toml" <<'EOF'
# managed by the setup-git-hooks skill — re-run it to change hooks
# regenerate: bash ~/.claude/skills/setup-git-hooks/setup-git-hooks.sh --apply --accept

[[repos]]
repo = "local"

[[repos.hooks]]
id = "factory-model-lint"
name = "factory-model eslint"
language = "system"
entry = "npm --prefix factory-model run lint"
files = "^factory-model/(src|tests|tools)/.*[.]ts$"
pass_filenames = false
stages = ["pre-commit"]

[[repos.hooks]]
id = "factory-model-ghost"
name = "factory-model ghost"
language = "system"
entry = "npm --prefix factory-model run ghost"
files = "^factory-model/(src|tests|tools)/.*[.]ts$"
pass_filenames = false
stages = ["pre-commit"]

# A pre-push hook has to exist for the pre-push shim to be one the skill wants
# to install — without it, a foreign pre-push is never contended for and the
# clobbering path is simply not reached.
[[repos.hooks]]
id = "factory-model-test"
name = "factory-model vitest"
language = "system"
entry = "npm --prefix factory-model test"
files = "^factory-model/(src|tests|tools)/.*[.]ts$"
pass_filenames = false
stages = ["pre-push"]
EOF
fi

if $EXTRA_JSON; then
	# A backslash regex (breaks TOML basic-string interpolation), an embedded
	# double quote in `entry`, and an `exclude` key.
	cat >"$ROOT/extra.json" <<'EOF'
[
  {
    "id": "fixture-lint",
    "name": "fixture eslint",
    "entry": "eslint \"src/**/*.ts\"",
    "stage": "pre-commit",
    "files": "^factory-model/src/.*\\.ts$",
    "exclude": "^factory-model/src/generated/",
    "pass_filenames": false
  }
]
EOF
fi

git -C "$ROOT" init -q
git -C "$ROOT" -c user.email=fixture@example.com -c user.name=Fixture \
	-c commit.gpgsign=false add -A
git -C "$ROOT" -c user.email=fixture@example.com -c user.name=Fixture \
	-c commit.gpgsign=false commit -qm 'fixture' --no-verify

if $FOREIGN_PRE_PUSH; then
	cat >"$ROOT/.git/hooks/pre-push" <<EOF
#!/bin/sh
# $FOREIGN_MARKER
exit 0
EOF
	chmod +x "$ROOT/.git/hooks/pre-push"
fi

if $FOREIGN_PRE_COMMIT; then
	cat >"$ROOT/.git/hooks/pre-commit" <<EOF
#!/bin/sh
# $FOREIGN_MARKER
exit 0
EOF
	chmod +x "$ROOT/.git/hooks/pre-commit"
fi

if $CHAINED_PRE_PUSH; then
	# The healthy arrangement: the chaining tool lands outermost and calls the
	# prek shim it displaced. A skill must read this as fine, not as drift.
	# Copied from a real prek shim, variable indirection and all: prek invokes
	# its entry point as `"$PREK" hook-impl`, never as a `prek hook-impl`
	# literal. A fixture that spelled it literally would let a naive detector
	# pass here and still fail on a real repo.
	cat >"$ROOT/.git/hooks/pre-push.displaced" <<'EOF'
#!/bin/sh
# File generated by prek: https://github.com/j178/prek
PREK="/opt/homebrew/bin/prek"
if [ ! -x "$PREK" ]; then
    PREK="prek"
fi
exec "$PREK" hook-impl --hook-type=pre-push -- "$@"
EOF
	cat >"$ROOT/.git/hooks/pre-push" <<EOF
#!/bin/sh
# $FOREIGN_MARKER
_d="\$(dirname "\$0")"
[ -x "\$_d/pre-push.displaced" ] && "\$_d/pre-push.displaced" "\$@"
EOF
	chmod +x "$ROOT/.git/hooks/pre-push" "$ROOT/.git/hooks/pre-push.displaced"
fi

printf '%s\n' "$ROOT"
