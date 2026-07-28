#!/usr/bin/env bash
# shellcheck disable=SC2016 # backticks in help prose are literal markup, not substitution
# Report git state, commit dirty work via `wt step commit`, and name the next step.
#
# Output follows AXI conventions: structured key/value on stdout (errors included),
# progress on stderr, exit 0 for success and no-ops, 1 for errors, 2 for usage.
#
# Invoke with `bash commit.sh` — `npx skills` copies skill files without the
# executable bit, so a direct exec would fail.

set -uo pipefail

SELF=${BASH_SOURCE[0]}
MODE=commit
DO_PUSH=false

usage() {
	printf 'bin: %s\n' "${SELF/#$HOME/\~}"
	printf 'description: Commit the working tree with a generated message and name the next step\n'
	printf 'flags[4]{flag,effect}:\n'
	printf '  --status,"Report state only; never commits"\n'
	printf '  --dry-run,"Preview the generated message without committing"\n'
	printf '  --push,"After committing, run the pull request skill"\n'
	printf '  --help,"This text"\n'
}

for arg in "$@"; do
	case "$arg" in
	--status) MODE=status ;;
	--dry-run) MODE=dry-run ;;
	--push) DO_PUSH=true ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'error: unknown flag %s\n' "$arg"
		usage
		exit 2
		;;
	esac
done

if [ "$MODE" != commit ] && [ "$DO_PUSH" = true ]; then
	printf 'error: --push and --%s conflict\n' "$MODE"
	printf 'cause: --%s changes nothing, --push commits and opens a pull request\n' "$MODE"
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

# A linked worktree keeps its own git dir under <common>/worktrees/<name>; the
# main worktree's git dir *is* the common dir. Resolve both to absolute paths
# because `git rev-parse --git-dir` may answer relatively.
GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd)
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd)
IS_LINKED=false
[ -n "$GIT_DIR" ] && [ "$GIT_DIR" != "$GIT_COMMON" ] && IS_LINKED=true

# Name the repository, not the worktree directory — a linked worktree lives at
# a path like <repo>.<branch>, which would otherwise be reported as the repo.
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
	printf 'help: run `git switch <branch>` or `git switch -c <branch>` before committing\n'
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
	[ "$STATE" != default-branch ] && printf 'default: %s\n' "$DEFAULT"
	[ "$IS_LINKED" = true ] && printf 'worktree: %s\n' "${REPO_ROOT/#$HOME/\~}"
	return 0
}

# Upstream divergence, re-read on demand because committing changes it.
UPSTREAM=""
HAS_UPSTREAM=false
AHEAD=0
BEHIND=0

read_remote_state() {
	local counts
	UPSTREAM=""
	HAS_UPSTREAM=false
	AHEAD=0
	BEHIND=0
	if UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null); then
		HAS_UPSTREAM=true
		if counts=$(git rev-list --left-right --count "@{upstream}...HEAD" 2>/dev/null); then
			BEHIND=${counts%%[[:space:]]*}
			AHEAD=${counts##*[[:space:]]}
		fi
	fi
	return 0
}

print_remote() {
	if [ "$HAS_UPSTREAM" != true ]; then
		if [ -n "$REMOTE" ]; then
			printf 'remote: %s configured, branch has no upstream\n' "$REMOTE"
		else
			printf 'remote: none configured\n'
		fi
		return 0
	fi
	if [ "$AHEAD" -eq 0 ] && [ "$BEHIND" -eq 0 ]; then
		printf 'remote: %s in sync\n' "$UPSTREAM"
	elif [ "$BEHIND" -eq 0 ]; then
		printf 'remote: %s +%s ahead\n' "$UPSTREAM" "$AHEAD"
	elif [ "$AHEAD" -eq 0 ]; then
		printf 'remote: %s -%s behind\n' "$UPSTREAM" "$BEHIND"
	else
		printf 'remote: %s +%s ahead, -%s behind\n' "$UPSTREAM" "$AHEAD" "$BEHIND"
	fi
}

# Every suggestion must be runnable as printed — never suggest a bare `git push`
# for a branch that has no upstream to push to.
print_next() {
	if [ "$STATE" != default-branch ]; then
		printf 'next: Run /pr to open a pull request\n'
	elif [ "$HAS_UPSTREAM" = true ]; then
		if [ "$AHEAD" -gt 0 ]; then
			printf 'next: git push\n'
		elif [ "$BEHIND" -gt 0 ]; then
			printf 'next: git pull (nothing local to push)\n'
		else
			printf 'next: nothing to push, %s is up to date\n' "$UPSTREAM"
		fi
	elif [ -n "$REMOTE" ]; then
		printf 'next: git push -u %s %s\n' "$REMOTE" "$BRANCH"
	else
		printf 'next: nothing to push, no remote configured\n'
	fi
}

