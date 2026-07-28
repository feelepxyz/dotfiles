#!/usr/bin/env bash
# shellcheck disable=SC2016 # backticks in help prose are literal markup, not substitution
# Roll four repository-setup checks into one report: Entire, git hooks,
# worktrunk and GitHub housekeeping.
#
# This script only reads. Two of the four areas need the user to choose from a
# table before anything is written, which a script cannot do, so converging is
# left to the individual skills and sequenced by SKILL.md.
#
# Output follows AXI conventions: structured key/value and TOON tables on stdout
# (errors included), progress on stderr, exit 0 for success and no-ops, 1 for
# errors, 2 for usage.
#
# Invoke with `bash setup-repo.sh` — `npx skills` copies skill files without the
# executable bit, so a direct exec would fail.

set -uo pipefail

SELF=${BASH_SOURCE[0]}
SEP=$'\037'

# Siblings are resolved as sibling *directories*, which holds in both layouts:
# ~/.agents/skills/setup-repo/../setup-entire/setup-entire.sh when installed,
# and ~/.dotfiles/skills/custom/setup-repo/../setup-entire/... at the source.
SKILL_DIR=$(cd "$(dirname "$SELF")" && pwd)
SIBLINGS=$(dirname "$SKILL_DIR")
SIBLINGS_SHOWN=${SIBLINGS/#$HOME/\~}

usage() {
	printf 'bin: %s\n' "${SELF/#$HOME/\~}"
	printf 'description: Report Entire, git hook, worktrunk and GitHub setup for this repo in one pass\n'
	printf 'modes[1]{mode,writes,job}:\n'
	printf '  --check,nothing,"Roll the four area checks into one report (default)"\n'
	printf 'note: this script never writes — converging each area is its own skill\n'
	printf 'examples[1]:\n'
	printf '  bash %s\n' "${SELF/#$HOME/\~}"
}

flag_error() {
	printf 'error: %s\n' "$1"
	printf 'help: valid flags: --check --help\n'
	exit 2
}

for arg in "$@"; do
	case "$arg" in
	--check) ;;
	-h | --help)
		usage
		exit 0
		;;
	*) flag_error "unknown flag $arg" ;;
	esac
done

if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || [ -z "$REPO_ROOT" ]; then
	printf 'error: not a git repository\n'
	printf 'cwd: %s\n' "${PWD/#$HOME/\~}"
	printf 'cause: all four areas configure a repository, and there is none here\n'
	printf 'help: cd into a repository, or run `git init` yourself first\n'
	exit 1
fi

# --- running the siblings --------------------------------------------------

AREAS=()
NEXT=()
add_area() { AREAS+=("$1$SEP$2$SEP$3"); }

OUT=""
RC=0

# Run a sibling in its read-only mode. A sibling that is not installed leaves
# $OUT empty and $RC at 127, which every classifier reports as `unavailable`
# rather than folding into a converged-looking result.
run_sibling() {
	local skill=$1
	shift
	local script="$SIBLINGS/$skill/$skill.sh"
	if [ ! -f "$script" ]; then
		OUT=""
		RC=127
		return 0
	fi
	printf 'checking %s...\n' "$skill" >&2
	OUT=$(bash "$script" "$@" 2>/dev/null)
	RC=$?
	return 0
}

# First value of a `key: value` line in the captured output.
field() {
	local key=$1 line
	while IFS= read -r line; do
		case "$line" in
		"$key: "*)
			printf '%s' "${line#"$key": }"
			return 0
			;;
		esac
	done <<<"$OUT"
	return 1
}

# The N from a `key[N]{col,col}:` table header. Siblings report a healthy list
# as a table and only fall back to a scalar `key: value` line in the degenerate
# cases, so reading one form without the other inverts the result: the better the
# config, the more likely it looks unreadable.
table_count() {
	local key=$1 line
	while IFS= read -r line; do
		case "$line" in
		"${key}["*)
			line=${line#"$key"[}
			printf '%s' "${line%%]*}"
			return 0
			;;
		esac
	done <<<"$OUT"
	return 1
}

# Siblings report either `pending[N]:` or `pending: 0 — ...`. Echo the count, or
# nothing at all when neither form is present.
pending_count() {
	local line
	while IFS= read -r line; do
		case "$line" in
		"pending["*)
			line=${line#pending[}
			printf '%s' "${line%%]*}"
			return 0
			;;
		"pending: 0"*)
			printf '0'
			return 0
			;;
		esac
	done <<<"$OUT"
	return 1
}

