#!/usr/bin/env bash
# shellcheck disable=SC2016 # backticks in help prose are literal markup, not substitution
# Assess the repository and land on a branch worth working on: fetch, cut off
# the fresh default, carry uncommitted work across, or report the branch that is
# already here.
#
# The repository state decides what happens. The name is a proposal, consumed
# only when a fresh cut is needed — which is what makes passing one always safe.
#
# This is not `wta`. That builds a worktree and launches an agent in it; this
# works in place, in whatever clone or worktree the session already occupies.
#
# Output follows AXI conventions: structured key/value on stdout (errors
# included), progress on stderr, exit 0 for success and no-ops, 1 for errors,
# 2 for usage.
#
# Invoke with `bash branch.sh` — `npx skills` copies skill files without the
# executable bit, so a direct exec would fail.

set -uo pipefail

SELF=${BASH_SOURCE[0]}
MODE=run
NAME=""
DO_REBASE=false
FORCE_NEW=false
DO_PUSH=false
BASE_OVERRIDE=""

usage() {
	printf 'bin: %s\n' "${SELF/#$HOME/\~}"
	printf 'description: Assess the repository and land on a branch worth working on\n'
	printf 'usage: branch.sh [<name>] [flags]\n'
	printf 'arg: <name>,"Proposed branch name, consumed only when a fresh cut is needed"\n'
	printf 'flags[6]{flag,effect}:\n'
	printf '  --status,"Assess and report; changes nothing"\n'
	printf '  --rebase,"Replay a branch that is behind onto the fresh default"\n'
	printf '  --new,"Cut a fresh branch even when this one carries live work"\n'
	printf '  --push,"After landing, run the commit skill, which opens the pull request"\n'
	printf '  --base <branch>,"Cut from this branch instead of the repository default"\n'
	printf '  --help,"This text"\n'
}

# A flag that takes a value must not swallow the next flag as its argument.
need_value() {
	case ${2:-} in
	"" | --*)
		printf 'error: %s requires a value\n' "$1"
		usage
		exit 2
		;;
	esac
}

while [ $# -gt 0 ]; do
	case "$1" in
	--status) MODE=status ;;
	--rebase) DO_REBASE=true ;;
	--new) FORCE_NEW=true ;;
	--push) DO_PUSH=true ;;
	--base)
		need_value "$1" "${2:-}"
		BASE_OVERRIDE=$2
		shift
		;;
	--base=*) BASE_OVERRIDE=${1#--base=} ;;
	-h | --help)
		usage
		exit 0
		;;
	-*)
		printf 'error: unknown flag %s\n' "$1"
		usage
		exit 2
		;;
	*)
		if [ -n "$NAME" ]; then
			printf 'error: unexpected argument %s (name is already "%s")\n' "$1" "$NAME"
			printf 'help: branch.sh <name> [flags]\n'
			exit 2
		fi
		NAME=$1
		;;
	esac
	shift
done

if [ "$MODE" = status ] && [ "$DO_PUSH" = true ]; then
	printf 'error: --status and --push conflict\n'
	printf 'cause: --status changes nothing, --push commits and opens a pull request\n'
	printf 'help: pass one or the other\n'
	exit 2
fi

# --- locate the repository -------------------------------------------------

if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || [ -z "$REPO_ROOT" ]; then
	printf 'error: not a git repository\n'
	printf 'cwd: %s\n' "${PWD/#$HOME/\~}"
	printf 'help: cd into a repository, or run `git init` to start one here\n'
	exit 2
fi

# --- classify the worktree -------------------------------------------------
# Kept identical to the commit and pr skills so all three report the same
# `state:` values for the same repository.

GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd)
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd)
IS_LINKED=false
[ -n "$GIT_DIR" ] && [ "$GIT_DIR" != "$GIT_COMMON" ] && IS_LINKED=true

if [ -z "$GIT_COMMON" ]; then
	REPO=$(basename "$REPO_ROOT")
elif [ "$(basename "$GIT_COMMON")" = ".git" ]; then
	REPO=$(basename "$(dirname "$GIT_COMMON")")
else
	REPO=$(basename "${GIT_COMMON%.git}")
fi