# `--push` hands off to the pull request skill, which names the destination
# instead. Resolved as a sibling, which holds under both the ~/.claude/skills
# symlink and the ~/.agents/skills directory it points at.
chain_push() {
	local dir sibling
	dir=$(cd "$(dirname "$SELF")/../pr" 2>/dev/null && pwd)
	sibling="$dir/pr.sh"
	if [ -z "$dir" ] || [ ! -f "$sibling" ]; then
		printf 'error: the pull request skill was not found beside this one\n'
		printf 'looked: %s\n' "$(dirname "${SELF/#$HOME/\~}")/../pr/pr.sh"
		printf 'cause: --push opens the pull request through it\n'
		printf 'help: run /pr\n'
		exit 1
	fi
	exec bash "$sibling"
}

# Strip ANSI escapes so captured tool output stays readable as plain text.
strip_ansi() {
	sed $'s/\033\\[[0-9;?]*[a-zA-Z]//g'
}

# --- read the working tree -------------------------------------------------

PORCELAIN=$(git status --porcelain 2>/dev/null)

read -r N_STAGED N_UNSTAGED N_UNTRACKED <<<"$(printf '%s\n' "$PORCELAIN" | awk '
	length($0) == 0 { next }
	{ x = substr($0, 1, 1); y = substr($0, 2, 1) }
	x == "?" { u++; next }
	x != " " { s++ }
	y != " " { m++ }
	END { printf "%d %d %d", s + 0, m + 0, u + 0 }
')"
N_FILES=$(printf '%s\n' "$PORCELAIN" | grep -c . || true)

print_pending() {
	printf 'pending: %s staged, %s unstaged, %s untracked\n' \
		"$N_STAGED" "$N_UNSTAGED" "$N_UNTRACKED"
	printf 'files[%s]{status,path}:\n' "$N_FILES"
	printf '%s\n' "$PORCELAIN" | head -10 | sed 's/^/  /'
	[ "$N_FILES" -gt 10 ] && printf '  ... and %s more\n' "$((N_FILES - 10))"
	return 0
}

# --- clean tree: nothing to do ---------------------------------------------

if [ -z "$PORCELAIN" ]; then
	print_state
	printf 'tree: clean, nothing to commit\n'
	read_remote_state
	print_remote
	# On a branch that already carries commits, --push still means ship them.
	[ "$DO_PUSH" = true ] && chain_push
	print_next
	exit 0
fi

# --- status mode: report only ----------------------------------------------

if [ "$MODE" = status ]; then
	print_state
	print_pending
	read_remote_state
	print_remote
	printf 'next: run this script with no flags to commit\n'
	exit 0
fi

# --- locate wt -------------------------------------------------------------

WT_BIN=${WORKTRUNK_BIN:-wt}
if ! WT_PATH=$(command -v "$WT_BIN" 2>/dev/null); then
	print_state
	print_pending
	printf 'error: `wt` not found on PATH\n'
	printf 'cause: worktrunk generates the commit message this skill relies on\n'
	printf 'help: install it with `brew install worktrunk` (https://worktrunk.dev)\n'
	printf 'fallback: write a Conventional Commits message and run `git commit` directly\n'
	exit 1
fi

# --- dry run: preview the message, commit nothing --------------------------

if [ "$MODE" = dry-run ]; then
	print_state
	print_pending
	DRY=$("$WT_PATH" step commit --dry-run 2>&1)
	DRY_RC=$?
	if [ "$DRY_RC" -ne 0 ]; then
		printf 'error: `wt step commit --dry-run` failed (exit %s)\n' "$DRY_RC"
		printf 'detail:\n'
		printf '%s\n' "$DRY" | strip_ansi | tail -12 | sed 's/^/  /'
		exit 1
	fi
	printf 'preview:\n'
	printf '%s\n' "$DRY" | strip_ansi | sed 's/^/  /'
	printf 'note: nothing was committed\n'
	exit 0
fi

# --- commit ----------------------------------------------------------------

HEAD_BEFORE=$(git rev-parse HEAD 2>/dev/null || printf '')

# No --yes: an unapproved project hook is the user's trust decision, not ours.
OUT=$("$WT_PATH" step commit 2>&1)
RC=$?

HEAD_AFTER=$(git rev-parse HEAD 2>/dev/null || printf '')

if [ "$RC" -ne 0 ] || [ "$HEAD_AFTER" = "$HEAD_BEFORE" ]; then
	CAUSE="wt reported no usable outcome; see detail"
	HELP="inspect the detail below and resolve the underlying failure"
	if grep -qi 'approval' <<<"$OUT"; then
		CAUSE="a project hook needs approval and wt cannot prompt non-interactively"
		HELP='run `wt config approvals add` to review and approve the commands yourself'
	elif grep -qiE 'pre-commit|hook .*failed' <<<"$OUT"; then
		CAUSE="a pre-commit hook failed"
		HELP="fix what the hook reported below, then run this script again"
	elif grep -qiE 'command not found|No such file|failed to (spawn|run)' <<<"$OUT"; then
		CAUSE="the configured [commit.generation] command could not run"
		HELP='check `wt config show` and confirm the generator CLI is installed'
	elif [ "$RC" -eq 0 ]; then
		CAUSE="wt exited cleanly but HEAD did not move"
		HELP="check whether the changes were excluded by .gitignore or a hook"
	fi

	print_state
	print_pending
	printf 'error: commit failed (exit %s)\n' "$RC"
	printf 'cause: %s\n' "$CAUSE"
	printf 'help: %s\n' "$HELP"
	printf 'fallback: write a Conventional Commits message and run `git commit` directly\n'
	printf 'detail:\n'
	printf '%s\n' "$OUT" | strip_ansi | grep -v '^[[:space:]]*$' | tail -12 | sed 's/^/  /'
	exit 1
fi

# --- report the commit, read back from git rather than parsing wt ----------

print_state
printf 'committed: %s\n' "$(git rev-parse --short HEAD)"
printf 'message: %s\n' "$(git log -1 --format=%s)"
[ -n "$(git log -1 --format=%b)" ] && printf 'body: present\n'
printf 'changes: %s\n' "$(git show --stat --format= HEAD | tail -1 | sed 's/^[[:space:]]*//')"

LEFTOVER=$(git status --porcelain 2>/dev/null)
if [ -n "$LEFTOVER" ]; then
	printf 'tree: %s file(s) still uncommitted\n' "$(printf '%s\n' "$LEFTOVER" | grep -c .)"
else
	printf 'tree: clean\n'
fi

read_remote_state
print_remote
[ "$DO_PUSH" = true ] && chain_push
print_next
exit 0
