#!/usr/bin/env bash
# Inspect a repository, propose the herdr panes a fresh worktree should open, and
# write .config/wt.toml so `wta <branch>` lands on a running agent.
#
# `wta` deliberately launches nothing in a repo that has .config/wt.toml — it
# hands that job to worktrunk's post-start hooks. This script writes them.
#
# Output follows AXI conventions: structured key/value and TOON tables on stdout
# (errors included), progress on stderr, exit 0 for success and no-ops, 1 for
# errors, 2 for usage.
#
# Invoke with `bash setup-worktrunk.sh` — `npx skills` copies skill files without
# the executable bit, so a direct exec would fail.

# Most of this script's output is text about shell, not shell: backticks quoting a
# command in a help line, and the `$(...)` of the hook body it generates. Both are
# meant to stay literal, so single-quoted printf is correct throughout.
# shellcheck disable=SC2016

set -uo pipefail

SELF=${BASH_SOURCE[0]}
MARKER="# managed by the setup-worktrunk skill"

MODE=plan
ACCEPT=false
FIX=false
FORCE=false
SEL_PANES=""
SEL_STEPS=""
SEL_GIVEN=false
EXTRA_FILE=""

usage() {
	printf 'bin: %s\n' "${SELF/#$HOME/\~}"
	printf 'description: Set up worktrunk hooks that open a herdr workspace per worktree\n'
	printf 'modes[5]{mode,writes,job}:\n'
	printf '  --plan,nothing,"Inspect the repo and print the candidate pane and step tables (default)"\n'
	printf '  --scan,nothing,"--plan plus a detection baseline and probe list for an agent deep-scan"\n'
	printf '  --apply,.config/wt.toml,"Write the project config"\n'
	printf '  --heal,nothing,"Diagnose a config that has drifted from the project or the tooling"\n'
	printf '  --status,nothing,"Report what is configured right now"\n'
	printf 'flags[6]{flag,effect}:\n'
	printf '  --accept,"With --apply: take the recommended set"\n'
	printf '  --panes=a\\,b,"With --apply: the exact pane ids, in layout order"\n'
	printf '  --steps=a\\,b,"With --apply: the exact step ids"\n'
	printf '  --extra=<file.json>,"With --apply: merge agent-discovered panes"\n'
	printf '  --fix,"With --heal: perform the safe repairs"\n'
	printf '  --force,"With --apply: overwrite a config this skill does not manage"\n'
	printf 'examples[3]:\n'
	printf '  bash %s\n' "${SELF/#$HOME/\~}"
	printf '  bash %s --apply --accept\n' "${SELF/#$HOME/\~}"
	printf '  bash %s --apply --panes=agent,frontend --steps=copy,herdr,close\n' "${SELF/#$HOME/\~}"
}

flag_error() {
	printf 'error: %s\n' "$1"
	printf 'help: valid flags: --plan --scan --apply --heal --status --accept --panes= --steps= --extra= --fix --force --help\n'
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
	--panes=*)
		SEL_PANES=${arg#--panes=}
		SEL_GIVEN=true
		;;
	--steps=*)
		SEL_STEPS=${arg#--steps=}
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
	[ "$SEL_GIVEN" = true ] && flag_error "--panes=/--steps= only apply to --apply"
	[ -n "$EXTRA_FILE" ] && flag_error "--extra= only applies to --apply"
	[ "$FORCE" = true ] && flag_error "--force only applies to --apply"
fi
if [ "$MODE" != heal ] && [ "$FIX" = true ]; then
	flag_error "--fix only applies to --heal"
fi
if [ "$MODE" = apply ] && [ "$ACCEPT" = false ] && [ "$SEL_GIVEN" = false ]; then
	printf 'error: --apply needs a selection\n'
	printf 'cause: neither --accept nor an explicit pane list was given\n'
	printf 'help: run --plan first, then --apply --accept or --apply --panes=a,b --steps=c\n'
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
CONFIG="$REPO_ROOT/.config/wt.toml"

# --- locate the tooling ----------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

if ! WT=$(command -v wt 2>/dev/null); then
	printf 'error: `wt` not found on PATH\n'
	printf 'repo: %s\n' "$REPO"
	printf 'cause: worktrunk owns the hooks this skill configures\n'
	printf 'help: install it with `brew install worktrunk`\n'
	exit 1
fi

if ! have jq; then
	printf 'error: `jq` not found on PATH\n'
	printf 'repo: %s\n' "$REPO"
	printf 'cause: package.json, herdr output and --extra parsing all read JSON through jq\n'
	printf 'help: install it with `brew install jq`\n'
	exit 1
fi

# herdr is what the generated hooks drive, but it is not needed to write them —
# the generated block degrades to a no-op on a machine without it.
HERDR_STATE=absent
if have herdr; then
	HERDR_STATE=present
fi

# --- tracked-file index ----------------------------------------------------
# Read the tree once. Detection asks this index questions rather than walking the
# filesystem per component, which keeps node_modules out of the answers.

# core.quotepath defaults to true, which makes ls-files wrap any path containing
# a non-ASCII byte in double quotes and octal-escape it — `Affärsplan/package.json`
# arrives as `"Aff\303\244rsplan/package.json"`. Every $-anchored pattern below
# then misses it, so a whole component can be invisible to detection with no
# error anywhere. Turning it off also makes paths with spaces come back verbatim.
TRACKED=$(git -C "$REPO_ROOT" -c core.quotepath=false ls-files 2>/dev/null)

tracked_matches() { printf '%s\n' "$TRACKED" | grep -qE "$1"; }

# --- probes ----------------------------------------------------------------
# Every path a detector looks at is recorded with what it saw, so --scan can show
# where detection has been and where it has never looked.

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
UNKNOWN_MARKERS="deno.json deno.jsonc mix.exs build.gradle build.gradle.kts pom.xml CMakeLists.txt composer.json pubspec.yaml Package.swift docker-compose.yml docker-compose.yaml Tiltfile skaffold.yaml"

# --- candidates ------------------------------------------------------------
# Panes:  id|dir|command|recommended|source
# Steps:  id|hook|summary|recommended|source
#
# ASCII unit separator. A pipe would be the obvious delimiter, but dev commands
# are full of `&&` and shell punctuation, and a pipe would eventually appear in
# one and shred the record.
SEP=$'\037'

PANES=()
STEPS=()
TOOLCHAINS=()

add_pane() { PANES+=("$1$SEP$2$SEP$3$SEP$4$SEP$5"); }
add_step() { STEPS+=("$1$SEP$2$SEP$3$SEP$4$SEP$5"); }

add_toolchain() {
	local t
	for t in "${TOOLCHAINS[@]:-}"; do
		[ "$t" = "$1" ] && return 0
	done
	TOOLCHAINS+=("$1")
	return 0
}

# Directories that hold code the project no longer runs. They still carry a real
# manifest, so detection finds them; leaving them unrecommended keeps them in the
# table for the user to opt into rather than silently starting a dead server.
dormant_dir() {
	case "$1" in
	*archive* | *.old | *-old | *.bak | *backup* | *deprecated* | \
		examples | */examples | fixtures | */fixtures | vendor | */vendor) return 0 ;;
	esac
	return 1
}