BRANCH=$(git branch --show-current 2>/dev/null)
if [ -z "$BRANCH" ]; then
	printf 'error: HEAD is detached\n'
	printf 'repo: %s\n' "$REPO"
	printf 'commit: %s\n' "$(git rev-parse --short HEAD 2>/dev/null || printf unknown)"
	printf 'help: run `git switch <branch>` before cutting a new one\n'
	exit 2
fi

if ! HEAD_SHA=$(git rev-parse --verify -q HEAD 2>/dev/null) || [ -z "$HEAD_SHA" ]; then
	printf 'error: %s has no commits yet\n' "$BRANCH"
	printf 'repo: %s\n' "$REPO"
	printf 'cause: there is nothing to cut a branch from\n'
	printf 'help: make the first commit, then run this script again\n'
	exit 2
fi

# Primary remote: origin when present, otherwise whichever remote exists.
REMOTE=origin
git remote get-url origin >/dev/null 2>&1 || REMOTE=$(git remote 2>/dev/null | head -1)

DEFAULT=""
if [ -n "$REMOTE" ]; then
	DEFAULT=$(git symbolic-ref -q --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null)
	DEFAULT=${DEFAULT#"$REMOTE/"}
fi
# Remote-tracking refs before local heads: a clone whose `$REMOTE/HEAD` was
# never set still knows its default branch, and falling straight through to
# local heads would name whatever branch happens to be checked out.
if [ -z "$DEFAULT" ] && [ -n "$REMOTE" ]; then
	for cand in main master trunk; do
		if git show-ref --verify --quiet "refs/remotes/$REMOTE/$cand"; then
			DEFAULT=$cand
			break
		fi
	done
fi
if [ -z "$DEFAULT" ]; then
	for cand in main master trunk; do
		if git show-ref --verify --quiet "refs/heads/$cand"; then
			DEFAULT=$cand
			break
		fi
	done
fi
[ -z "$DEFAULT" ] && DEFAULT=$BRANCH

BASE=${BASE_OVERRIDE:-$DEFAULT}

if [ "$BRANCH" = "$DEFAULT" ]; then
	STATE=default-branch
elif [ "$IS_LINKED" = true ]; then
	STATE=worktree
else
	STATE=branch
fi

# --- shared reporting ------------------------------------------------------

print_state() {
	printf 'repo: %s\n' "$REPO"
	printf 'state: %s\n' "$STATE"
	printf 'branch: %s\n' "$BRANCH"
	printf 'base: %s\n' "$BASE"
	[ "$IS_LINKED" = true ] && printf 'worktree: %s\n' "${REPO_ROOT/#$HOME/\~}"
	return 0
}

# Strip ANSI escapes so captured tool output stays readable as plain text.
strip_ansi() {
	sed $'s/\033\\[[0-9;?]*[a-zA-Z]//g'
}

print_detail() {
	printf 'detail:\n'
	printf '%s\n' "$1" | strip_ansi | grep -v '^[[:space:]]*$' | tail -12 | sed 's/^/  /'
}

PORCELAIN=$(git status --porcelain 2>/dev/null)
N_DIRTY=$(printf '%s\n' "$PORCELAIN" | grep -c . || true)

print_changes() {
	if [ "$N_DIRTY" -eq 0 ]; then
		printf 'changes: none\n'
		return 0
	fi
	printf 'changes[%s]{status,path}:\n' "$N_DIRTY"
	printf '%s\n' "$PORCELAIN" | head -10 | sed 's/^/  /'
	[ "$N_DIRTY" -gt 10 ] && printf '  ... and %s more\n' "$((N_DIRTY - 10))"
	return 0
}

# --- fetch -----------------------------------------------------------------
# Being offline is not a reason to refuse to branch: a failed fetch degrades to
# a note and the run decides from whatever refs are already here.

FETCH_NOTE=""
if [ -n "$REMOTE" ]; then
	if ! git fetch --quiet "$REMOTE" \
		"+refs/heads/$BASE:refs/remotes/$REMOTE/$BASE" >/dev/null 2>&1; then
		FETCH_NOTE="failed, deciding from the refs already here"
	fi
else
	FETCH_NOTE="no remote configured, deciding from local refs"
fi

# --- resolve the cut point -------------------------------------------------
# Always the remote ref when there is one: a stale local default can never leak
# into a new branch.

if [ -n "$REMOTE" ] && git rev-parse --verify -q "refs/remotes/$REMOTE/$BASE" >/dev/null 2>&1; then
	CUT="$REMOTE/$BASE"
elif git rev-parse --verify -q "refs/heads/$BASE" >/dev/null 2>&1; then
	CUT="$BASE"
else
	print_state
	printf 'error: base branch %s not found\n' "$BASE"
	printf 'cause: neither %s/%s nor a local %s exists\n' "$REMOTE" "$BASE" "$BASE"
	printf 'help: pass --base <branch> naming one that does\n'
	[ -n "$FETCH_NOTE" ] && printf 'fetch: %s\n' "$FETCH_NOTE"
	exit 1
fi

CUT_SHA=$(git rev-parse "$CUT")
read -r BEHIND AHEAD <<<"$(git rev-list --left-right --count "$CUT...HEAD" 2>/dev/null || printf '0 0')"

ON_BASE=false
[ "$BRANCH" = "$BASE" ] && ON_BASE=true

print_position() {
	[ -n "$FETCH_NOTE" ] && printf 'fetch: %s\n' "$FETCH_NOTE"
	if [ "$ON_BASE" = false ]; then
		printf 'ahead: %s commit(s) %s lacks\n' "$AHEAD" "$CUT"
	fi
	[ "$BEHIND" -gt 0 ] && printf 'behind: %s commit(s) on %s\n' "$BEHIND" "$CUT"
	return 0
}

# --- has this branch already landed? ---------------------------------------
# Only worth asking when the branch is behind: a branch that already contains
# every commit on the base cannot have been merged into it.
#
# `wt merge` and `/pr` both squash, so `--is-ancestor` is the wrong probe — the
# landed commit has a different sha and an identical tree.

MERGED=""
detect_merged() {
	# The base cannot have landed into itself. Asking anyway reports the base as
	# merged whenever a local commit reappears upstream as someone else's squash,
	# and the `cleanup:` line below would then offer to delete it.
	[ "$ON_BASE" = false ] || return 0
	[ "$AHEAD" -gt 0 ] || return 0
	[ "$BEHIND" -gt 0 ] || return 0

	# The squash landed and nothing has moved past it yet: same tree, new sha.
	if git diff --quiet "$CUT" HEAD 2>/dev/null; then
		MERGED="its content is already on $CUT"
		return 0
	fi

	# The base has moved past the squash, so only the forge still knows.
	case "$CUT" in
	"$REMOTE/"*) ;;
	*) return 0 ;;
	esac
	command -v gh >/dev/null 2>&1 || return 0
	local url merged
	url=$(git config --get "remote.$REMOTE.url" 2>/dev/null)
	case "$url$(git remote get-url "$REMOTE" 2>/dev/null)" in
	*github.com*) ;;
	*) return 0 ;;
	esac
	merged=$(gh pr list --head "$BRANCH" --state merged --limit 1 \
		--json number --jq '.[0].number // empty' 2>/dev/null)
	[ -n "$merged" ] && MERGED="pull request #$merged is merged"
	return 0
}
detect_merged

