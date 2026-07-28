#!/usr/bin/env bash
# shellcheck disable=SC2016 # backticks in help prose are literal markup, not substitution
# Inspect a repository, propose git hooks matched to what it can actually run,
# write prek.toml, and install the shims.
#
# Output follows AXI conventions: structured key/value and TOON tables on stdout
# (errors included), progress on stderr, exit 0 for success and no-ops, 1 for
# errors, 2 for usage.
#
# Invoke with `bash setup-git-hooks.sh` — `npx skills` copies skill files without
# the executable bit, so a direct exec would fail.

set -uo pipefail

SELF=${BASH_SOURCE[0]}
MARKER="# managed by the setup-git-hooks skill"

MODE=plan
ACCEPT=false
FIX=false
FORCE=false
SEL_PRE_COMMIT=""
SEL_PRE_PUSH=""
SEL_GIVEN=false
EXTRA_FILE=""

usage() {
	printf 'bin: %s\n' "${SELF/#$HOME/\~}"
	printf 'description: Set up prek git hooks matched to this repository\n'
	printf 'modes[5]{mode,writes,job}:\n'
	printf '  --plan,nothing,"Inspect the repo and print the candidate hook table (default)"\n'
	printf '  --scan,nothing,"--plan plus a detection baseline and probe list for an agent deep-scan"\n'
	printf '  --apply,"prek.toml + shims","Write the config and install the git shims"\n'
	printf '  --heal,nothing,"Diagnose an existing prek setup"\n'
	printf '  --status,nothing,"Report what is configured and installed right now"\n'
	printf 'flags[6]{flag,effect}:\n'
	printf '  --accept,"With --apply: take the recommended set"\n'
	printf '  --pre-commit=a\\,b,"With --apply: the exact pre-commit hook ids"\n'
	printf '  --pre-push=a\\,b,"With --apply: the exact pre-push hook ids"\n'
	printf '  --extra=<file.json>,"With --apply: merge agent-discovered hooks"\n'
	printf '  --fix,"With --heal: perform the safe repairs"\n'
	printf '  --force,"With --apply: overwrite a config this skill does not manage"\n'
	printf 'examples[3]:\n'
	printf '  bash %s\n' "${SELF/#$HOME/\~}"
	printf '  bash %s --apply --accept\n' "${SELF/#$HOME/\~}"
	printf '  bash %s --apply --pre-commit=lint,typecheck --pre-push=test\n' "${SELF/#$HOME/\~}"
}

flag_error() {
	printf 'error: %s\n' "$1"
	printf 'help: valid flags: --plan --scan --apply --heal --status --accept --pre-commit= --pre-push= --extra= --fix --force --help\n'
	exit 2
}

for arg in "$@"; do
	case "$arg" in
	--plan) MODE=plan ;;
	--scan) MODE=scan ;;
	--apply) MODE=apply ;;
	--heal) MODE=heal ;;
	--status) MODE=status ;;
	--accept) ACCEPT=true ;;
	--fix) FIX=true ;;
	--force) FORCE=true ;;
	--pre-commit=*)
		SEL_PRE_COMMIT=${arg#--pre-commit=}
		SEL_GIVEN=true
		;;
	--pre-push=*)
		SEL_PRE_PUSH=${arg#--pre-push=}
		SEL_GIVEN=true
		;;
	--extra=*) EXTRA_FILE=${arg#--extra=} ;;
	-h | --help)
		usage
		exit 0
		;;
	*) flag_error "unknown flag $arg" ;;
	esac
done

# Reject flags that do not apply to the chosen mode, rather than dropping them
# silently — a swallowed --accept would look like a deliberate empty selection.
if [ "$MODE" != apply ]; then
	[ "$ACCEPT" = true ] && flag_error "--accept only applies to --apply"
	[ "$SEL_GIVEN" = true ] && flag_error "--pre-commit=/--pre-push= only apply to --apply"
	[ -n "$EXTRA_FILE" ] && flag_error "--extra= only applies to --apply"
	[ "$FORCE" = true ] && flag_error "--force only applies to --apply"
fi
if [ "$MODE" != heal ] && [ "$FIX" = true ]; then
	flag_error "--fix only applies to --heal"
fi
if [ "$MODE" = apply ] && [ "$ACCEPT" = false ] && [ "$SEL_GIVEN" = false ]; then
	printf 'error: --apply needs a selection\n'
	printf 'cause: neither --accept nor an explicit hook list was given\n'
	printf 'help: run --plan first, then --apply --accept or --apply --pre-commit=a,b --pre-push=c\n'
	exit 2
fi

# --- locate the repository -------------------------------------------------

if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || [ -z "$REPO_ROOT" ]; then
	printf 'error: not a git repository\n'
	printf 'cwd: %s\n' "${PWD/#$HOME/\~}"
	printf 'help: cd into a repository, or run `git init` to start one here\n'
	exit 2
fi
REPO=$(basename "$REPO_ROOT")
CONFIG="$REPO_ROOT/prek.toml"
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd)
HOOKS_DIR="${GIT_COMMON:-$REPO_ROOT/.git}/hooks"

# --- locate prek -----------------------------------------------------------

if ! PREK=$(command -v prek 2>/dev/null); then
	printf 'error: `prek` not found on PATH\n'
	printf 'repo: %s\n' "$REPO"
	printf 'cause: prek is the hook runner this skill configures\n'
	printf 'help: install it with `brew install prek` (or `uv tool install prek`, `mise use prek`)\n'
	exit 1
fi

have() { command -v "$1" >/dev/null 2>&1; }

if ! have jq; then
	printf 'error: `jq` not found on PATH\n'
	printf 'repo: %s\n' "$REPO"
	printf 'cause: package.json and --extra parsing read JSON through jq\n'
	printf 'help: install it with `brew install jq`\n'
	exit 1
fi

# --- tracked-file index ----------------------------------------------------
# Read the tree once. Detection asks this index questions rather than shelling
# out per toolchain.

# core.quotepath defaults to true, which makes ls-files wrap any path containing
# a non-ASCII byte in double quotes and octal-escape it — `Affärsplan/tool.sh`
# arrives as `"Aff\303\244rsplan/tool.sh"`, so a $-anchored pattern misses it and
# the file is invisible to detection with no error anywhere.
TRACKED=$(git -C "$REPO_ROOT" -c core.quotepath=false ls-files 2>/dev/null)

tracked_matches() { printf '%s\n' "$TRACKED" | grep -qE "$1"; }

# --- probes ----------------------------------------------------------------
# Every path a detector looks at is recorded with what it saw, so --scan can
# show where detection has been and where it has never looked.

PROBES=()

probe() {
	if [ -e "$REPO_ROOT/$1" ]; then
		PROBES+=("$1|present")
		return 0
	fi
	PROBES+=("$1|absent")
	return 1
}

# Markers this script knows exist in the world but has no detector for. When one
# is present it is reported as `not-probed` — the signal that a scan is worth
# spending, and that a detector is worth adding afterwards.
UNKNOWN_MARKERS="deno.json deno.jsonc mix.exs build.gradle build.gradle.kts pom.xml CMakeLists.txt composer.json pubspec.yaml Package.swift turbo.json nx.json bacon.toml"