rec_field() {
	# $1 = record, $2 = 1-based field index
	printf '%s' "$1" | cut -d"$SEP" -f"$2"
}

has_pane() {
	local rec
	for rec in "${PANES[@]:-}"; do
		[ -n "$rec" ] || continue
		[ "$(rec_field "$rec" 1)" = "$1" ] && return 0
	done
	return 1
}

# Pane ids double as herdr labels and as --panes= selectors, so keep them to a
# shell-safe word and never let a directory basename collide with a reserved id.
is_ascii() {
	[ -n "$1" ] || return 1
	! printf '%s' "$1" | LC_ALL=C grep -q '[^ -~]'
}

# Fold accents to plain ASCII, so `Affärsplan` becomes the `Affarsplan` a human
# would have typed. Two routes because the iconv implementations differ: BSD
# iconv's //TRANSLIT renders ä as `"a`, while decomposing to NFD first and then
# dropping the combining marks gives `a` on both. GNU iconv has no UTF-8-MAC, so
# it falls through to //TRANSLIT, which behaves properly there.
ascii_fold() {
	local s=$1 out
	out=$(printf '%s' "$s" | iconv -f UTF-8 -t UTF-8-MAC 2>/dev/null |
		iconv -f UTF-8 -t ASCII//IGNORE 2>/dev/null)
	is_ascii "$out" && {
		printf '%s' "$out"
		return 0
	}
	out=$(printf '%s' "$s" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null)
	is_ascii "$out" && {
		printf '%s' "$out"
		return 0
	}
	printf '%s' "$s"
}

pane_id_for() {
	local base=$1 id
	# `tr` works on bytes, so a multi-byte character would otherwise become one
	# dash per byte — or leave an invalid byte — inside what is about to be a
	# herdr label and a --panes= selector. Lowercase too: the id is something the
	# user types, and a capitalised directory would otherwise produce an id that
	# differs from the same one written by hand only in case — which --heal then
	# reads as a component with no pane.
	id=$(ascii_fold "$base")
	id=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]' |
		tr -c '[:alnum:]_-' '-' | sed 's/^-*//; s/-*$//')
	[ -n "$id" ] || id=app
	case "$id" in
	agent | shell) id="$id-app" ;;
	esac
	while has_pane "$id"; do
		id="$id-2"
	done
	printf '%s' "$id"
}

# --- node -------------------------------------------------------------------

# Lockfiles usually sit at the repo root in a monorepo, so a component's package
# manager is decided by its own lockfile first and the root's second.
node_pm() {
	local d=$1 p
	for p in "$d" "."; do
		local pre="${p%/}"
		[ "$pre" = "." ] && pre=""
		[ -n "$pre" ] && pre="$pre/"
		if [ -e "$REPO_ROOT/${pre}pnpm-lock.yaml" ]; then
			printf 'pnpm'
			return 0
		fi
		if [ -e "$REPO_ROOT/${pre}yarn.lock" ]; then
			printf 'yarn'
			return 0
		fi
		if [ -e "$REPO_ROOT/${pre}bun.lock" ] || [ -e "$REPO_ROOT/${pre}bun.lockb" ]; then
			printf 'bun'
			return 0
		fi
	done
	printf 'npm'
}

# How this package manager runs a binary from node_modules.
pm_exec() {
	case "$1" in
	pnpm) printf 'pnpm exec' ;;
	yarn) printf 'yarn' ;;
	bun) printf 'bunx' ;;
	*) printf 'npx' ;;
	esac
}

# A framework config beside a package.json that defines no dev-server script.
# Sets FRONTEND_MARKER_FILE / FRONTEND_MARKER_CMD rather than echoing them: it
# calls probe(), and a command substitution would run that in a subshell where
# every appended probe is discarded — leaving --scan unable to show the very
# inference that produced the pane.
FRONTEND_MARKER_FILE=""
FRONTEND_MARKER_CMD=""