# The `error:` line a sibling prints when it refuses.
error_line() {
	local line
	while IFS= read -r line; do
		case "$line" in
		"error: "*)
			printf '%s' "${line#error: }"
			return 0
			;;
		esac
	done <<<"$OUT"
	return 1
}

unavailable() {
	add_area "$1" unavailable "$2/$2.sh is not installed beside this skill"
	# Unavailable counts as unfinished, so it needs a step of its own — otherwise
	# a run with no siblings reports four pending areas and an empty next[].
	NEXT+=("bash ~/.dotfiles/install/skills.sh   # reinstall skills; $2 is missing")
	return 0
}

# --- entire ----------------------------------------------------------------

run_sibling setup-entire
if [ "$RC" = 127 ]; then
	unavailable entire setup-entire
elif [ "$RC" != 0 ]; then
	add_area entire error "$(error_line || printf 'exited %s' "$RC")"
	NEXT+=("bash $SIBLINGS_SHOWN/setup-entire/setup-entire.sh   # resolve the error above")
else
	n=$(pending_count) || n=""
	enabled=$(field enabled) || enabled=unknown
	if [ -z "$n" ]; then
		add_area entire unknown "could not read a pending count from setup-entire"
		NEXT+=("bash $SIBLINGS_SHOWN/setup-entire/setup-entire.sh")
	elif [ "$n" = 0 ]; then
		add_area entire converged "enabled=$enabled, hooks installed, commit_linking=$(field commit_linking || printf unset)"
	else
		add_area entire pending "$n change(s): enabled=$enabled, commit_linking=$(field commit_linking || printf unset)"
		NEXT+=("bash $SIBLINGS_SHOWN/setup-entire/setup-entire.sh --apply   # autonomous, asks nothing")
	fi
fi

# --- git hooks -------------------------------------------------------------

run_sibling setup-git-hooks --status
if [ "$RC" = 127 ]; then
	unavailable git-hooks setup-git-hooks
elif [ "$RC" != 0 ]; then
	add_area git-hooks error "$(error_line || printf 'exited %s' "$RC")"
	NEXT+=("read $SIBLINGS_SHOWN/setup-git-hooks/SKILL.md   # resolve the error above")
else
	cfg=$(field config) || cfg=""
	shims=$(field shims) || shims="shims unknown"
	case "$cfg" in
	absent)
		# Surface a hook another tool already owns even here. First-time setup is
		# exactly when a foreign shim is most likely and least visible, and it
		# decides whether the hooks step can install at all.
		case "$shims" in
		*foreign*)
			add_area git-hooks pending "no prek.toml — nothing checks a commit; $shims"
			;;
		*)
			add_area git-hooks pending "no prek.toml — nothing checks a commit"
			;;
		esac
		NEXT+=("read $SIBLINGS_SHOWN/setup-git-hooks/SKILL.md   # proposes a hook set, then asks you to choose")
		;;
	*"hand-written"* | *"not managed"*)
		add_area git-hooks unmanaged "prek.toml exists but this skill did not write it; $shims"
		NEXT+=("read $SIBLINGS_SHOWN/setup-git-hooks/SKILL.md   # offers --heal or --force on a foreign config")
		;;
	*managed*)
		# A shim belonging to husky or another manager sits in the same slot
		# prek wants, so the configured hooks are not the ones that run.
		case "$shims" in
		*foreign*)
			add_area git-hooks drifted "$shims — a foreign shim holds that slot"
			NEXT+=("read $SIBLINGS_SHOWN/setup-git-hooks/SKILL.md   # --heal names the drift, then repairs it")
			;;
		# `chained` means another tool holds the slot but calls prek's shim, so
		# the configured hooks do run. That is a working setup, not drift.
		*chained*) add_area git-hooks configured "$shims" ;;
		*) add_area git-hooks configured "$shims" ;;
		esac
		;;
	"")
		add_area git-hooks unknown "could not read a config line from setup-git-hooks"
		NEXT+=("read $SIBLINGS_SHOWN/setup-git-hooks/SKILL.md")
		;;
	*)
		add_area git-hooks configured "$cfg; $shims"
		;;
	esac
fi

# --- worktrunk -------------------------------------------------------------

run_sibling setup-worktrunk --status
if [ "$RC" = 127 ]; then
	unavailable worktrunk setup-worktrunk
elif [ "$RC" != 0 ]; then
	add_area worktrunk error "$(error_line || printf 'exited %s' "$RC")"
	NEXT+=("read $SIBLINGS_SHOWN/setup-worktrunk/SKILL.md   # resolve the error above")