# --- candidates ------------------------------------------------------------
# One record per candidate hook:
#   id|kind|stage|recommended|source|entry|files|pass_filenames|exclude|name
# kind is `builtin` or `local`. Generated configs never pin a remote repo: a
# repo's own script already uses the version the project pinned, and a second
# pinned copy would need network and `prek update` to stay honest.

CAND=()

# ASCII unit separator. A pipe would be the obvious delimiter, but the `files`
# regexes below are full of alternations — every record would shred itself.
SEP=$'\037'

add_cand() {
	# $9 (exclude) and ${10} (display name) are optional: the detectors below set
	# neither, but a hook arriving through --extra can carry both.
	CAND+=("$1$SEP$2$SEP$3$SEP$4$SEP$5$SEP$6$SEP$7$SEP$8$SEP${9:-}$SEP${10:-$1}")
}

cand_field() {
	# $1 = record, $2 = 1-based field index
	printf '%s' "$1" | cut -d"$SEP" -f"$2"
}

has_cand() {
	local rec
	for rec in "${CAND[@]:-}"; do
		[ -n "$rec" ] || continue
		[ "$(cand_field "$rec" 1)" = "$1" ] && return 0
	done
	return 1
}

TOOLCHAINS=()

# Render a raw string as a TOML basic string, quotes included. Regexes are full
# of backslashes and a TOML basic string eats them, so every string written into
# the generated config goes through here. Keeping the values raw means the same
# regex can also be handed to grep or prek directly without a second dialect.
toml_basic() {
	local s=$1
	s=${s//\\/\\\\}
	s=${s//\"/\\\"}
	s=${s//$'\t'/\\t}
	s=${s//$'\n'/\\n}
	s=${s//$'\r'/\\r}
	printf '"%s"' "$s"
}

RE_JS='\.(js|jsx|mjs|cjs|ts|tsx|mts|cts|vue|svelte)$'
RE_JS_WIDE='\.(js|jsx|mjs|cjs|ts|tsx|mts|cts|vue|svelte|json|md|mdx|css|scss|ya?ml|html)$'
RE_TS='\.(ts|tsx|mts|cts|vue|svelte)$'
RE_RS='\.rs$'
RE_PY='\.py$'
RE_GO='\.go$'
RE_RB='\.(rb|rake)$'
RE_SH='\.(sh|bash)$'

# Files that carry a .json extension but are really JSONC — comments and trailing
# commas are legal in them, so a strict JSON check fails on every commit forever.
RE_JSONC='(^|/)(tsconfig|jsconfig|devcontainer)\.json$|(^|/)\.vscode/'

# The one place a *builtin* hook declares files to skip. Keyed by id so the
# detectors stay free of per-hook special cases. A hook from --extra carries its
# own exclude in the record instead, so it takes precedence when set.
cand_exclude() {
	case "$1" in
	check-json) printf '%s' "$RE_JSONC" ;;
	esac
	return 0
}

# --- detector: node --------------------------------------------------------

# Walk every tracked package.json, not just the root one. A repo whose real
# checks all live in sub-packages — a root manifest carrying nothing but a
# `deploy` script — otherwise reports no hooks at all, with no error to say why.
detect_node() {
	local manifest dir
	probe package.json && detect_node_at "."

	while IFS= read -r manifest; do
		dir=${manifest%/*}
		[ -n "$dir" ] || continue
		dormant_dir "$dir" && continue
		probe "$manifest" && detect_node_at "$dir"
	done < <(printf '%s\n' "$TRACKED" |
		grep -E '(^|/)package\.json$' | grep '/' | awk -F/ 'NF<=3' | sort -u)
	return 0
}

# Directories that exist to be read, not run. A fixture's package.json is not a
# check this repo wants on every commit.
dormant_dir() {
	case "$1" in
	*/node_modules/* | node_modules/*) return 0 ;;
	*/fixtures/* | fixtures/* | */fixture/* | fixture/*) return 0 ;;
	*/examples/* | examples/* | */example/* | example/*) return 0 ;;
	*/vendor/* | vendor/* | */third_party/* | third_party/*) return 0 ;;
	*/__tests__/* | */testdata/* | testdata/*) return 0 ;;
	esac
	return 1
}

# A hook id derived from a directory path. Folds accents so `Affärsplan` becomes
# `affarsplan` rather than a run of dashes or an invalid byte — the id is also a
# --pre-commit= selector, so it has to be typeable.
ascii_slug() {
	local s=$1 out
	out=$(printf '%s' "$s" | iconv -f UTF-8 -t UTF-8-MAC 2>/dev/null |
		iconv -f UTF-8 -t ASCII//IGNORE 2>/dev/null)
	printf '%s' "$out" | LC_ALL=C grep -q '[^ -~]' && out=""
	[ -n "$out" ] || out=$(printf '%s' "$s" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null)
	printf '%s' "$out" | LC_ALL=C grep -q '[^ -~]' && out=$s
	printf '%s' "$out" | tr '[:upper:]' '[:lower:]' |
		tr -c '[:alnum:]' '-' | sed 's/-\{1,\}/-/g; s/^-//; s/-$//'
}

# The package manager for one component: its own lockfile first, the root's
# second, matching how a monorepo actually resolves.
node_pm_at() {
	local d=$1 p pre
	for p in "$d" "."; do
		pre=""
		[ "$p" != "." ] && pre="$p/"
		[ -e "$REPO_ROOT/${pre}pnpm-lock.yaml" ] && {
			printf pnpm
			return 0
		}
		[ -e "$REPO_ROOT/${pre}yarn.lock" ] && {
			printf yarn
			return 0
		}
		{ [ -e "$REPO_ROOT/${pre}bun.lock" ] || [ -e "$REPO_ROOT/${pre}bun.lockb" ]; } && {
			printf bun
			return 0
		}
	done
	printf npm
}

# Escape a path for use inside a `files` regex.
regex_escape() {
	printf '%s' "$1" | sed 's/[][(){}.*+?^$|\\/]/\\\\&/g'
}

detect_node_at() {
	local dir=$1 pre="" idpre="" scoped="" pmname scripts name entry
	if [ "$dir" != "." ]; then
		pre="$dir/"
		# Namespace the ids: three sub-packages each offering `test` would
		# otherwise collide, and has_cand dedups on the bare id.
		idpre="$(ascii_slug "$dir")-"
		# Scope the hook to its own package, so a commit touching only one
		# sub-package does not run every other one's checks.
		scoped="^$(regex_escape "$dir")/.*"
	fi

	pmname=$(node_pm_at "$dir")

	scripts=$(jq -r '.scripts // {} | keys[]' "$REPO_ROOT/${pre}package.json" 2>/dev/null)
	[ -z "$scripts" ] && return 0
	case " ${TOOLCHAINS[*]:-} " in
	*" node($pmname) "*) ;;
	*) TOOLCHAINS+=("node($pmname)") ;;
	esac

	# Prefer a non-mutating :check variant when the repo offers both.
	pick() {
		local want
		for want in "$@"; do
			if printf '%s\n' "$scripts" | grep -qx "$want"; then
				printf '%s' "$want"
				return 0
			fi
		done
		return 1
	}

	# `npm --prefix <dir> run <script>` keeps one root config while each hook
	# resolves against its own manifest. yarn v2+ dropped --cwd; it is left on
	# the v1 spelling here rather than guessed at.
	run_entry() {
		if [ "$dir" = "." ]; then
			printf '%s run %s' "$pmname" "$1"
			return 0
		fi
		case "$pmname" in
		pnpm) printf 'pnpm -C %s run %s' "$dir" "$1" ;;
		yarn) printf 'yarn --cwd %s run %s' "$dir" "$1" ;;
		bun) printf 'bun run --cwd %s %s' "$dir" "$1" ;;
		*) printf 'npm --prefix %s run %s' "$dir" "$1" ;;
		esac
	}

	if name=$(pick format:check fmt:check format fmt prettier); then
		entry=$(run_entry "$name")
		add_cand "${idpre}format" local pre-commit 1 "${pre}package.json" "$entry" "${scoped}${RE_JS_WIDE}" false
	fi
	if name=$(pick lint lint:check eslint biome oxlint); then
		entry=$(run_entry "$name")
		add_cand "${idpre}lint" local pre-commit 1 "${pre}package.json" "$entry" "${scoped}${RE_JS}" false
	fi
	if name=$(pick typecheck type-check check-types types tsc); then
		entry=$(run_entry "$name")
		add_cand "${idpre}typecheck" local pre-commit 1 "${pre}package.json" "$entry" "${scoped}${RE_TS}" false
	fi
	if name=$(pick test test:unit); then
		entry=$(run_entry "$name")
		add_cand "${idpre}test" local pre-push 1 "${pre}package.json" "$entry" "${scoped}${RE_JS}" false
	fi
	if name=$(pick build); then
		entry=$(run_entry "$name")
		add_cand "${idpre}build" local pre-push 0 "${pre}package.json" "$entry" "${scoped}${RE_JS}" false
	fi
	return 0
}

# --- detector: rust --------------------------------------------------------

detect_rust() {
	probe Cargo.toml || return 0
	TOOLCHAINS+=(rust)
	add_cand cargo-fmt local pre-commit 1 Cargo.toml "cargo fmt --check" "$RE_RS" false
	add_cand cargo-clippy local pre-commit 1 Cargo.toml "cargo clippy --all-targets -- -D warnings" "$RE_RS" false
	add_cand cargo-test local pre-push 1 Cargo.toml "cargo test" "$RE_RS" false
	add_cand cargo-build local pre-push 0 Cargo.toml "cargo build" "$RE_RS" false
	return 0
}

# --- detector: python ------------------------------------------------------

detect_python() {
	probe pyproject.toml || return 0
	TOOLCHAINS+=(python)
	local run=""
	probe uv.lock && run="uv run "
	local py
	py=$(cat "$REPO_ROOT/pyproject.toml" 2>/dev/null)

	if printf '%s' "$py" | grep -qi 'ruff'; then
		add_cand ruff-format local pre-commit 1 pyproject.toml "${run}ruff format --check" "$RE_PY" false
		add_cand ruff local pre-commit 1 pyproject.toml "${run}ruff check" "$RE_PY" false
	fi
	if printf '%s' "$py" | grep -qi 'mypy'; then
		add_cand mypy local pre-commit 1 pyproject.toml "${run}mypy ." "$RE_PY" false
	elif printf '%s' "$py" | grep -qi 'pyright'; then
		add_cand pyright local pre-commit 1 pyproject.toml "${run}pyright" "$RE_PY" false
	fi
	if printf '%s' "$py" | grep -qi 'pytest' || tracked_matches '^tests?/'; then
		add_cand pytest local pre-push 1 pyproject.toml "${run}pytest" "$RE_PY" false
	fi
	return 0
}

# --- detector: go ----------------------------------------------------------

detect_go() {
	probe go.mod || return 0
	TOOLCHAINS+=(go)
	# `go fmt` rewrites in place; prek fails the hook when a file changes, which
	# is the gate. `gofmt -l` would only print and exit 0 — no gate at all.
	add_cand go-fmt local pre-commit 1 go.mod "go fmt ./..." "$RE_GO" false
	add_cand go-vet local pre-commit 1 go.mod "go vet ./..." "$RE_GO" false
	add_cand go-test local pre-push 1 go.mod "go test ./..." "$RE_GO" false
	add_cand go-build local pre-push 0 go.mod "go build ./..." "$RE_GO" false
	return 0
}

# --- detector: ruby --------------------------------------------------------

detect_ruby() {
	probe Gemfile || return 0
	TOOLCHAINS+=(ruby)
	local gem
	gem=$(cat "$REPO_ROOT/Gemfile" 2>/dev/null)
	if printf '%s' "$gem" | grep -qi 'rubocop'; then
		add_cand rubocop local pre-commit 1 Gemfile "bundle exec rubocop" "$RE_RB" false
	fi
	if printf '%s' "$gem" | grep -qi 'rspec'; then
		add_cand rspec local pre-push 1 Gemfile "bundle exec rspec" "$RE_RB" false
	fi
	return 0
}

# --- detector: task runners ------------------------------------------------

# Map a task name to (stage, recommended). Correctness blocks the commit;
# running the code blocks the push. This mapping is the placement rule, and it
# lives in exactly one place.
task_placement() {
	case "$1" in
	lint | fmt | format | check | typecheck | type-check | tidy)
		printf 'pre-commit 1'
		;;
	test | tests | spec)
		printf 'pre-push 1'
		;;
	build)
		printf 'pre-push 0'
		;;
	*) return 1 ;;
	esac
	return 0
}

add_task_cand() {
	# $1 = runner label, $2 = task name, $3 = entry, $4 = source file
	local place stage rec
	place=$(task_placement "$2") || return 0
	stage=${place%% *}
	rec=${place##* }
	has_cand "$2" && return 0
	add_cand "$2" local "$stage" "$rec" "$4" "$3" "" false
	return 0
}

detect_make() {
	probe Makefile || return 0
	local targets t
	targets=$(grep -oE '^[a-zA-Z][a-zA-Z0-9_-]*:' "$REPO_ROOT/Makefile" 2>/dev/null | tr -d ':')
	[ -z "$targets" ] && return 0
	TOOLCHAINS+=(make)
	for t in $targets; do
		add_task_cand make "$t" "make $t" Makefile
	done
	return 0
}

detect_just() {
	local f=""
	probe justfile && f=justfile
	[ -z "$f" ] && probe Justfile && f=Justfile
	[ -z "$f" ] && return 0
	local recipes t
	recipes=$(grep -oE '^[a-zA-Z][a-zA-Z0-9_-]*:' "$REPO_ROOT/$f" 2>/dev/null | tr -d ':')
	[ -z "$recipes" ] && return 0
	TOOLCHAINS+=(just)
	for t in $recipes; do
		add_task_cand just "$t" "just $t" "$f"
	done
	return 0
}

detect_task() {
	local f=""
	probe Taskfile.yml && f=Taskfile.yml
	[ -z "$f" ] && probe Taskfile.yaml && f=Taskfile.yaml
	[ -z "$f" ] && return 0
	local tasks t
	tasks=$(awk '
		/^tasks:/ { intasks = 1; next }
		/^[^[:space:]#]/ { intasks = 0 }
		intasks && /^[[:space:]]{2}[a-zA-Z0-9_-]+:/ {
			line = $0
			sub(/^[[:space:]]+/, "", line)
			sub(/:.*$/, "", line)
			print line
		}
	' "$REPO_ROOT/$f" 2>/dev/null)
	[ -z "$tasks" ] && return 0
	TOOLCHAINS+=(task)
	for t in $tasks; do
		add_task_cand task "$t" "task $t" "$f"
	done
	return 0
}

detect_mise() {
	local f=""
	probe mise.toml && f=mise.toml
	[ -z "$f" ] && probe .mise.toml && f=.mise.toml
	[ -z "$f" ] && return 0
	local tasks t
	tasks=$(grep -oE '^\[tasks\.[a-zA-Z0-9_-]+\]' "$REPO_ROOT/$f" 2>/dev/null |
		sed 's/^\[tasks\.//; s/\]$//')
	[ -z "$tasks" ] && return 0
	TOOLCHAINS+=(mise)
	for t in $tasks; do
		add_task_cand mise "$t" "mise run $t" "$f"
	done
	return 0
}

# --- detector: shell -------------------------------------------------------

detect_shell() {
	tracked_matches '\.(sh|bash)$' || return 0
	have shellcheck || return 0
	TOOLCHAINS+=(shell)
	add_cand shellcheck local pre-commit 1 "*.sh" "shellcheck" "$RE_SH" true
	return 0
}

# --- detector: builtins ----------------------------------------------------

detect_builtins() {
	add_cand trailing-whitespace builtin pre-commit 1 builtin "" "" ""
	add_cand end-of-file-fixer builtin pre-commit 1 builtin "" "" ""
	add_cand check-merge-conflict builtin pre-commit 1 builtin "" "" ""
	add_cand detect-private-key builtin pre-commit 1 builtin "" "" ""
	add_cand check-added-large-files builtin pre-commit 1 builtin "" "" ""
	add_cand mixed-line-ending builtin pre-commit 1 builtin "" "" ""
	tracked_matches '\.ya?ml$' && add_cand check-yaml builtin pre-commit 1 builtin "" "" ""
	tracked_matches '\.json$' && add_cand check-json builtin pre-commit 1 builtin "" "" ""
	tracked_matches '\.toml$' && add_cand check-toml builtin pre-commit 1 builtin "" "" ""
	return 0
}

run_detection() {
	detect_node
	detect_rust
	detect_python
	detect_go
	detect_ruby
	detect_make
	detect_just
	detect_task
	detect_mise
	detect_shell
	detect_builtins
	return 0
}

# --- existing state --------------------------------------------------------

CONFIG_STATE=absent # absent | managed | unmanaged
FOREIGN=""          # husky / lefthook / pre-commit-yaml

read_existing_state() {
	if [ -f "$CONFIG" ]; then
		if head -3 "$CONFIG" | grep -qF "$MARKER"; then
			CONFIG_STATE=managed
		else
			CONFIG_STATE=unmanaged
		fi
	fi
	[ -f "$REPO_ROOT/.pre-commit-config.yaml" ] && FOREIGN="pre-commit-yaml"
	[ -z "$FOREIGN" ] && [ -f "$REPO_ROOT/.pre-commit-config.yml" ] && FOREIGN="pre-commit-yaml"
	[ -z "$FOREIGN" ] && [ -d "$REPO_ROOT/.husky" ] && FOREIGN="husky"
	[ -z "$FOREIGN" ] && [ -f "$REPO_ROOT/lefthook.yml" ] && FOREIGN="lefthook"
	[ -z "$FOREIGN" ] && [ -f "$REPO_ROOT/lefthook.yaml" ] && FOREIGN="lefthook"
	return 0
}

shim_state() {
	# $1 = stage; echoes: none | prek | chained | foreign
	#
	# `chained` is the healthy end state when another tool also wants this hook.
	# prek's own shim does not call a pre-existing hook, but several tools that
	# install into .git/hooks do: they displace prek's shim to a sibling and call
	# it. Treating that as `foreign` would make this skill reinstall over the
	# outer hook and break the chain it is already part of.
	local f="$HOOKS_DIR/$1" sib
	if [ ! -f "$f" ]; then
		printf none
		return 0
	fi
	if grep -q 'prek' "$f" 2>/dev/null; then
		printf prek
		return 0
	fi
	# Not prek's. If it hands off to a sibling that *is* prek's, prek still runs.
	# Require the sibling to be executable, to name prek, and to carry the real
	# entry point — prek's shim invokes it through a variable (`"$PREK"
	# hook-impl`), so the two have to be matched separately rather than as one
	# literal. Both together keep a passing mention in a comment from reading as
	# a live chain.
	for sib in "$HOOKS_DIR/$1".*; do
		[ -f "$sib" ] && [ -x "$sib" ] || continue
		grep -q 'hook-impl' "$sib" 2>/dev/null || continue
		grep -qi 'prek' "$sib" 2>/dev/null || continue
		if grep -qF "$(basename "$sib")" "$f" 2>/dev/null; then
			printf chained
			return 0
		fi
	done
	printf foreign
}

print_header() {
	printf 'bin: %s\n' "${SELF/#$HOME/\~}"
	printf 'repo: %s\n' "$REPO"
	printf 'mode: %s\n' "$MODE"
	local pc pp
	pc=$(shim_state pre-commit)
	pp=$(shim_state pre-push)
	case "$CONFIG_STATE" in
	absent) printf 'config: absent\n' ;;
	managed) printf 'config: prek.toml, managed by this skill\n' ;;
	unmanaged) printf 'config: prek.toml, hand-written (not managed by this skill)\n' ;;
	esac
	[ -n "$FOREIGN" ] && printf 'other-manager: %s\n' "$FOREIGN"
	printf 'shims: pre-commit=%s pre-push=%s\n' "$pc" "$pp"
	return 0
}

print_readme_state() {
	local rm=""
	for c in README.md readme.md README.markdown README; do
		[ -f "$REPO_ROOT/$c" ] && {
			rm=$c
			break
		}
	done
	if [ -z "$rm" ]; then
		printf 'readme: none in repo\n'
		return 0
	fi
	if grep -qiE 'prek|git hook|pre-commit' "$REPO_ROOT/$rm"; then
		printf 'readme: %s, hooks already documented\n' "$rm"
	else
		printf 'readme: %s, hooks not documented\n' "$rm"
	fi
	return 0
}

print_readme_snippet() {
	printf 'snippet:\n'
	printf '  ## Git hooks\n'
	printf '  \n'
	printf '  `prek` runs formatting, linting and type checks on commit, and tests on push.\n'
	printf '  \n'
	printf '  ```bash\n'
	printf '  prek install          # once, after cloning\n'
	printf '  prek run --all-files  # run everything now\n'
	printf '  ```\n'
	printf '  \n'
	printf '  Bypass with `git commit --no-verify` when you must.\n'
	return 0
}

# --- rendering -------------------------------------------------------------

print_stage_table() {
	# $1 = stage
	local stage=$1 rows=() rec id kind st r src entry mark
	for rec in "${CAND[@]:-}"; do
		[ -n "$rec" ] || continue
		IFS="$SEP" read -r id kind st r src entry _ _ <<<"$rec"
		[ "$st" = "$stage" ] || continue
		[ "$r" = 1 ] && mark="Y" || mark=""
		[ -n "$entry" ] || entry="-"
		rows+=("  $mark,$id,$src,$entry")
	done
	printf '%s[%s]{on,id,source,entry}:\n' "$stage" "${#rows[@]}"
	if [ "${#rows[@]}" -eq 0 ]; then
		printf '  none detected\n'
		return 0
	fi
	printf '%s\n' "${rows[@]}"
	return 0
}

recommended_ids() {
	# $1 = stage
	local rec id st r out=""
	for rec in "${CAND[@]:-}"; do
		[ -n "$rec" ] || continue
		IFS="$SEP" read -r id _ st r _ _ _ _ <<<"$rec"
		[ "$st" = "$1" ] || continue
		[ "$r" = 1 ] || continue
		out="$out${out:+,}$id"
	done
	printf '%s' "$out"
	return 0
}

# --- prek.toml generation --------------------------------------------------

# Every generated hook carries an explicit `stages`. Without it prek reports a
# hook as belonging to *every* stage, and nothing downstream — --status, --heal,
# the re-run reconciliation — could tell pre-commit from pre-push.

# Blocks are separated by a blank line *before* each one, never after. A trailing
# separator would leave the file ending on a blank line — which the
# end-of-file-fixer hook this same script installs then strips, so every
# generated config failed the very first commit it was supposed to guard.
gen_config() {
	# reads WANT_PRE_COMMIT / WANT_PRE_PUSH (comma lists) and CAND
	local rec id kind st r src entry files passfn excl name want
	printf '%s — re-run it to change hooks\n' "$MARKER"
	printf '# regenerate: bash %s --apply --accept\n' "${SELF/#$HOME/\~}"

	# builtin block
	local any_builtin=false
	for rec in "${CAND[@]:-}"; do
		[ -n "$rec" ] || continue
		IFS="$SEP" read -r id kind st r src entry files passfn excl name <<<"$rec"
		[ "$kind" = builtin ] || continue
		selected_stage "$id" >/dev/null || continue
		any_builtin=true
	done
	if [ "$any_builtin" = true ]; then
		printf '\n[[repos]]\nrepo = "builtin"\n'
		for rec in "${CAND[@]:-}"; do
			[ -n "$rec" ] || continue
			IFS="$SEP" read -r id kind st r src entry files passfn excl name <<<"$rec"
			[ "$kind" = builtin ] || continue
			want=$(selected_stage "$id") || continue
			local excl
			excl=$(cand_exclude "$id")
			printf '\n[[repos.hooks]]\n'
			printf 'id = %s\n' "$(toml_basic "$id")"
			[ -n "$excl" ] && printf 'exclude = %s\n' "$(toml_basic "$excl")"
			printf 'stages = ["%s"]\n' "$want"
		done
	fi

	# local block
	local any_local=false
	for rec in "${CAND[@]:-}"; do
		[ -n "$rec" ] || continue
		IFS="$SEP" read -r id kind st r src entry files passfn excl name <<<"$rec"
		[ "$kind" = local ] || continue
		selected_stage "$id" >/dev/null || continue
		any_local=true
	done
	if [ "$any_local" = true ]; then
		printf '\n[[repos]]\nrepo = "local"\n'
		for rec in "${CAND[@]:-}"; do
			[ -n "$rec" ] || continue
			IFS="$SEP" read -r id kind st r src entry files passfn excl name <<<"$rec"
			[ "$kind" = local ] || continue
			want=$(selected_stage "$id") || continue
			printf '\n[[repos.hooks]]\n'
			printf 'id = %s\n' "$(toml_basic "$id")"
			printf 'name = %s\n' "$(toml_basic "${name:-$id}")"
			printf 'language = "system"\n'
			printf 'entry = %s\n' "$(toml_basic "$entry")"
			[ -n "$files" ] && printf 'files = %s\n' "$(toml_basic "$files")"
			[ -n "$excl" ] && printf 'exclude = %s\n' "$(toml_basic "$excl")"
			printf 'pass_filenames = %s\n' "${passfn:-false}"
			printf 'stages = ["%s"]\n' "$want"
		done
	fi
	return 0
}

selected_stage() {
	# echoes the stage $1 was selected into, or returns 1
	case ",$WANT_PRE_COMMIT," in *",$1,"*)
		printf 'pre-commit'
		return 0
		;;
	esac
	case ",$WANT_PRE_PUSH," in *",$1,"*)
		printf 'pre-push'
		return 0
		;;
	esac
	return 1
}

# --- modes -----------------------------------------------------------------

do_plan() {
	read_existing_state
	run_detection
	print_header
	printf 'toolchains[%s]: %s\n' "${#TOOLCHAINS[@]}" "$(
		IFS=' '
		printf '%s' "${TOOLCHAINS[*]:-none}"
	)"
	printf '\n'
	print_stage_table pre-commit
	print_stage_table pre-push
	printf '\n'
	print_readme_state

	if [ "$MODE" = scan ]; then
		print_scan_tables
	fi

	if [ "$CONFIG_STATE" = unmanaged ] || [ -n "$FOREIGN" ]; then
		printf 'blocked: an existing setup owns this repo\n'
		printf 'help: run --heal to diagnose it, or --apply --force to replace it\n'
		return 0
	fi

	local nrepo=0 rec kind
	for rec in "${CAND[@]:-}"; do
		[ -n "$rec" ] || continue
		kind=$(cand_field "$rec" 2)
		[ "$kind" = local ] && nrepo=$((nrepo + 1))
	done
	if [ "$nrepo" -eq 0 ] && [ "$MODE" != scan ]; then
		printf 'note: no repo scripts detected, only builtin hygiene hooks\n'
		printf 'help: run --scan to have an agent look for checks the heuristics missed\n'
	fi
	printf 'next: bash %s --apply --accept\n' "${SELF/#$HOME/\~}"
	printf 'help: change the set with --apply --pre-commit=<ids> --pre-push=<ids>\n'
	return 0
}

print_scan_tables() {
	printf '\n'
	local rows=() rec id kind st r src entry
	for rec in "${CAND[@]:-}"; do
		[ -n "$rec" ] || continue
		IFS="$SEP" read -r id kind st r src entry _ _ <<<"$rec"
		[ "$kind" = local ] || continue
		rows+=("  $id,$src,$entry,$st")
	done
	printf 'detected[%s]{id,source,entry,stage}:\n' "${#rows[@]}"
	if [ "${#rows[@]}" -eq 0 ]; then
		printf '  none\n'
	else
		printf '%s\n' "${rows[@]}"
	fi

	local plist=() p m
	for p in "${PROBES[@]:-}"; do
		[ -n "$p" ] && plist+=("  ${p/|/,}")
	done
	# Across the whole tree, not just the root. A marker for a toolchain this
	# script has no detector for is most often nested — which is exactly the case
	# the root-only check could never surface, leaving the mechanism designed to
	# expose gaps blind to the commonest one.
	for m in $UNKNOWN_MARKERS; do
		while IFS= read -r hit; do
			[ -n "$hit" ] && plist+=("  $hit,not-probed")
		done < <(printf '%s\n' "$TRACKED" | grep -E "(^|/)$(printf '%s' "$m" | sed 's/[.]/[.]/g')$" | head -5)
	done
	printf 'probed[%s]{path,result}:\n' "${#plist[@]}"
	printf '%s\n' "${plist[@]}"
	printf 'gap-check: every `not-probed` row is a marker this script has no detector for\n'
	printf 'help: explore the repo, hand findings back via --apply --extra=<file.json>\n'
	printf 'help: then add a detector for anything that generalises, and prove it with --plan\n'
	return 0
}

do_status() {
	read_existing_state
	print_header
	if [ "$CONFIG_STATE" = absent ]; then
		printf 'hooks: none configured\n'
		printf 'next: bash %s\n' "${SELF/#$HOME/\~}"
		return 0
	fi
	local stage ids
	for stage in pre-commit pre-push; do
		ids=$("$PREK" list --hook-stage "$stage" --output-format json 2>/dev/null |
			jq -r '.[].id' 2>/dev/null | paste -sd, -)
		printf '%s: %s\n' "$stage" "${ids:-none}"
	done
	print_readme_state
	return 0
}

# --- apply -----------------------------------------------------------------

load_extra() {
	[ -z "$EXTRA_FILE" ] && return 0
	if [ ! -f "$EXTRA_FILE" ]; then
		printf 'error: --extra file not found: %s\n' "$EXTRA_FILE"
		printf 'help: write a JSON array of {id,name,entry,stage,files,exclude,pass_filenames}\n'
		exit 2
	fi
	if ! jq -e 'type == "array"' "$EXTRA_FILE" >/dev/null 2>&1; then
		printf 'error: --extra file is not a JSON array\n'
		printf 'file: %s\n' "$EXTRA_FILE"
		printf 'help: expected [{"id":"check","entry":"script/check","stage":"pre-commit"}]\n'
		exit 2
	fi
	local bad
	bad=$(jq -r '.[] | select((.id|type) != "string" or (.entry|type) != "string"
		or ((.stage // "") | IN("pre-commit","pre-push") | not)) | .id // "<no id>"' \
		"$EXTRA_FILE" 2>/dev/null)
	if [ -n "$bad" ]; then
		printf 'error: --extra entries are missing a valid id, entry, or stage\n'
		printf 'invalid[%s]: %s\n' "$(printf '%s\n' "$bad" | grep -c .)" "$(printf '%s' "$bad" | paste -sd, -)"
		printf 'help: stage must be "pre-commit" or "pre-push"; id and entry are required strings\n'
		exit 2
	fi
	# Extras become ordinary candidates rather than pre-rendered TOML. Everything
	# downstream — the tables, the recommended set, stage selection, escaping,
	# generation — then treats them exactly like a detected hook, and there is one
	# code path instead of two that drift apart.
	local xid xname xentry xfiles xexcl xpass xstage
	while IFS="$SEP" read -r xid xname xentry xfiles xexcl xpass xstage; do
		[ -n "$xid" ] || continue
		if has_cand "$xid"; then
			printf 'error: --extra id %s already names a detected hook\n' "$xid"
			printf 'cause: two hooks with one id would make the generated config ambiguous\n'
			printf 'help: rename the entry in %s\n' "$EXTRA_FILE"
			exit 2
		fi
		add_cand "$xid" local "$xstage" 1 "$(basename "$EXTRA_FILE")" \
			"$xentry" "$xfiles" "$xpass" "$xexcl" "$xname"
		EXTRA_IDS="$EXTRA_IDS${EXTRA_IDS:+,}$xid"
	done < <(jq -r --arg sep "$SEP" '.[] | [
		.id,
		(.name // .id),
		.entry,
		(.files // ""),
		(.exclude // ""),
		(if .pass_filenames then "true" else "false" end),
		.stage
	] | join($sep)' "$EXTRA_FILE" 2>/dev/null)
	return 0
}

EXTRA_IDS=""

do_apply() {
	read_existing_state
	run_detection
	load_extra

	if [ "$ACCEPT" = true ]; then
		WANT_PRE_COMMIT=$(recommended_ids pre-commit)
		WANT_PRE_PUSH=$(recommended_ids pre-push)
	else
		WANT_PRE_COMMIT=$SEL_PRE_COMMIT
		WANT_PRE_PUSH=$SEL_PRE_PUSH
	fi

	# Reject an id that matches no candidate — a typo must not silently shrink
	# the hook set into something the agent believes it asked for.
	local id unknown=""
	for id in $(printf '%s,%s' "$WANT_PRE_COMMIT" "$WANT_PRE_PUSH" | tr ',' ' '); do
		[ -n "$id" ] || continue
		has_cand "$id" || unknown="$unknown${unknown:+,}$id"
	done
	if [ -n "$unknown" ]; then
		printf 'error: unknown hook id(s): %s\n' "$unknown"
		printf 'cause: no detected candidate carries that id\n'
		printf 'valid-pre-commit: %s\n' "$(all_ids pre-commit)"
		printf 'valid-pre-push: %s\n' "$(all_ids pre-push)"
		printf 'help: run --plan to see the candidate table\n'
		exit 2
	fi

	# ...and the reverse. An extra the caller supplied but did not name is
	# dropped by the selection, which used to happen silently. Say so instead:
	# `--extra` offers a hook, the selection still decides.
	local dropped=""
	for id in $(printf '%s' "$EXTRA_IDS" | tr ',' ' '); do
		[ -n "$id" ] || continue
		selected_stage "$id" >/dev/null || dropped="$dropped${dropped:+,}$id"
	done
	if [ -n "$dropped" ]; then
		printf 'error: --extra hook(s) not in the selection: %s\n' "$dropped"
		printf 'cause: an explicit --pre-commit=/--pre-push= list decides the whole set\n'
		printf 'help: add the id to the matching stage list, or pass --accept to take every recommended hook\n'
		exit 2
	fi

	if [ -z "$WANT_PRE_COMMIT$WANT_PRE_PUSH" ]; then
		printf 'error: the selection is empty\n'
		printf 'help: pass --accept, or name ids with --pre-commit=/--pre-push=\n'
		exit 2
	fi

	# Ownership: never overwrite a setup this skill did not write.
	if [ "$FORCE" != true ]; then
		if [ "$CONFIG_STATE" = unmanaged ]; then
			printf 'error: prek.toml exists and was not written by this skill\n'
			printf 'cause: overwriting it would discard hand-written hooks\n'
			printf 'help: run --heal to diagnose it, or --apply --force to replace it\n'
			exit 1
		fi
		if [ -n "$FOREIGN" ]; then
			printf 'error: this repo already uses %s\n' "$FOREIGN"
			printf 'cause: two hook managers fighting over .git/hooks is worse than either alone\n'
			case "$FOREIGN" in
			pre-commit-yaml) printf 'help: convert it with `prek util yaml-to-toml`, or --apply --force to replace it\n' ;;
			*) printf 'help: remove %s first, or --apply --force to replace it\n' "$FOREIGN" ;;
			esac
			exit 1
		fi
		# The check above is file-based — it only knows the managers that leave a
		# config in the worktree. A tool that installs straight into .git/hooks
		# leaves no such trace, so ask the shims themselves.
		local blocked="" st
		for st in pre-commit pre-push; do
			[ "$st" = pre-commit ] && [ -z "$WANT_PRE_COMMIT" ] && continue
			[ "$st" = pre-push ] && [ -z "$WANT_PRE_PUSH" ] && continue
			[ "$(shim_state "$st")" = foreign ] &&
				blocked="$blocked${blocked:+ }$st"
		done
		if [ -n "$blocked" ]; then
			printf 'error: another tool owns the %s hook\n' "$blocked"
			printf 'cause: installing over it would delete a hook this skill did not write\n'
			printf 'help: --apply --force replaces it; to keep both, run --force and then\n'
			printf 'help: re-run the other tool'"'"'s installer so it lands outermost and chains\n'
			exit 1
		fi
	fi

	# prek picks its parser from the file extension, so the candidate has to end
	# in .toml or it gets read as YAML and fails to parse.
	local tmp="$REPO_ROOT/.sgh-tmp.toml"
	gen_config >"$tmp" 2>/dev/null
	if ! "$PREK" validate-config "$tmp" >/dev/null 2>&1; then
		printf 'error: the generated config did not validate\n'
		printf 'cause: prek rejected it — a hook id or entry is not usable here\n'
		printf 'detail:\n'
		"$PREK" validate-config "$tmp" 2>&1 | head -10 | sed 's/^/  /'
		printf 'help: re-run --plan and pick a smaller set, or report the detail above\n'
		rm -f "$tmp"
		exit 1
	fi
	mv "$tmp" "$CONFIG"

	# Install a shim only for a stage that actually has hooks, and remove the one
	# for a stage that no longer does — an orphan shim is drift this would
	# otherwise have to heal later.
	local installed="" removed=""
	local want_pc=$WANT_PRE_COMMIT want_pp=$WANT_PRE_PUSH

	local stage want chained=""
	for stage in pre-commit pre-push; do
		[ "$stage" = pre-commit ] && want=$want_pc || want=$want_pp
		if [ -n "$want" ]; then
			# Already reachable through another tool's hook — reinstalling would
			# replace that outer hook and break the chain.
			if [ "$(shim_state "$stage")" = chained ]; then
				chained="$chained${chained:+ }$stage"
				continue
			fi
			"$PREK" install -t "$stage" -f >/dev/null 2>&1 &&
				installed="$installed${installed:+ }$stage"
		elif [ "$(shim_state "$stage")" = prek ]; then
			"$PREK" uninstall -t "$stage" >/dev/null 2>&1 &&
				removed="$removed${removed:+ }$stage"
		fi
	done

	CONFIG_STATE=managed
	print_header
	printf 'wrote: prek.toml\n'
	printf 'installed: %s\n' "${installed:-none}"
	[ -n "$chained" ] && printf 'chained: %s shim reached through another tool'"'"'s hook, left alone\n' "$chained"
	[ -n "$removed" ] && printf 'removed: %s shim (no hooks left in that stage)\n' "$removed"
	local stage ids
	for stage in pre-commit pre-push; do
		ids=$("$PREK" list --hook-stage "$stage" --output-format json 2>/dev/null |
			jq -r '.[].id' 2>/dev/null | paste -sd, -)
		printf '%s: %s\n' "$stage" "${ids:-none}"
	done
	print_readme_state
	print_readme_snippet
	printf 'next: prek run --all-files\n'
	return 0
}

all_ids() {
	local rec id st out=""
	for rec in "${CAND[@]:-}"; do
		[ -n "$rec" ] || continue
		IFS="$SEP" read -r id _ st _ _ _ _ _ <<<"$rec"
		[ "$st" = "$1" ] || continue
		out="$out${out:+,}$id"
	done
	printf '%s' "${out:-none}"
	return 0
}

# --- heal ------------------------------------------------------------------

# Pull id/entry pairs out of either config dialect. `prek list` reports ids and
# stages but not entries, and a dead entry is exactly what heal is looking for.
config_entries() {
	local f=$1
	awk '
		/^[[:space:]]*[-]?[[:space:]]*id[[:space:]]*[:=]/ {
			line = $0
			sub(/^[^:=]*[:=][[:space:]]*/, "", line)
			gsub(/^["'"'"']|["'"'"'][[:space:]]*,?[[:space:]]*$/, "", line)
			id = line
		}
		/^[[:space:]]*entry[[:space:]]*[:=]/ {
			line = $0
			sub(/^[^:=]*[:=][[:space:]]*/, "", line)
			gsub(/^["'"'"']|["'"'"'][[:space:]]*,?[[:space:]]*$/, "", line)
			if (id != "") { print id "\t" line; id = "" }
		}
	' "$f" 2>/dev/null
}

entry_is_dead() {
	# $1 = entry command; returns 0 when it cannot possibly run
	#
	# Everything here fails open. A false `dead` makes --heal --fix delete a
	# working hook, while a false `alive` costs nothing but a stale entry, so any
	# form this cannot confidently parse is reported as alive.
	local e=$1 first second
	read -r first second _ <<<"$e"
	case "$first" in
	npm | pnpm | yarn | bun)
		# A sub-package hook names its own manifest: `npm --prefix <dir> run
		# lint`, `pnpm -C <dir> test`. Walk the tokens rather than assuming the
		# script is the first or second word, or `--prefix` itself gets looked up
		# as a script name and every sub-package hook reads as dead.
		local dir="" script="" tok
		# shellcheck disable=SC2086
		set -- $e
		shift # the package manager itself
		while [ $# -gt 0 ]; do
			tok=$1
			case "$tok" in
			--prefix | -C | --cwd)
				dir=${2:-}
				shift 2 || break
				continue
				;;
			--prefix=* | --cwd=*)
				dir=${tok#*=}
				shift
				continue
				;;
			-w | --workspace | -w=* | --workspace=*)
				# Names a workspace, not a path. Resolving it needs the root
				# manifest's globs — out of scope, so decline to judge.
				return 1
				;;
			run | run-script | exec)
				shift
				continue
				;;
			-*)
				shift
				continue
				;;
			*)
				script=$tok
				break
				;;
			esac
		done
		[ -z "$script" ] && return 1
		local manifest="$REPO_ROOT/package.json"
		[ -n "$dir" ] && manifest="$REPO_ROOT/$dir/package.json"
		# A named directory that has no manifest at all is a real dead signal.
		[ -f "$manifest" ] || return 0
		jq -e --arg s "$script" '.scripts // {} | has($s)' "$manifest" >/dev/null 2>&1 && return 1
		return 0
		;;
	make)
		[ -f "$REPO_ROOT/Makefile" ] || return 0
		grep -qE "^$second:" "$REPO_ROOT/Makefile" && return 1
		return 0
		;;
	just)
		{ [ -f "$REPO_ROOT/justfile" ] || [ -f "$REPO_ROOT/Justfile" ]; } || return 0
		grep -qhE "^$second:" "$REPO_ROOT/justfile" "$REPO_ROOT/Justfile" 2>/dev/null && return 1
		return 0
		;;
	esac
	return 1
}