frontend_marker() {
	local pre=$1 f entry
	FRONTEND_MARKER_FILE=""
	FRONTEND_MARKER_CMD=""
	# SvelteKit and Remix both run through vite.
	for entry in \
		'vite.config.ts vite' 'vite.config.js vite' 'vite.config.mts vite' \
		'vite.config.mjs vite' 'next.config.ts next dev' 'next.config.js next dev' \
		'next.config.mjs next dev' 'astro.config.ts astro dev' \
		'astro.config.mjs astro dev' 'nuxt.config.ts nuxt dev' \
		'nuxt.config.js nuxt dev' 'svelte.config.js vite' 'remix.config.js vite'; do
		f=${entry%% *}
		if probe "${pre}${f}"; then
			FRONTEND_MARKER_FILE=$f
			FRONTEND_MARKER_CMD=${entry#* }
			return 0
		fi
	done
	return 1
}

node_script() {
	# $1 = package.json path; echoes the first dev-server script it offers
	local want
	for want in dev start serve develop; do
		if jq -e --arg s "$want" '.scripts // {} | has($s)' "$1" >/dev/null 2>&1; then
			printf '%s' "$want"
			return 0
		fi
	done
	return 1
}

# --- component detection ----------------------------------------------------
# A component is a tracked directory carrying a manifest. Each one that can serve
# something becomes a pane; directories that only build are left alone.

detect_components() {
	local manifests dir seen=""
	manifests=$(printf '%s\n' "$TRACKED" |
		grep -E '(^|/)(package\.json|encore\.app|Cargo\.toml|manage\.py|Gemfile)$' |
		awk -F/ 'NF<=3')

	# Root first, so the agent pane and the root dev server keep a stable order.
	detect_one_component "."
	seen="$seen$SEP."

	# `xargs -n1 dirname` inside an unquoted $( ) would split twice on whitespace,
	# so a tracked `Business Plan/package.json` became the two bogus directories
	# `Business` and `Plan`. Strip the basename with sed and read whole lines.
	while IFS= read -r dir; do
		[ -n "$dir" ] || continue
		case "$SEP$seen$SEP" in *"$SEP$dir$SEP"*) continue ;; esac
		seen="$seen$SEP$dir"
		detect_one_component "$dir"
	done < <(printf '%s\n' "$manifests" | grep '/' | sed 's|/[^/]*$||' | sort -u)
	return 0
}

detect_one_component() {
	local dir=$1 pre="" id cmd="" src="" rec=1
	[ "$dir" != "." ] && pre="$dir/"
	dormant_dir "$dir" && rec=0

	# Encore owns the whole backend loop — its own runner supersedes `go run`.
	if probe "${pre}encore.app"; then
		cmd="encore run"
		src="${pre}encore.app"
	elif probe "${pre}package.json"; then
		local pm script
		pm=$(node_pm "$dir")
		if script=$(node_script "$REPO_ROOT/${pre}package.json"); then
			cmd="$pm install && $pm run $script"
			src="${pre}package.json"
			add_toolchain "node($pm)"
		elif frontend_marker "$pre"; then
			# A named script is preferred, but plenty of frontend packages define
			# only build/preview/test and are started through the framework's own
			# binary. Same shape as the Cargo and Rails arms below: the manifest
			# gets us here, a secondary marker decides the command.
			cmd="$pm install && $(pm_exec "$pm") $FRONTEND_MARKER_CMD"
			src="${pre}${FRONTEND_MARKER_FILE}"
			add_toolchain "node($pm)"
		fi
	elif probe "${pre}manage.py"; then
		local run=""
		[ -e "$REPO_ROOT/uv.lock" ] && run="uv run "
		cmd="${run}python manage.py runserver"
		src="${pre}manage.py"
		add_toolchain django
	elif probe "${pre}Cargo.toml"; then
		# A workspace root has no binary of its own to run.
		if [ -e "$REPO_ROOT/${pre}src/main.rs" ]; then
			cmd="cargo run"
			src="${pre}Cargo.toml"
			add_toolchain rust
		fi
	elif probe "${pre}Gemfile"; then
		if [ -e "$REPO_ROOT/${pre}bin/rails" ]; then
			cmd="bundle install && bin/rails server"
			src="${pre}Gemfile"
			add_toolchain rails
		fi
	fi

	[ -n "$cmd" ] || return 0

	if [ "$dir" = "." ]; then
		id=$(pane_id_for dev)
	else
		id=$(pane_id_for "$(basename "$dir")")
	fi
	add_pane "$id" "$dir" "$cmd" "$rec" "$src"
	return 0
}

# --- steps ------------------------------------------------------------------

detect_forge() {
	local url
	url=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null) || return 0
	case "$url" in
	*github*) printf 'github' ;;
	*gitlab*) printf 'gitlab' ;;
	esac
	return 0
}

# No `[list] url` step. Worktrunk can show a per-worktree URL built from
# `hash_port`, but nothing here makes a dev server listen on that port — Vite,
# Next and encore each take their port their own way. Advertising a port nothing
# binds to is worse than showing no column at all.
detect_steps() {
	local forge
	if probe .gitignore; then
		add_step copy post-start "wt step copy-ignored" 1 .gitignore
	fi
	add_step herdr post-start "open a herdr workspace and run the panes" 1 herdr
	add_step close pre-remove "close the herdr workspace" 1 herdr
	forge=$(detect_forge)
	if [ -n "$forge" ]; then
		add_step forge forge "platform = \"$forge\"" 0 origin
	fi
	return 0
}