# --- what would happen? ----------------------------------------------------
# One decision, made once, so --status and the run itself can never disagree.

PLAN=""
if [ "$ON_BASE" = true ] && [ "$AHEAD" -gt 0 ]; then
	# Ahead of --new deliberately. Both ways out of a base carrying unpushed
	# commits rewrite or publish history, so no flag here gets to pick one.
	PLAN=refuse-ahead
elif [ "$FORCE_NEW" = true ]; then
	PLAN=cut-fresh
elif [ "$ON_BASE" = true ]; then
	if [ "$DO_REBASE" = true ] && [ -z "$NAME" ] && [ "$BEHIND" -gt 0 ]; then
		# `--rebase` with no name, standing on the base, means bring the base up
		# to date and stay here. A name says cut instead — and the cut below
		# fast-forwards the base on its way past, so nothing is lost by it.
		PLAN=fast-forward
	else
		PLAN=cut-fresh
	fi
elif [ -n "$MERGED" ]; then
	PLAN=cut-fresh
elif [ "$AHEAD" -eq 0 ]; then
	if [ "$BEHIND" -gt 0 ]; then
		PLAN=fast-forward
	else
		PLAN=ready
	fi
elif [ "$BEHIND" -gt 0 ] && [ "$DO_REBASE" = true ]; then
	PLAN=rebase
