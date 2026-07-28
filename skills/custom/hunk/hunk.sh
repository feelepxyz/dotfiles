#!/usr/bin/env bash
# shellcheck disable=SC2016 # backticks in help prose are literal markup, not substitution
# Resolve what to review, open it in Hunk, and report the live session.
#
# Output follows AXI conventions: structured key/value on stdout (errors included),
# progress on stderr, exit 0 for success and no-ops, 1 for errors, 2 for usage.
#
# Invoke with `bash hunk.sh` — `npx skills` copies skill files without the
# executable bit, so a direct exec would fail.

set -uo pipefail

SELF=${BASH_SOURCE[0]}
MODE=open
DRY_RUN=false

usage() {
	printf 'bin: %s\n' "${SELF/#$HOME/\~}"
	printf 'description: Open the working diff, last commit, or branch range in Hunk\n'
	printf 'args[3]{arg,effect}:\n'
	printf '  auto,"Report mode: auto so the caller reviews and comments inline"\n'
	printf '  --dry-run,"Print the resolved target and command; open nothing"\n'
	printf '  --help,"This text"\n'
}

# `auto` arrives bare from `/hunk auto`, so accept it with and without dashes.
for arg in "$@"; do
	case "$arg" in
	auto | --auto) MODE=auto ;;
	--dry-run) DRY_RUN=true ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'error: unknown argument %s\n' "$arg"
		printf 'help: valid arguments: auto, --dry-run, --help\n'
		exit 2
		;;
	esac
done

# --- locate the repository and the viewer ----------------------------------

if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || [ -z "$REPO_ROOT" ]; then
	printf 'error: not a git repository\n'
	printf 'cwd: %s\n' "${PWD/#$HOME/\~}"
	printf 'help: cd into a repository, or run `git init` to start one here\n'
	exit 2
fi

if ! HUNK=$(command -v hunk 2>/dev/null); then
	printf 'error: `hunk` not found on PATH\n'
	printf 'cause: this skill reviews changes in the Hunk terminal viewer\n'
	printf 'help: install it with `brew install hunk` (https://hunk.dev)\n'
	exit 1
fi

GIT_COMMON=$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd)
if [ -z "$GIT_COMMON" ]; then
	REPO=$(basename "$REPO_ROOT")
elif [ "$(basename "$GIT_COMMON")" = ".git" ]; then
	REPO=$(basename "$(dirname "$GIT_COMMON")")
else
	REPO=$(basename "${GIT_COMMON%.git}")
fi

# --- resolve the target ----------------------------------------------------

BRANCH=$(git branch --show-current 2>/dev/null)
PORCELAIN=$(git status --porcelain 2>/dev/null)

# `hunk diff` reads worktree-against-index, so staged-only work needs --staged
# to be visible at all. Count the three classes separately to tell them apart.
read -r N_STAGED N_UNSTAGED N_UNTRACKED <<<"$(printf '%s\n' "$PORCELAIN" | awk '
	length($0) == 0 { next }
	{ x = substr($0, 1, 1); y = substr($0, 2, 1) }
	x == "?" { u++; next }
	x != " " { s++ }
	y != " " { m++ }
	END { printf "%d %d %d", s + 0, m + 0, u + 0 }
')"

REMOTE=origin
git remote get-url origin >/dev/null 2>&1 || REMOTE=$(git remote 2>/dev/null | head -1)