run_detection() {
	# --heal --fix diagnoses and then delegates to apply, so detection runs twice
	# in one process. Starting from empty keeps the second pass from stacking a
	# duplicate set of panes on top of the first.
	PANES=()
	STEPS=()
	TOOLCHAINS=()
	PROBES=()

	# The agent pane is the reason this config exists: `wta` skips launching an
	# agent whenever .config/wt.toml is present, so without this pane a new
	# worktree opens with nothing running in it.
	add_pane agent . claude 1 wta
	detect_components
	add_pane shell . "" 0 always
	merge_extra
	detect_steps
	return 0
}

# --- agent-discovered panes -------------------------------------------------

EXTRA_IDS=""

merge_extra() {
	[ -n "$EXTRA_FILE" ] || return 0
	if [ ! -f "$EXTRA_FILE" ]; then
		printf 'error: --extra file not found: %s\n' "$EXTRA_FILE"
		printf 'help: write a JSON array of {id, dir, command} and pass its path\n'
		exit 1
	fi
	if ! jq -e 'type == "array"' "$EXTRA_FILE" >/dev/null 2>&1; then
		printf 'error: --extra file is not a JSON array: %s\n' "$EXTRA_FILE"
		printf 'help: [{"id":"worker","dir":"services/worker","command":"npm run worker"}]\n'
		exit 1
	fi
	local n i id dir cmd
	n=$(jq 'length' "$EXTRA_FILE")
	for ((i = 0; i < n; i++)); do
		id=$(jq -r --argjson i "$i" '.[$i].id // empty' "$EXTRA_FILE")
		dir=$(jq -r --argjson i "$i" '.[$i].dir // "."' "$EXTRA_FILE")
		cmd=$(jq -r --argjson i "$i" '.[$i].command // ""' "$EXTRA_FILE")
		if [ -z "$id" ]; then
			printf 'error: --extra entry %s has no id\n' "$i"
			printf 'help: every entry needs {"id": "..."}\n'
			exit 1
		fi
		has_pane "$id" && continue
		add_pane "$id" "$dir" "$cmd" 1 "$(basename "$EXTRA_FILE")"
		EXTRA_IDS="$EXTRA_IDS${EXTRA_IDS:+,}$id"
	done
	return 0
}

# --- existing state --------------------------------------------------------

CONFIG_STATE=absent # absent | managed | unmanaged

read_existing_state() {
	if [ -f "$CONFIG" ]; then
		if head -3 "$CONFIG" | grep -qF "$MARKER"; then
			CONFIG_STATE=managed
		else
			CONFIG_STATE=unmanaged
		fi
	fi
	return 0
}

print_header() {
	printf 'bin: %s\n' "${SELF/#$HOME/\~}"
	printf 'repo: %s\n' "$REPO"
	printf 'mode: %s\n' "$MODE"
	case "$CONFIG_STATE" in
	absent) printf 'config: absent\n' ;;
	managed) printf 'config: .config/wt.toml, managed by this skill\n' ;;
	unmanaged) printf 'config: .config/wt.toml, hand-written (not managed by this skill)\n' ;;
	esac
	printf 'herdr: %s\n' "$HERDR_STATE"
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
	if grep -qiE 'worktrunk|wt\.toml|\bwta\b' "$REPO_ROOT/$rm"; then
		printf 'readme: %s, worktrees already documented\n' "$rm"
	else
		printf 'readme: %s, worktrees not documented\n' "$rm"
	fi
	return 0
}

print_readme_snippet() {
	printf 'snippet:\n'
	printf '  ## Worktrees\n'
	printf '  \n'
	printf '  `wta <branch>` opens a worktree with the agent and dev servers already\n'
	printf '  running, from the hooks in `.config/wt.toml`.\n'
	printf '  \n'
	printf '  ```bash\n'
	printf '  wta fix-auth        # new worktree off the default branch\n'
	printf '  wt list             # what is checked out where\n'
	printf '  wt remove           # tear the worktree and its panes down\n'
	printf '  ```\n'
	return 0
}

# --- rendering -------------------------------------------------------------

print_pane_table() {
	local rows=() rec id dir cmd r src mark
	for rec in "${PANES[@]:-}"; do
		[ -n "$rec" ] || continue
		IFS="$SEP" read -r id dir cmd r src <<<"$rec"
		[ "$r" = 1 ] && mark="Y" || mark=""
		[ -n "$cmd" ] || cmd="-"
		rows+=("  $mark,$id,$dir,$cmd,$src")
	done
	printf 'panes[%s]{on,id,dir,command,source}:\n' "${#rows[@]}"
	printf '%s\n' "${rows[@]}"
	return 0
}

print_step_table() {
	local rows=() rec id hook summary r src mark
	for rec in "${STEPS[@]:-}"; do
		[ -n "$rec" ] || continue
		IFS="$SEP" read -r id hook summary r src <<<"$rec"
		[ "$r" = 1 ] && mark="Y" || mark=""
		rows+=("  $mark,$id,$hook,$summary,$src")
	done
	printf 'steps[%s]{on,id,hook,detail,source}:\n' "${#rows[@]}"
	printf '%s\n' "${rows[@]}"
	return 0
}

recommended_ids() {
	# $1 = panes | steps
	local rec id r out="" arr
	if [ "$1" = panes ]; then arr=("${PANES[@]:-}"); else arr=("${STEPS[@]:-}"); fi
	for rec in "${arr[@]:-}"; do
		[ -n "$rec" ] || continue
		id=$(rec_field "$rec" 1)
		r=$(rec_field "$rec" 4)
		[ "$r" = 1 ] || continue
		out="$out${out:+,}$id"
	done
	printf '%s' "$out"
	return 0
}