else
	cfg=$(field config) || cfg=""
	# A healthy --status prints `hooks[N]{...}:`; only the degenerate paths print
	# a scalar `hooks: ...`. Try the table first, then the line.
	if hooks=$(table_count hooks); then
		hooks="$hooks project hook(s)"
	else
		hooks=$(field hooks) || hooks="hooks unknown"
	fi
	# Hooks that exist but are unapproved never run, and the documented finish
	# line is the user holding the approvals command — so this is not done yet.
	approval=$(field approval) || approval=""
	case "$cfg" in
	absent)
		add_area worktrunk pending "no .config/wt.toml — wta opens a worktree with nothing running"
		NEXT+=("read $SIBLINGS_SHOWN/setup-worktrunk/SKILL.md   # proposes panes, then asks you to choose")
		;;
	*"hand-written"* | *"not managed"*)
		add_area worktrunk unmanaged "wt.toml exists but this skill did not write it; $hooks"
		NEXT+=("read $SIBLINGS_SHOWN/setup-worktrunk/SKILL.md   # offers --heal or --force on a foreign config")
		;;
	"")
		add_area worktrunk unknown "could not read a config line from setup-worktrunk"
		NEXT+=("read $SIBLINGS_SHOWN/setup-worktrunk/SKILL.md")
		;;
	*)
		case "$approval" in
		*awaiting*)
			add_area worktrunk pending "$approval"
			NEXT+=("wt config approvals add   # hooks are written but cannot run until approved")
			;;
		*)
			add_area worktrunk configured "$hooks"
			;;
		esac
		;;
	esac
fi

# --- github ----------------------------------------------------------------

run_sibling setup-github --plan
if [ "$RC" = 127 ]; then
	unavailable github setup-github
elif [ "$RC" != 0 ]; then
	add_area github error "$(error_line || printf 'exited %s' "$RC")"
	NEXT+=("read $SIBLINGS_SHOWN/setup-github/SKILL.md   # resolve the error above")
elif skipped=$(field github); then
	# `github: skipped — <reason>`; the state column already says skipped.
	add_area github skipped "${skipped#skipped — }"
else
	repo=$(field repo) || repo="?"
	n=$(pending_count) || n=""
	if [ -z "$n" ]; then
		# `pending: N blocked` carries no bracket form — a permission fact, not
		# a change list.
		blocked=$(field pending) || blocked=""
		case "$blocked" in
		*blocked*)
			add_area github blocked "$repo: $blocked"
			# Counts as unfinished, so it needs a step. The step is not a fix —
			# nothing short of the user getting admin changes it — but an area
			# that is pending with no next[] entry is a dead end to read.
			NEXT+=("bash $SIBLINGS_SHOWN/setup-github/setup-github.sh --status   # needs admin on $repo; ask an owner, or skip GitHub")
			;;
		*)
			add_area github unknown "could not read a pending count from setup-github"
			NEXT+=("read $SIBLINGS_SHOWN/setup-github/SKILL.md")
			;;
		esac
	elif [ "$n" = 0 ]; then
		add_area github converged "$repo"
	else
		add_area github pending "$repo: $n item(s)"
		NEXT+=("read $SIBLINGS_SHOWN/setup-github/SKILL.md   # shows the item table, then asks you to confirm")
	fi
fi

# --- report ----------------------------------------------------------------

printf 'bin: %s\n' "${SELF/#$HOME/\~}"
printf 'repo: %s\n' "$(basename "$REPO_ROOT")"

rows=()
pending_areas=0
for rec in ${AREAS[@]+"${AREAS[@]}"}; do
	IFS="$SEP" read -r area state detail <<<"$rec"
	rows+=("  $area,$state,\"$detail\"")
	case "$state" in
	converged | configured | skipped) ;;
	*) pending_areas=$((pending_areas + 1)) ;;
	esac
done
printf 'areas[%s]{area,state,detail}:\n' "${#rows[@]}"
printf '%s\n' "${rows[@]}"

if [ "$pending_areas" -eq 0 ]; then
	printf 'pending: 0 of %s areas — this repo is set up (no-op)\n' "${#rows[@]}"
	exit 0
fi

printf 'pending: %s of %s areas\n' "$pending_areas" "${#rows[@]}"
printf 'next[%s]:\n' "${#NEXT[@]}"
# Guarded like AREAS above: under bash 3.2 with `set -u`, expanding an empty
# array aborts rather than yielding nothing. Every terminal state now pushes a
# step, so this should not be empty — but the report must not be what discovers
# that it is.
printf '  %s\n' ${NEXT[@]+"${NEXT[@]}"}
printf 'help: the SKILL.md steps each ask you one question — follow them in the order above, then commit once\n'
exit 0