else
	PLAN=ready
fi

# --- gate: the plan needs a name -------------------------------------------

if [ "$PLAN" = cut-fresh ] && [ -z "$NAME" ] && [ "$MODE" != status ]; then
	print_state
	print_position
	[ -n "$MERGED" ] && printf 'merged: %s — %s\n' "$BRANCH" "$MERGED"
	printf 'error: a branch name is required\n'
	printf 'cause: %s\n' "$(
		if [ "$ON_BASE" = true ]; then
			printf 'this is the base branch, so the work needs one of its own'
		else
			printf '%s has landed already, so the work needs a fresh branch' "$BRANCH"
		fi
	)"
	print_changes
	printf 'help: rerun as `branch.sh <name>` — kebab-case, from the work above\n'
	exit 2
fi

# --- is the proposed name free? --------------------------------------------
# Resolved before anything prints a command, so no suggestion can name a branch
# that already exists.

NAME_TAKEN=false
HOLDER=""
if [ -n "$NAME" ] && git show-ref --verify --quiet "refs/heads/$NAME"; then
	NAME_TAKEN=true
	HOLDER=$(git worktree list --porcelain 2>/dev/null | awk -v want="refs/heads/$NAME" '
		$1 == "worktree" { path = substr($0, 10) }
		$1 == "branch" && $2 == want { print path; exit }
	')
fi

CUT_NAME=${NAME:-<name>}
[ "$NAME_TAKEN" = true ] && CUT_NAME='<name>'

# --- gate: the local base carries unpushed commits -------------------------
# Carrying them onto the branch or publishing them on the base is the user's
# call, and either choice is hard to walk back.

print_ahead_options() {
	printf 'cause: cutting a branch now either duplicates them onto it or strands them here\n'
	printf 'option[2]{command,effect}:\n'
	printf '  git switch -c %s && git branch -f %s %s,"carry them onto the branch, reset %s"\n' \
		"$CUT_NAME" "$BRANCH" "$CUT" "$BRANCH"
	printf '  git push,"publish them on %s first, then rerun"\n' "$BRANCH"
	return 0
}

if [ "$PLAN" = refuse-ahead ] && [ "$MODE" != status ]; then
	print_state
	print_position
	printf 'error: local %s carries %s commit(s) %s lacks\n' "$BRANCH" "$AHEAD" "$CUT"
	print_ahead_options
	printf 'help: ask which the user wants — this script will not choose for them\n'
	exit 1
fi

# --- gate: the name is already taken ---------------------------------------

if [ "$NAME_TAKEN" = true ] && [ "$PLAN" = cut-fresh ] && [ "$MODE" != status ]; then
	print_state
	print_position
	printf 'error: branch %s already exists\n' "$NAME"
	printf 'at: %s\n' "$(git rev-parse --short "$NAME")"
	[ -n "$HOLDER" ] && printf 'worktree: %s holds it\n' "${HOLDER/#$HOME/\~}"
	if [ -n "$HOLDER" ]; then
		printf 'help: run `wt switch %s` to work there, or pass a different name\n' "$NAME"
	else
		printf 'help: run `git switch %s` to work there, or pass a different name\n' "$NAME"
	fi
	exit 1
fi

# --- status mode: report the plan, change nothing --------------------------
# Every refusal a run would raise is reported here as a plan instead, so the one
# mode built to assess is never the one that cannot describe what it found.

if [ "$MODE" = status ]; then
	print_state
	print_position
	[ -n "$MERGED" ] && printf 'merged: %s — %s\n' "$BRANCH" "$MERGED"
	print_changes
	case "$PLAN" in
	cut-fresh)
		printf 'plan: cut %s off %s (%s)\n' "$CUT_NAME" "$CUT" "$(git rev-parse --short "$CUT")"
		[ "$NAME_TAKEN" = true ] &&
			printf 'note: %s already exists, so the cut needs a different name\n' "$NAME"
		[ "$N_DIRTY" -gt 0 ] && [ "$HEAD_SHA" != "$CUT_SHA" ] &&
			printf 'plan: stash the changes across the switch, then pop them\n'
		;;
	refuse-ahead)
		printf 'plan: nothing — local %s carries %s commit(s) %s lacks\n' "$BRANCH" "$AHEAD" "$CUT"
		print_ahead_options
		printf 'help: a run refuses this and asks which option the user wants\n'
		;;
	fast-forward)
		printf 'plan: fast-forward %s to %s (+%s)\n' "$BRANCH" "$CUT" "$BEHIND"
		;;
	rebase)
		printf 'plan: rebase %s onto %s\n' "$BRANCH" "$CUT"
		;;
	ready)
		printf 'plan: nothing — %s is already a branch worth working on\n' "$BRANCH"
		;;
	esac
	printf 'note: nothing was changed\n'
	exit 0