# --- config generation -----------------------------------------------------

# Wrap a command for the generated bash. Single-quoting is the only form that
# survives a dev command containing $, backticks or globs untouched.
shquote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

want_pane() {
	case ",$WANT_PANES," in *",$1,"*) return 0 ;; esac
	return 1
}

want_step() {
	case ",$WANT_STEPS," in *",$1,"*) return 0 ;; esac
	return 1
}

selected_panes() {
	# Emit selected pane records in layout order: agent first, shell last.
	local rec id order
	for order in agent other shell; do
		for rec in "${PANES[@]:-}"; do
			[ -n "$rec" ] || continue
			id=$(rec_field "$rec" 1)
			want_pane "$id" || continue
			case "$order:$id" in
			agent:agent | shell:shell) ;;
			other:agent | other:shell) continue ;;
			agent:* | shell:*) continue ;;
			esac
			printf '%s\n' "$rec"
		done
	done
	return 0
}

# The layout: the agent owns the root pane, the first extra splits off to the
# right, and the rest stack down that column. Focus is decided at creation —
# herdr has no `pane focus <id>` verb — so every split is --no-focus and the
# workspace focus at the end lands back on the agent.
gen_herdr_block() {
	local rec id dir cmd n=0 var prev="" cwd agent_cmd=""
	printf 'set -eu\n'
	printf 'command -v herdr >/dev/null 2>&1 || exit 0\n'
	# --cwd names the parent checkout, not the new worktree: herdr opens a linked
	# worktree from its repo's parent workspace, and with no --cwd at all it
	# resolves the source from whichever workspace the UI happens to have focused
	# — which is not this repo when a hook fires in the background.
	printf 'out=$(herdr worktree open --cwd {{ primary_worktree_path }} --path {{ worktree_path }} --label {{ branch | sanitize }} --no-focus --json) || exit 0\n'
	# Re-entry guard: `worktree open` is idempotent per checkout and reports when
	# it reused a workspace. Without this, a second run would start a second dev
	# server inside the panes that are already there.
	printf '[ "$(printf %%s "$out" | jq -r .result.already_open)" = false ] || exit 0\n'
	printf 'ws=$(printf %%s "$out" | jq -r .result.workspace.workspace_id)\n'

	while IFS="$SEP" read -r id dir cmd _ _; do
		[ -n "$id" ] || continue
		n=$((n + 1))
		var="p$n"
		# Single-quote the whole argument, placeholder included. `{{ worktree_path }}`
		# is substituted by worktrunk before any shell sees the line, so quoting
		# only the directory would leave the expanded path unquoted and split a
		# component whose name contains a space. Escape any quote in the directory
		# itself the same way shquote does.
		cwd="'{{ worktree_path }}'"
		[ "$dir" != "." ] && cwd="'{{ worktree_path }}/${dir//\'/\'\\\'\'}'"
		if [ "$n" -eq 1 ]; then
			printf '%s=$(printf %%s "$out" | jq -r .result.root_pane.pane_id)\n' "$var"
		elif [ -z "$prev" ]; then
			printf '%s=$(herdr pane split --pane "$p1" --direction right --cwd %s --no-focus | jq -r .result.pane.pane_id)\n' "$var" "$cwd"
			prev="$var"
		else
			printf '%s=$(herdr pane split --pane "$%s" --direction down --cwd %s --no-focus | jq -r .result.pane.pane_id)\n' "$var" "$prev" "$cwd"
			prev="$var"
		fi
		printf 'herdr pane rename "$%s" %s\n' "$var" "$(shquote "$id")"
		# The root pane's command waits until the splits are done: starting a
		# full-screen agent TUI and then carving panes out from under it makes it
		# redraw for every split.
		if [ "$n" -eq 1 ]; then
			agent_cmd=$cmd
		elif [ -n "$cmd" ]; then
			printf 'herdr pane run "$%s" %s\n' "$var" "$(shquote "$cmd")"
		fi
	done < <(selected_panes)

	[ -n "$agent_cmd" ] && printf 'herdr pane run "$p1" %s\n' "$(shquote "$agent_cmd")"
	printf 'herdr workspace focus "$ws"\n'
	return 0
}

gen_close_block() {
	printf 'set -eu\n'
	printf 'command -v herdr >/dev/null 2>&1 || exit 0\n'
	printf 'ws=$(herdr worktree list --cwd {{ worktree_path }} --json | jq -r --arg p {{ worktree_path }} '"'"'.result.worktrees[] | select(.path==$p) | .open_workspace_id'"'"')\n'
	# The worktree is on its way out; a workspace that is already gone is not a
	# failure, and a pre-remove that exits non-zero would abort the removal.
	printf '[ -n "$ws" ] && [ "$ws" != null ] && herdr workspace close "$ws" || true\n'
	return 0
}