do_heal() {
	read_existing_state
	print_header

	if [ "$CONFIG_STATE" = absent ] && [ -z "$FOREIGN" ]; then
		printf 'error: nothing to heal\n'
		printf 'cause: this repo has no prek config\n'
		printf 'help: run --plan to set hooks up from scratch\n'
		exit 1
	fi

	local cfg="$CONFIG"
	[ "$CONFIG_STATE" = absent ] && [ "$FOREIGN" = pre-commit-yaml ] && {
		[ -f "$REPO_ROOT/.pre-commit-config.yaml" ] && cfg="$REPO_ROOT/.pre-commit-config.yaml"
		[ -f "$REPO_ROOT/.pre-commit-config.yml" ] && cfg="$REPO_ROOT/.pre-commit-config.yml"
	}

	if ! "$PREK" validate-config "$cfg" >/dev/null 2>&1; then
		printf 'broken: %s does not parse\n' "$(basename "$cfg")"
		printf 'detail:\n'
		"$PREK" validate-config "$cfg" 2>&1 | head -8 | sed 's/^/  /'
		printf 'help: fix the config before healing anything else\n'
		exit 1
	fi

	local findings=0 repairs=()
	local stage ids shim
	for stage in pre-commit pre-push; do
		ids=$("$PREK" list --hook-stage "$stage" --output-format json 2>/dev/null |
			jq -r '.[].id' 2>/dev/null | paste -sd, -)
		shim=$(shim_state "$stage")
		if [ -n "$ids" ] && [ "$shim" = none ]; then
			printf 'drift: %s hooks configured, no %s shim installed\n' "$stage" "$stage"
			repairs+=("install:$stage")
			findings=$((findings + 1))
		elif [ -n "$ids" ] && [ "$shim" = foreign ]; then
			# Reported, never queued for repair: the repair is `prek install -f`,
			# which deletes the other tool's hook. Naming it and stopping is the
			# honest move — which of the two managers should own the slot is not
			# this skill's call.
			printf 'drift: %s shim belongs to another manager, not prek\n' "$stage"
			printf 'help: prek cannot take that slot without deleting the other hook;\n'
			printf 'help: re-run this skill with --apply --force if that is what you want\n'
			findings=$((findings + 1))
		elif [ -z "$ids" ] && [ "$shim" = prek ]; then
			printf 'drift: %s shim installed but no %s hooks configured\n' "$stage" "$stage"
			repairs+=("uninstall:$stage")
			findings=$((findings + 1))
		fi
	done

	# Dead entries and missing binaries.
	local id entry first
	while IFS=$'\t' read -r id entry; do
		[ -n "$entry" ] || continue
		if entry_is_dead "$entry"; then
			printf 'dead: %s -> %s (target no longer exists)\n' "$id" "$entry"
			repairs+=("drop:$id")
			findings=$((findings + 1))
			continue
		fi
		first=${entry%% *}
		if ! have "$first"; then
			printf 'missing: %s needs `%s`, not on PATH\n' "$id" "$first"
			findings=$((findings + 1))
		fi
	done <<<"$(config_entries "$cfg")"

	# Pinned revisions.
	# `grep -c` prints its count and still exits 1 when that count is zero, so a
	# `|| printf 0` fallback would append a second number.
	local nrev
	nrev=$(grep -cE '^[[:space:]]*-?[[:space:]]*rev[[:space:]]*[:=]' "$cfg" 2>/dev/null)
	nrev=${nrev:-0}
	if [ "$nrev" -gt 0 ]; then
		printf 'pinned: %s remote repo(s) with a pinned rev\n' "$nrev"
		printf 'help: `prek update` refreshes them when you want newer hooks\n'
	fi

	if [ "$findings" -eq 0 ]; then
		printf 'healthy: no drift found\n'
		print_readme_state
		printf 'next: prek run --all-files\n'
		return 0
	fi

	printf 'findings: %s\n' "$findings"

	if [ "$FIX" != true ]; then
		printf 'next: bash %s --heal --fix\n' "${SELF/#$HOME/\~}"
		printf 'note: --fix installs and removes shims; it edits the config only when this skill manages it\n'
		return 0
	fi

	# --- repair ---
	local r act target done_=""
	for r in "${repairs[@]:-}"; do
		[ -n "$r" ] || continue
		act=${r%%:*}
		target=${r#*:}
		case "$act" in
		install)
			"$PREK" install -t "$target" -f >/dev/null 2>&1 &&
				done_="$done_${done_:+, }installed $target shim"
			;;
		uninstall)
			"$PREK" uninstall -t "$target" >/dev/null 2>&1 &&
				done_="$done_${done_:+, }removed dead $target shim"
			;;
		drop)
			if [ "$CONFIG_STATE" = managed ]; then
				drop_hook "$target" &&
					done_="$done_${done_:+, }dropped dead hook $target"
			else
				printf 'skipped: %s is dead, but this config is not managed by this skill\n' "$target"
				printf 'help: remove it by hand, or re-run --apply --force to regenerate\n'
			fi
			;;
		esac
	done
	printf 'repaired: %s\n' "${done_:-nothing}"
	print_readme_state
	printf 'next: prek run --all-files\n'
	return 0
}

drop_hook() {
	# Remove one [[repos.hooks]] block by id from a config this skill wrote.
	local id=$1 tmp="$REPO_ROOT/.sgh-tmp.toml"
	awk -v target="$id" '
		/^\[\[repos\.hooks\]\]/ {
			if (block != "") { if (!drop) printf "%s", block }
			block = $0 "\n"; drop = 0; next
		}
		block != "" {
			if ($0 ~ "^id[[:space:]]*=" ) {
				v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); gsub(/"/, "", v)
				if (v == target) drop = 1
			}
			block = block $0 "\n"; next
		}
		{ print }
		END { if (block != "" && !drop) printf "%s", block }
	' "$CONFIG" >"$tmp" 2>/dev/null || {
		rm -f "$tmp"
		return 1
	}
	if "$PREK" validate-config "$tmp" >/dev/null 2>&1; then
		mv "$tmp" "$CONFIG"
		return 0
	fi
	rm -f "$tmp"
	return 1
}

# --- dispatch --------------------------------------------------------------

WANT_PRE_COMMIT=""
WANT_PRE_PUSH=""

case "$MODE" in
plan | scan) do_plan ;;
status) do_status ;;
apply) do_apply ;;
heal) do_heal ;;
esac
exit 0