fi

# --- carrying uncommitted work ---------------------------------------------

STASHED=false

# Stash only when the checkout will actually move the tree. When it will not,
# git carries the changes across itself and the stash is pure risk.
stash_if_needed() {
	[ "$N_DIRTY" -gt 0 ] || return 0
	[ "$HEAD_SHA" != "$CUT_SHA" ] || return 0
	local out
	if ! out=$(git stash push --include-untracked --message "branch: ${NAME:-$BRANCH}" 2>&1); then
		print_state
		print_position
		printf 'error: could not stash the uncommitted changes\n'
		printf 'cause: the switch would move the tree, so they have to travel in a stash\n'
		printf 'help: resolve what git reports below, or commit them with /commit first\n'
		print_detail "$out"
		exit 1
	fi
	STASHED=true
	return 0
}

# Returns 1 on a conflicting pop, having reported it. The stash entry survives.
pop_stash() {
	[ "$STASHED" = true ] || return 0
	local out
	if out=$(git stash pop 2>&1); then
		STASHED=false
		printf 'changes: %s file(s) carried across\n' "$N_DIRTY"
		return 0
	fi
	printf 'stash: kept — the carried changes did not apply cleanly\n'
	printf 'error: the stashed changes conflict with %s\n' "$CUT"
	printf 'cause: a file changed here was also changed on %s\n' "$CUT"
	printf 'help: resolve the conflicts, then `git stash drop` to discard the entry\n'
	printf 'help: or `git checkout -- . && git stash pop` to start the pop over\n'
	print_detail "$out"
	return 1
}

# --- the destination -------------------------------------------------------

# Every suggestion must be runnable as printed, and only the last script in a
# --push chain names a destination.
print_next() {
	if [ "$N_DIRTY" -gt 0 ]; then
		printf 'next: Run /commit to commit the carried changes\n'
	elif [ "$AHEAD_NOW" -gt 0 ]; then
		printf 'next: Run /pr to open a pull request\n'
	else
		printf 'next: make the change, then run /commit\n'
	fi
	return 0
}