# Blocks are separated by a blank line *before* each one, never after. A trailing
# separator would leave the file ending on a blank line, which the repo's own
# end-of-file-fixer hook then strips — so every --apply produced a file that was
# dirty the moment it was written, and re-dirtied it on the next run.
gen_config() {
	local forge
	printf '%s — re-run it to change the layout\n' "$MARKER"
	printf '# regenerate: bash %s --apply --accept\n' "${SELF/#$HOME/\~}"

	if want_step copy; then
		# Runs before the panes so a CoW copy of node_modules/target is already in
		# place when the dev panes start installing.
		printf '\n[[post-start]]\n'
		printf 'copy = "wt step copy-ignored"\n'
	fi

	if want_step herdr; then
		printf '\n[[post-start]]\n'
		printf "herdr = '''\n"
		gen_herdr_block
		printf "'''\n"
	fi

	if want_step close; then
		printf '\n[pre-remove]\n'
		printf "herdr = '''\n"
		gen_close_block
		printf "'''\n"
	fi

	if want_step forge; then
		forge=$(detect_forge)
		if [ -n "$forge" ]; then
			printf '\n[forge]\n'
			printf 'platform = "%s"\n' "$forge"
		fi
	fi
	return 0
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
	print_pane_table
	printf '\n'
	print_step_table
	printf '\n'
	print_readme_state

	[ "$MODE" = scan ] && print_scan_tables

	if [ "$CONFIG_STATE" = unmanaged ]; then
		printf 'blocked: .config/wt.toml exists and this skill did not write it\n'
		printf 'help: run --heal to diagnose it, or --apply --force to replace it\n'
		return 0
	fi

	local nserv=0 rec
	for rec in "${PANES[@]:-}"; do
		[ -n "$rec" ] || continue
		[ -n "$(rec_field "$rec" 3)" ] && nserv=$((nserv + 1))
	done
	# agent always has a command, so one means nothing else runs.
	if [ "$nserv" -le 1 ] && [ "$MODE" != scan ]; then
		printf 'note: no dev servers detected, only the agent pane\n'
		printf 'help: run --scan to have an agent look for services the heuristics missed\n'
	fi
	if [ "$HERDR_STATE" = absent ]; then
		printf 'note: herdr is not on PATH, so the generated hooks will no-op here\n'
	fi
	printf 'next: bash %s --apply --accept\n' "${SELF/#$HOME/\~}"
	printf 'help: change the set with --apply --panes=<ids> --steps=<ids>\n'
	return 0
}

print_scan_tables() {
	printf '\n'
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
	local json
	json=$("$WT" hook show --format json 2>/dev/null)
	if [ -z "$json" ] || ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
		printf 'hooks: unreadable\n'
		printf 'help: bash %s --heal\n' "${SELF/#$HOME/\~}"
		return 0
	fi
	local rows
	rows=$(printf '%s' "$json" |
		jq -r '.[] | select(.source == "project") | "  \(.name),\(.type),\(.needs_approval)"')
	if [ -z "$rows" ]; then
		printf 'hooks: 0 project hooks configured\n'
		return 0
	fi
	printf 'hooks[%s]{name,type,needs-approval}:\n' "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
	printf '%s\n' "$rows"
	print_approval_state
	return 0
}

# Returns 0 when approval is outstanding, so callers can word their own next step
# around it rather than printing a second, competing `next:`.
print_approval_state() {
	local pending
	pending=$("$WT" hook show --format json 2>/dev/null |
		jq -r '[.[] | select(.source == "project" and .needs_approval)] | length' 2>/dev/null)
	if [ -n "$pending" ] && [ "$pending" != 0 ]; then
		printf 'approval: %s project hook(s) awaiting approval\n' "$pending"
		printf 'next: wt config approvals add\n'
		printf 'help: approving lets this repo run its hook commands on this machine — the user decides\n'
		return 0
	fi
	return 1
}