DEFAULT=""
if [ -n "$REMOTE" ]; then
	DEFAULT=$(git symbolic-ref -q --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null)
	DEFAULT=${DEFAULT#"$REMOTE/"}
fi
if [ -z "$DEFAULT" ]; then
	for cand in main master trunk; do
		if git show-ref --verify --quiet "refs/heads/$cand"; then
			DEFAULT=$cand
			break
		fi
	done
fi

# Compare against the local default branch when it exists so the range still
# resolves offline; fall back to the remote-tracking ref in a fresh worktree.
BASE=""
if [ -n "$DEFAULT" ]; then
	if git show-ref --verify --quiet "refs/heads/$DEFAULT"; then
		BASE=$DEFAULT
	elif [ -n "$REMOTE" ] && git show-ref --verify --quiet "refs/remotes/$REMOTE/$DEFAULT"; then
		BASE="$REMOTE/$DEFAULT"
	fi
fi

NOTE=""
if [ "$N_UNSTAGED" -gt 0 ] || [ "$N_UNTRACKED" -gt 0 ]; then
	TARGET="working tree"
	ARGS=(diff)
	if [ "$N_STAGED" -gt 0 ]; then
		NOTE="$N_STAGED staged change(s) sit outside this view; reload with \`diff --staged\` to read them"
	fi
elif [ "$N_STAGED" -gt 0 ]; then
	TARGET="staged changes"
	ARGS=(diff --staged)
elif [ -z "$BRANCH" ]; then
	TARGET="last commit"
	ARGS=(show)
	NOTE="HEAD is detached, so there is no branch range to compare"
elif [ -n "$DEFAULT" ] && [ "$BRANCH" = "$DEFAULT" ]; then
	TARGET="last commit"
	ARGS=(show)
elif [ -z "$BASE" ]; then
	TARGET="last commit"
	ARGS=(show)
	NOTE="no default branch found to compare against"
else
	AHEAD=$(git rev-list --count "$BASE..HEAD" 2>/dev/null || printf 0)
	if [ "$AHEAD" -eq 0 ]; then
		TARGET="last commit"
		ARGS=(show)
		NOTE="$BRANCH adds no commits on top of $BASE"
	else
		TARGET="$BASE...HEAD"
		ARGS=(diff "$BASE...HEAD")
	fi
fi

# A reloaded session keeps the watch setting it launched with, and `session
# reload` takes no viewer flags — so --watch belongs only on a fresh launch.
LAUNCH=("${ARGS[@]}" --watch)
CMD="hunk"
for a in "${LAUNCH[@]}"; do CMD+=" $a"; done

# --- shared reporting ------------------------------------------------------

print_state() {
	printf 'repo: %s\n' "$REPO"
	[ -n "$BRANCH" ] && printf 'branch: %s\n' "$BRANCH"
	if [ -n "$PORCELAIN" ]; then
		printf 'tree: %s staged, %s unstaged, %s untracked\n' \
			"$N_STAGED" "$N_UNSTAGED" "$N_UNTRACKED"
	else
		printf 'tree: clean\n'
	fi
	printf 'target: %s\n' "$TARGET"
	[ -n "$NOTE" ] && printf 'note: %s\n' "$NOTE"
	printf 'mode: %s\n' "$MODE"
	printf 'command: %s\n' "$CMD"
	return 0
}

# Read one session id for this repo. `session list --json` carries the whole
# file tree, so pull the id out with jq rather than letting it reach a caller.
find_session() {
	[ -n "$JQ" ] || return 0
	"$HUNK" session list --json 2>/dev/null |
		"$JQ" -r --arg root "$REPO_ROOT" \
			'[.sessions[]? | select(.repoRoot == $root) | .sessionId] | first // empty' 2>/dev/null
}

JQ=$(command -v jq 2>/dev/null) || JQ=""

# --- dry run: resolve only -------------------------------------------------

if [ "$DRY_RUN" = true ]; then
	print_state
	printf 'action: none, --dry-run opened nothing\n'
	exit 0
fi

# --- reuse a live session, else open a Herdr tab, else hand it over --------

SESSION=$(find_session)

if [ -n "$SESSION" ]; then
	OUT=$("$HUNK" session reload "$SESSION" -- "${ARGS[@]}" 2>&1)
	RC=$?
	if [ "$RC" -ne 0 ]; then
		print_state
		printf 'error: could not reload the live Hunk session\n'
		printf 'cause: %s\n' "$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-200)"
		printf 'help: close the Hunk window and run this script again to open a fresh one\n'
		exit 1
	fi
	print_state
	printf 'action: reloaded the session already open for this repo\n'
	printf 'session: %s\n' "$SESSION"

elif [ "${HERDR_ENV:-}" = 1 ] && [ -n "$JQ" ]; then
	# Name the caller's workspace: omitting it targets whichever workspace the UI
	# has focused, which may belong to a different client.
	if [ -n "${HERDR_WORKSPACE_ID:-}" ]; then
		TAB=$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" \
			--cwd "$REPO_ROOT" --label hunk --focus 2>&1)
	else
		TAB=$(herdr tab create --cwd "$REPO_ROOT" --label hunk --focus 2>&1)
	fi
	PANE=$(printf '%s' "$TAB" | "$JQ" -r '.result.root_pane.pane_id // empty' 2>/dev/null)
	if [ -z "$PANE" ]; then
		print_state
		printf 'error: Herdr did not return a pane for the new tab\n'
		printf 'cause: %s\n' "$(printf '%s' "$TAB" | tr '\n' ' ' | cut -c1-200)"
		printf 'help: run `%s` in a terminal yourself\n' "$CMD"
		exit 1
	fi
	herdr pane run "$PANE" "$CMD" >/dev/null 2>&1

	# Wait for the daemon to register the session so the caller's first
	# `hunk session` command lands on a live target.
	for _ in $(seq 1 30); do
		SESSION=$(find_session)
		[ -n "$SESSION" ] && break
		sleep 0.2
	done

	print_state
	printf 'action: opened a focused Herdr tab\n'
	printf 'pane: %s\n' "$PANE"
	if [ -n "$SESSION" ]; then
		printf 'session: %s\n' "$SESSION"
	else
		printf 'session: not registered yet\n'
		printf 'help: re-run `hunk session list --json` in a moment\n'
	fi

else
	print_state
	if [ "${HERDR_ENV:-}" = 1 ]; then
		printf 'action: none, jq is missing so the Herdr tab could not be opened\n'
		printf 'help: install it with `brew install jq`\n'
	else
		printf 'action: none, not running inside Herdr\n'
	fi
	printf 'run: %s\n' "$CMD"
	printf 'next: ask the user to run that command, then drive the session it opens\n'
	exit 0
fi

# --- point at the branch the caller takes next -----------------------------

if [ "$MODE" = auto ]; then
	printf 'next: review this changeset and leave inline comments\n'
else
	printf 'next: the diff is on screen for the user; stop here\n'
fi
exit 0