# `--push` hands off to the commit skill, which hands off to the pull request
# skill. Resolved as a sibling, which holds under both the ~/.claude/skills
# symlink and the ~/.agents/skills directory it points at.
chain_push() {
	local dir sibling
	dir=$(cd "$(dirname "$SELF")/../commit" 2>/dev/null && pwd)
	sibling="$dir/commit.sh"
	if [ -z "$dir" ] || [ ! -f "$sibling" ]; then
		printf 'error: the commit skill was not found beside this one\n'
		printf 'looked: %s\n' "$(dirname "${SELF/#$HOME/\~}")/../commit/commit.sh"
		printf 'cause: --push runs the commit skill, which opens the pull request\n'
		printf 'help: run /commit, then /pr\n'
		exit 1
	fi
	exec bash "$sibling" --push
}

# --- act -------------------------------------------------------------------

print_state
print_position

case "$PLAN" in
cut-fresh)
	[ -n "$MERGED" ] && printf 'merged: %s — %s\n' "$BRANCH" "$MERGED"
	stash_if_needed

	# Fast-forward the base while still standing on it, so the branch left
	# behind is current too and the next cut starts from the right place.
	if [ "$ON_BASE" = true ] && [ "$BEHIND" -gt 0 ]; then
		if FF=$(git merge --ff-only "$CUT" 2>&1); then
			printf 'updated: %s fast-forwarded to %s (+%s)\n' "$BRANCH" "$CUT" "$BEHIND"
		else
			printf 'note: %s could not be fast-forwarded; cutting from %s anyway\n' "$BRANCH" "$CUT"
		fi
	fi

	if ! SW=$(git switch -c "$NAME" "$CUT" 2>&1); then
		printf 'error: could not create %s off %s\n' "$NAME" "$CUT"
		printf 'cause: git refused the switch\n'
		printf 'help: resolve what git reports below, then run this script again\n'
		[ "$STASHED" = true ] &&
			printf 'stash: held — run `git stash pop` to bring the changes back\n'
		print_detail "$SW"
		exit 1
	fi
	printf 'branched: %s off %s (%s)\n' "$NAME" "$CUT" "$(git rev-parse --short HEAD)"
	[ -n "$MERGED" ] && printf 'cleanup: git branch -D %s\n' "$BRANCH"
	pop_stash || exit 1
	BRANCH=$NAME
	;;

fast-forward)
	stash_if_needed
	if ! FF=$(git merge --ff-only "$CUT" 2>&1); then
		printf 'error: could not fast-forward %s to %s\n' "$BRANCH" "$CUT"
		printf 'cause: git refused the fast-forward\n'
		printf 'help: resolve what git reports below, then run this script again\n'
		[ "$STASHED" = true ] &&
			printf 'stash: held — run `git stash pop` to bring the changes back\n'
		print_detail "$FF"
		exit 1
	fi
	printf 'updated: %s fast-forwarded to %s (+%s)\n' "$BRANCH" "$CUT" "$BEHIND"
	[ "$ON_BASE" = false ] &&
		printf 'note: it carried no commits of its own, so the name is kept\n'
	pop_stash || exit 1
	;;

rebase)
	stash_if_needed
	if ! RB=$(git rebase "$CUT" 2>&1); then
		printf 'error: rebase onto %s failed\n' "$CUT"
		if [ -d "$GIT_DIR/rebase-merge" ] || [ -d "$GIT_DIR/rebase-apply" ]; then
			printf 'cause: the rebase hit a conflict and is still open here\n'
			printf 'help: resolve the conflicts and run `git rebase --continue`, or `git rebase --abort` to back out\n'
		else
			printf 'cause: git could not replay %s onto %s\n' "$BRANCH" "$CUT"
			printf 'help: resolve what git reports below, then run this script again\n'
		fi
		[ "$STASHED" = true ] &&
			printf 'stash: held — run `git stash pop` once the rebase settles\n'
		print_detail "$RB"
		exit 1
	fi
	printf 'rebased: %s onto %s\n' "$BRANCH" "$CUT"
	pop_stash || exit 1
	;;

ready)
	if [ "$AHEAD" -gt 0 ] && [ "$BEHIND" -gt 0 ]; then
		printf 'ready: %s carries unmerged work; nothing was changed\n' "$BRANCH"
		printf 'note: /pr rebases onto %s when it ships, or run /branch rebase now\n' "$BASE"
	elif [ "$AHEAD" -gt 0 ]; then
		printf 'ready: %s is a branch worth working on, %s commit(s) in\n' "$BRANCH" "$AHEAD"
	else
		printf 'ready: %s is level with %s\n' "$BRANCH" "$CUT"
	fi
	[ -n "$NAME" ] && [ "$NAME" != "$BRANCH" ] &&
		printf 'note: %s was not created — the branch here is already good\n' "$NAME"
	;;
esac

AHEAD_NOW=$(git rev-list --count "$CUT..HEAD" 2>/dev/null || printf 0)
N_DIRTY=$(git status --porcelain 2>/dev/null | grep -c . || true)

[ "$DO_PUSH" = true ] && chain_push
print_next
exit 0