do_apply() {
	read_existing_state
	run_detection

	if [ "$CONFIG_STATE" = unmanaged ] && [ "$FORCE" = false ]; then
		printf 'error: .config/wt.toml exists and this skill did not write it\n'
		printf 'repo: %s\n' "$REPO"
		printf 'cause: overwriting it would discard hand-written hooks\n'
		printf 'help: bash %s --heal   # diagnose what is there\n' "${SELF/#$HOME/\~}"
		printf 'help: bash %s --apply --force   # replace it\n' "${SELF/#$HOME/\~}"
		exit 1
	fi

	if [ "$ACCEPT" = true ]; then
		WANT_PANES=$(recommended_ids panes)
		WANT_STEPS=$(recommended_ids steps)
	else
		WANT_PANES=$SEL_PANES
		WANT_STEPS=$SEL_STEPS
	fi

	local id
	for id in ${WANT_PANES//,/ }; do
		has_pane "$id" && continue
		printf 'error: unknown pane id %s\n' "$id"
		printf 'help: valid pane ids: %s\n' "$(
			for rec in "${PANES[@]:-}"; do
				[ -n "$rec" ] && printf '%s ' "$(rec_field "$rec" 1)"
			done
		)"
		exit 2
	done

	# ...and the reverse. An extra the caller supplied but did not name is dropped
	# by the selection, which used to happen silently — the report simply echoed
	# --panes back. Say so instead: `--extra` offers a pane, the selection still
	# decides.
	local dropped=""
	for id in $(printf '%s' "$EXTRA_IDS" | tr ',' ' '); do
		[ -n "$id" ] || continue
		want_pane "$id" || dropped="$dropped${dropped:+,}$id"
	done
	if [ -n "$dropped" ]; then
		printf 'error: --extra pane(s) not in the selection: %s\n' "$dropped"
		printf 'cause: an explicit --panes= list decides the whole layout\n'
		printf 'help: add the id to --panes=, or pass --accept to take every recommended pane\n'
		exit 2
	fi

	if [ -z "$WANT_PANES" ]; then
		printf 'error: no panes selected\n'
		printf 'cause: a workspace with no panes is not worth opening\n'
		printf 'help: --apply --accept, or name ids with --panes=agent,frontend\n'
		exit 2
	fi

	# The hook body goes into a TOML literal string, which cannot carry three
	# consecutive quotes. Only pane ids and commands reach it from outside this
	# script, so check those rather than the rendered file — where the `'''`
	# delimiters legitimately appear.
	local pid pcmd
	while IFS="$SEP" read -r pid _ pcmd _ _; do
		case "$pid$pcmd" in
		*"'''"*)
			printf 'error: pane %s contains a triple quote\n' "$pid"
			printf 'cause: it would close the TOML literal string early\n'
			printf 'help: rename the offending script, or pass a simpler command via --extra\n'
			exit 1
			;;
		esac
	done < <(selected_panes)

	local tmp
	mkdir -p "$REPO_ROOT/.config"
	tmp="$REPO_ROOT/.config/.wt.toml.swt"
	gen_config >"$tmp"

	# Validate before the file is in place: wt reads .config/wt.toml by path, so
	# swap it in only once it parses and every template renders.
	local backup=""
	if [ -f "$CONFIG" ]; then
		backup="$REPO_ROOT/.config/.wt.toml.bak"
		cp "$CONFIG" "$backup"
	fi
	mv "$tmp" "$CONFIG"

	local bad=""
	if ! "$WT" hook show --format json >/dev/null 2>&1; then
		bad="the config does not parse"
	else
		local h
		for h in post-start pre-remove; do
			"$WT" hook "$h" --dry-run >/dev/null 2>&1 || bad="a $h template does not render"
		done
	fi

	if [ -n "$bad" ]; then
		if [ -n "$backup" ]; then
			mv "$backup" "$CONFIG"
		else
			rm -f "$CONFIG"
		fi
		printf 'error: generated config rejected by wt\n'
		printf 'cause: %s\n' "$bad"
		printf 'help: wt hook post-start --dry-run   # see the failure\n'
		exit 1
	fi
	rm -f "$backup"

	printf 'wrote: .config/wt.toml\n'
	printf 'panes: %s\n' "$WANT_PANES"
	printf 'steps: %s\n' "$WANT_STEPS"
	printf 'validated: wt hook show, post-start and pre-remove dry-run\n'
	print_readme_state
	grep -qiE 'worktrunk|wt\.toml|\bwta\b' "$REPO_ROOT/README.md" 2>/dev/null || print_readme_snippet
	if print_approval_state; then
		printf 'help: after approval, `wta <branch>` opens the workspace\n'
	else
		printf 'next: wta <branch>   # opens the workspace\n'
	fi
	return 0
}

# --- heal ------------------------------------------------------------------

FINDINGS=()
finding() { FINDINGS+=("$1"); }

do_heal() {
	read_existing_state
	run_detection
	print_header

	if [ "$CONFIG_STATE" = absent ]; then
		printf 'nothing: no .config/wt.toml in this repo\n'
		printf 'next: bash %s\n' "${SELF/#$HOME/\~}"
		return 0
	fi

	heal_parse
	heal_schema
	heal_commands
	heal_panes
	heal_block_currency

	if [ "${#FINDINGS[@]}" -eq 0 ]; then
		printf 'healthy: no drift found\n'
		print_approval_state
		return 0
	fi

	printf 'findings: %s\n' "${#FINDINGS[@]}"
	local f
	for f in "${FINDINGS[@]}"; do
		printf 'drift: %s\n' "$f"
	done

	if [ "$FIX" = false ]; then
		printf 'next: bash %s --heal --fix\n' "${SELF/#$HOME/\~}"
		if [ "$CONFIG_STATE" = managed ]; then
			printf 'help: --fix regenerates the managed config from what the repo runs now\n'
		else
			printf 'help: this config is hand-written, so --fix reports and changes nothing\n'
		fi
		return 0
	fi

	if [ "$CONFIG_STATE" != managed ]; then
		printf 'refused: this config is hand-written, so nothing was changed\n'
		printf 'help: fix the entries above by hand, or --apply --force to replace the file\n'
		return 0
	fi

	printf 'fixing: regenerating from the current repository\n' >&2
	ACCEPT=true
	FORCE=true
	MODE=apply
	do_apply
	return 0
}

heal_parse() {
	"$WT" hook show --format json >/dev/null 2>&1 ||
		finding "the config does not parse — wt hook show fails"
	local h
	for h in post-start pre-remove post-switch pre-start; do
		grep -q "^\[\[\?$h\]\]\?" "$CONFIG" 2>/dev/null || continue
		"$WT" hook "$h" --dry-run >/dev/null 2>&1 ||
			finding "a $h template does not render — wt hook $h --dry-run fails"
	done
	return 0
}

# Worktrunk warns rather than errors on a field the installed version no longer
# knows, so schema drift is invisible unless stderr is read. This is the check
# that a config still matches the tooling it was written for.
heal_schema() {
	local warn
	# NO_COLOR keeps wt's styling out of the finding; the sed is the belt to that
	# braces, since a leaked escape sequence would land in the agent's transcript.
	warn=$(NO_COLOR=1 "$WT" hook show --format json 2>&1 >/dev/null |
		grep -i 'project config' |
		sed $'s/\033\\[[0-9;]*m//g; s/^[^A-Za-z]*//')
	[ -n "$warn" ] || return 0
	local line
	while IFS= read -r line; do
		[ -n "$line" ] && finding "$line"
	done <<<"$warn"
	return 0
}

heal_commands() {
	local body
	body=$(cat "$CONFIG" 2>/dev/null)
	local bin
	# Only the binaries this script ever generates; a hand-written config may name
	# anything, and guessing at those would produce noise rather than findings.
	for bin in herdr encore cargo bundle uv; do
		printf '%s' "$body" | grep -q "\b$bin\b" || continue
		have "$bin" && continue
		finding "the config runs \`$bin\`, which is not on PATH"
	done
	# A pane pointing at an npm script the project has since dropped. Which
	# package.json owns the script depends on the pane's directory — a monorepo can
	# define `dev` in three of them and mean three different things — so resolve
	# each command against the pane it runs in.
	if [ "$CONFIG_STATE" = managed ]; then
		heal_scripts_by_pane "$body"
	else
		heal_scripts_anywhere "$body"
	fi
	return 0
}

# In a managed block each pane's directory is on its `pane split` line, so a
# command can be checked against the manifest that actually backs it.
heal_scripts_by_pane() {
	local body=$1 dirs var dir cmd pm script
	dirs=$(printf '%s\n' "$body" |
		sed -n 's|^\(p[0-9]*\)=\$(herdr pane split .*--cwd {{ worktree_path }}/\([^ ]*\) .*|\1 \2|p')
	while read -r var cmd; do
		[ -n "$var" ] || continue
		dir=$(printf '%s\n' "$dirs" | awk -v v="$var" '$1 == v {print $2; exit}')
		[ -n "$dir" ] || dir="."
		# Clear first: a pane whose command names no script leaves `read` untouched,
		# and the previous pane's script would be checked against this pane's
		# directory.
		pm=""
		script=""
		read -r pm script < <(printf '%s' "$cmd" |
			grep -oE '\b(npm|pnpm|yarn|bun) run [a-zA-Z0-9:_-]+' | awk '{print $1, $3}' | head -1)
		[ -n "$script" ] || continue
		local mf="$REPO_ROOT/${dir%/}/package.json"
		[ "$dir" = "." ] && mf="$REPO_ROOT/package.json"
		[ -f "$mf" ] || continue
		jq -e --arg s "$script" '.scripts // {} | has($s)' "$mf" >/dev/null 2>&1 && continue
		finding "the config runs \`$pm run $script\` in \`$dir/\`, which its package.json no longer defines"
	done < <(printf '%s\n' "$body" | sed -n "s|^herdr pane run \"\\\$\(p[0-9]*\)\" '\(.*\)'\$|\1 \2|p")
	return 0
}

# A hand-written config need not say where a command runs, so the most that can
# be claimed is that no manifest in the repo defines the script at all.
heal_scripts_anywhere() {
	local body=$1 pm script manifests found m
	manifests=$(printf '%s\n' "$TRACKED" | grep -E '(^|/)package\.json$')
	[ -n "$manifests" ] || return 0
	while read -r pm script; do
		[ -n "$script" ] || continue
		found=false
		while read -r m; do
			[ -n "$m" ] || continue
			if jq -e --arg s "$script" '.scripts // {} | has($s)' "$REPO_ROOT/$m" >/dev/null 2>&1; then
				found=true
				break
			fi
		done <<<"$manifests"
		[ "$found" = true ] && continue
		finding "the config runs \`$pm run $script\`, which no package.json defines"
	done < <(printf '%s' "$body" | grep -oE '\b(npm|pnpm|yarn|bun) run [a-zA-Z0-9:_-]+' | awk '{print $1, $3}' | sort -u)
	return 0
}

heal_panes() {
	local body dir
	body=$(cat "$CONFIG" 2>/dev/null)
	while read -r dir; do
		[ -n "$dir" ] || continue
		[ -d "$REPO_ROOT/$dir" ] && continue
		finding "a pane opens in \`$dir/\`, which no longer exists"
		# An ASCII-only character class here truncated `Affärsplan` at the first
		# non-ASCII byte, so a live pane was reported as opening in `Aff/` — and
		# --heal --fix then regenerated the config without it. Match to the end of
		# the shell token instead, and let the -d test decide what really exists.
	done < <(printf '%s' "$body" | grep -oE "\\{\\{ worktree_path \\}\\}/[^ '\"]+" | sed 's|.*}}/||' | sort -u)

	# A component the repo has grown since the config was written. Only the ones
	# detection would recommend today count — a dormant directory left out on
	# purpose is not drift.
	local rec id r
	for rec in "${PANES[@]:-}"; do
		[ -n "$rec" ] || continue
		id=$(rec_field "$rec" 1)
		r=$(rec_field "$rec" 4)
		[ "$r" = 1 ] || continue
		case "$id" in agent | shell) continue ;; esac
		printf '%s' "$body" | grep -q "\b$id\b" ||
			finding "\`$id\` runs in this repo but has no pane"
	done
	return 0
}

# The generated block is a snapshot of herdr's CLI. When this script learns a new
# shape, every config written by the old one is stale — catch that here rather
# than leaving a repo on a block that no longer works.
heal_block_currency() {
	[ "$CONFIG_STATE" = managed ] || return 0
	grep -q 'herdr worktree open' "$CONFIG" 2>/dev/null ||
		finding "the managed block predates the current generator — regenerate it"
	grep -q 'already_open' "$CONFIG" 2>/dev/null ||
		finding "the managed block has no re-entry guard — regenerate it"
	if grep -q 'herdr worktree open' "$CONFIG" 2>/dev/null &&
		! grep -q 'worktree open --cwd' "$CONFIG" 2>/dev/null; then
		finding "the managed block opens a worktree without naming its parent checkout — regenerate it"
	fi
	return 0
}

# --- dispatch --------------------------------------------------------------

case "$MODE" in
plan | scan) do_plan ;;
apply) do_apply ;;
heal) do_heal ;;
status) do_status ;;
esac
