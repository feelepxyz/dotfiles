#!/usr/bin/env bash
# shellcheck disable=SC2016 # backticks in help prose are literal markup, not substitution
# Take a committed branch to an open pull request: worktrunk's merge pipeline
# with the landing swapped for a PR. The worktree stays — CI has not spoken yet,
# and a red run needs the checkout it is about.
#
# `wt merge` cannot serve this flow. It fast-forwards the target branch, which
# parks unmerged work on the local default branch until the PR lands, so the
# next branch cut from it inherits the previous feature. Its steps are run
# individually here instead, and the merge step is replaced by push + gh.
#
# `--merge` is the other half: it lands the request on GitHub, and only then
# removes the worktree, deletes the branch, and catches the local default branch
# up. Cleanup belongs to the merge, not to opening the request.
#
# Output follows AXI conventions: structured key/value on stdout (errors
# included), progress on stderr, exit 0 for success and no-ops, 1 for errors,
# 2 for usage.
#
# Invoke with `bash pr.sh` — `npx skills` copies skill files without the
# executable bit, so a direct exec would fail.

set -uo pipefail

SELF=${BASH_SOURCE[0]}
SELF_DIR=$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)
MODE=run
MERGE=false
WATCH=true
DO_SQUASH=true
DO_REBASE=true
DRAFT=false
TITLE=""
BODY=""
BASE_OVERRIDE=""

usage() {
	printf 'bin: %s\n' "${SELF/#$HOME/\~}"
	printf 'description: Squash, rebase, run hooks, push, and open a pull request; --merge lands it\n'
	printf 'flags[11]{flag,effect}:\n'
	printf '  --merge,"Land the open request: squash-merge, remove the worktree, delete the branch"\n'
	printf '  --status,"Report state and the planned steps; changes nothing"\n'
	printf '  --dry-run,"Print the commands that would run; changes nothing"\n'
	printf '  --no-watch,"Do not print a checks command to watch after the PR opens"\n'
	printf '  --no-squash,"Leave the individual commits alone"\n'
	printf '  --no-rebase,"Skip the rebase onto the default branch"\n'
	printf '  --draft,"Open the pull request as a draft"\n'
	printf '  --title <text>,"Pull request title (default: filled from commits)"\n'
	printf '  --body <text>,"Pull request body (default: filled from commits)"\n'
	printf '  --base <branch>,"Target branch (default: the repository default)"\n'
	printf '  --help,"This text"\n'
	printf 'note: opening a request keeps the worktree — only --merge removes it\n'
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
	--dry-run) MODE=dry-run ;;
	--merge) MERGE=true ;;
	--no-watch) WATCH=false ;;
	--no-squash) DO_SQUASH=false ;;
	--no-rebase) DO_REBASE=false ;;
	--draft) DRAFT=true ;;
	--title)
		need_value "$1" "${2:-}"
		TITLE=$2
		shift
		;;
	--title=*) TITLE=${1#--title=} ;;
	--body)
		need_value "$1" "${2:-}"
		BODY=$2
		shift
		;;
	--body=*) BODY=${1#--body=} ;;
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
	*)
		printf 'error: unknown flag %s\n' "$1"
		usage
		exit 2
		;;
	esac
	shift
done

# --- locate the repository -------------------------------------------------

if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || [ -z "$REPO_ROOT" ]; then
	printf 'error: not a git repository\n'
	printf 'cwd: %s\n' "${PWD/#$HOME/\~}"
	printf 'help: cd into a repository, or run `git init` to start one here\n'
	exit 2
fi

# --- classify the worktree -------------------------------------------------
# Kept identical to the commit skill so both report the same `state:` values.

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

# The main worktree, resolved before anything can remove the one we stand in.
MAIN_WORKTREE=$(git worktree list --porcelain 2>/dev/null |
	awk '/^worktree /{print substr($0, 10); exit}')
[ -z "$MAIN_WORKTREE" ] && MAIN_WORKTREE=$REPO_ROOT

BRANCH=$(git branch --show-current 2>/dev/null)
if [ -z "$BRANCH" ]; then
	printf 'error: HEAD is detached\n'
	printf 'repo: %s\n' "$REPO"
	printf 'commit: %s\n' "$(git rev-parse --short HEAD 2>/dev/null || printf unknown)"
	printf 'help: run `git switch <branch>` before opening a pull request\n'
	exit 2
fi

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
	[ "$STATE" != default-branch ] && printf 'base: %s\n' "$BASE"
	[ "$IS_LINKED" = true ] && printf 'worktree: %s\n' "${REPO_ROOT/#$HOME/\~}"
	return 0
}

# Strip ANSI escapes so captured tool output stays readable as plain text.
strip_ansi() {
	sed $'s/\033\\[[0-9;?]*[a-zA-Z]//g'
}

# Render a remote URL as the https form a browser can open. git accepts
# scp-style (git@host:owner/repo) and ssh:// remotes, but a compare link printed
# as a fallback has to be a URL the user can actually click. Only remotes that
# already passed the github.com gate above reach this.
web_url() {
	local u=${1%.git} host path
	case "$u" in
	https://* | http://*)
		# Already a URL; only a user@ in the authority needs dropping.
		host=${u#*://}
		path=${host#*/}
		host=${host%%/*}
		case "$host" in *@*) host=${host#*@} ;; esac
		printf 'https://%s/%s' "$host" "$path"
		return 0
		;;
	ssh://*) u=${u#ssh://} ;;
	esac
	# scp-style is host:path; an ssh:// remainder is host/path. Split on whichever
	# separator comes first so a path cannot be mistaken for a host.
	case "$u" in
	*:*) host=${u%%:*} path=${u#*:} ;;
	*) host=${u%%/*} path=${u#*/} ;;
	esac
	case "$host" in *@*) host=${host#*@} ;; esac
	printf 'https://%s/%s' "$host" "${path#/}"
}

print_detail() {
	printf 'detail:\n'
	printf '%s\n' "$1" | strip_ansi | grep -v '^[[:space:]]*$' | tail -12 | sed 's/^/  /'
}

PORCELAIN=$(git status --porcelain 2>/dev/null)
N_DIRTY=$(printf '%s\n' "$PORCELAIN" | grep -c . || true)

# Commits this branch carries that the base does not.
count_ahead() {
	git rev-list --count "$BASE..HEAD" 2>/dev/null || printf 0
}
AHEAD=$(count_ahead)

# --- gate: default branch --------------------------------------------------
# Only opening a request needs a branch of its own. `--merge` lands whatever
# request is already open, and the "no open request" gate below covers the rest.

if [ "$STATE" = default-branch ] && [ "$MERGE" = false ]; then
	print_state
	if [ "$N_DIRTY" -gt 0 ]; then
		printf 'tree: %s file(s) uncommitted\n' "$N_DIRTY"
	else
		printf 'tree: clean\n'
	fi
	printf 'error: refusing to open a pull request from the default branch\n'
	printf 'cause: a pull request needs a branch other than %s to merge from\n' "$DEFAULT"
	printf 'option[2]{command,effect}:\n'
	printf '  git switch -c <name>,"carry the current changes onto a new branch, then rerun"\n'
	printf '  git push,"publish %s directly, with no review"\n' "$DEFAULT"
	printf 'help: ask which the user wants — this script will not choose for them\n'
	exit 1
fi

# --- gate: dirty tree ------------------------------------------------------

if [ "$N_DIRTY" -gt 0 ]; then
	print_state
	printf 'tree: %s file(s) uncommitted\n' "$N_DIRTY"
	printf 'files[%s]{status,path}:\n' "$N_DIRTY"
	printf '%s\n' "$PORCELAIN" | head -10 | sed 's/^/  /'
	[ "$N_DIRTY" -gt 10 ] && printf '  ... and %s more\n' "$((N_DIRTY - 10))"
	printf 'error: the working tree has uncommitted changes\n'
	if [ "$MERGE" = true ]; then
		printf 'cause: merging removes this worktree, and these changes would go with it\n'
	else
		printf 'cause: a pull request can only carry what is committed\n'
	fi
	printf 'help: run /commit to commit them, then run this script again\n'
	exit 1
fi

# --- locate the tools ------------------------------------------------------

WT_BIN=${WORKTRUNK_BIN:-wt}
if ! WT_PATH=$(command -v "$WT_BIN" 2>/dev/null); then
	print_state
	printf 'error: `wt` not found on PATH\n'
	printf 'cause: worktrunk runs the squash, rebase, and hook steps this skill relies on\n'
	printf 'help: install it with `brew install worktrunk` (https://worktrunk.dev)\n'
	printf 'fallback: run `git push -u %s %s` and open the pull request yourself\n' "$REMOTE" "$BRANCH"
	exit 1
fi

if ! GH_PATH=$(command -v gh 2>/dev/null); then
	print_state
	printf 'error: `gh` not found on PATH\n'
	printf 'cause: the GitHub CLI opens the pull request\n'
	printf 'help: install it with `brew install gh`\n'
	printf 'fallback: run `git push -u %s %s` and open the pull request in the browser\n' "$REMOTE" "$BRANCH"
	exit 1
fi

if [ -z "$REMOTE" ]; then
	print_state
	printf 'error: no remote configured\n'
	printf 'cause: a pull request needs a branch published to GitHub\n'
	printf 'help: run `git remote add origin <url>`\n'
	exit 1
fi

# Read both the configured value and the resolved one: `git remote get-url`
# applies any url.<base>.insteadOf rewrite, and either side may be the GitHub
# form depending on which direction the user rewrites.
REMOTE_URL=$(git config --get "remote.$REMOTE.url" 2>/dev/null)
REMOTE_URL_RESOLVED=$(git remote get-url "$REMOTE" 2>/dev/null)
[ -z "$REMOTE_URL" ] && REMOTE_URL=$REMOTE_URL_RESOLVED
# Either side may be the GitHub one, and only that side can build a compare link.
COMPARE_SRC=$REMOTE_URL
case "$REMOTE_URL" in
*github.com*) ;;
*) COMPARE_SRC=$REMOTE_URL_RESOLVED ;;
esac

case "$REMOTE_URL $REMOTE_URL_RESOLVED" in
*github.com*) ;;
*)
	print_state
	printf 'error: remote %s is not on GitHub\n' "$REMOTE"
	printf 'url: %s\n' "$REMOTE_URL"
	printf 'cause: `gh` only opens pull requests against GitHub\n'
	printf 'help: open the request through whatever forge hosts this remote\n'
	exit 1
	;;
esac

if ! AUTH=$("$GH_PATH" auth status 2>&1); then
	print_state
	printf 'error: `gh` is not authenticated\n'
	printf 'cause: opening a pull request needs a GitHub login\n'
	printf 'help: run `gh auth login`\n'
	print_detail "$AUTH"
	exit 1
fi

# --- is a pull request already open? ---------------------------------------

PR_OPEN=$("$GH_PATH" pr list --head "$BRANCH" --state open \
	--json url,number --jq '.[0] // empty | "\(.url)\t\(.number)"' 2>/dev/null)
PR_URL=${PR_OPEN%%$'\t'*}
PR_NUM=${PR_OPEN##*$'\t'}

# --- mode: land the request ------------------------------------------------
# Cleanup lives here, not at the moment the request opens: until it merges, the
# worktree is where a red run gets investigated.

if [ "$MERGE" = true ]; then
	print_state
	if [ -z "$PR_URL" ]; then
		printf 'error: no open pull request for %s\n' "$BRANCH"
		printf 'cause: --merge lands a request that is already open; this branch has none\n'
		printf 'help: run `bash %s` without --merge to open one\n' "${SELF/#$HOME/\~}"
		exit 1
	fi
	printf 'pr: %s\n' "$PR_URL"
	printf 'pr_number: %s\n' "$PR_NUM"

	if [ "$IS_LINKED" = true ]; then
		REMOVE_DESC="wt remove --foreground -D $BRANCH"
	else
		REMOVE_DESC="git switch $DEFAULT && git branch -D $BRANCH"
	fi

	if [ "$MODE" = status ] || [ "$MODE" = dry-run ]; then
		printf 'plan[4]:\n'
		printf '  gh pr merge %s --squash\n' "$PR_URL"
		printf '  %s\n' "$REMOVE_DESC"
		printf '  git fetch --prune && git merge --ff-only %s/%s\n' "$REMOTE" "$DEFAULT"
		printf '  git push %s --delete %s   # only if the repository kept it\n' "$REMOTE" "$BRANCH"
		printf 'note: nothing was changed\n'
		exit 0
	fi

	MERGED=$("$GH_PATH" pr merge "$PR_URL" --squash 2>&1)
	MERGED_RC=$?
	if [ "$MERGED_RC" -ne 0 ]; then
		printf 'error: `gh pr merge --squash` failed\n'
		if grep -qiE 'not mergeable|conflict' <<<"$MERGED"; then
			printf 'cause: GitHub will not merge the request as it stands\n'
			printf 'help: rebase the branch onto %s and push again, then rerun\n' "$BASE"
		elif grep -qiE 'required|check|review|protected' <<<"$MERGED"; then
			printf 'cause: a branch protection rule is not satisfied yet\n'
			printf 'help: wait for the checks or reviews it names below, then rerun\n'
		else
			printf 'cause: the request is still open and nothing was removed\n'
			printf 'help: resolve what gh reports below, then run this script again\n'
		fi
		printf 'removed: nothing\n'
		print_detail "$MERGED"
		exit 1
	fi
	printf 'merged: %s squashed into %s\n' "$PR_URL" "$BASE"

	# The squash rewrites the commit, so the branch tip is not an ancestor of
	# the base and a safe delete would refuse: -D is the only option that works.
	#
	# Step out of the worktree in *this* process first, so the steps below still
	# have a working directory once it is gone.
	#
	# No --reap. It kills every process whose working directory is under the
	# worktree, and whoever ran this script is standing in exactly that place —
	# measured, it takes the calling shell down mid-run, so the output below
	# never reaches the caller even though the work completes. Dev servers the
	# worktree started outlive it; `wt remove --reap` is there to run by hand.
	if [ "$IS_LINKED" = true ]; then
		if ! cd "$MAIN_WORKTREE"; then
			printf 'removed: no — could not leave the worktree first\n'
			printf 'help: the request is merged; run `wt remove -D %s` from %s\n' \
				"$BRANCH" "${MAIN_WORKTREE/#$HOME/\~}"
			exit 1
		fi
		RM=$("$WT_PATH" remove --foreground -D "$BRANCH" 2>&1)
		RM_RC=$?
		if [ "$RM_RC" -ne 0 ]; then
			printf 'removed: no — worktree cleanup failed\n'
			printf 'help: the request is merged; remove the worktree yourself with `wt remove -D %s`\n' "$BRANCH"
			print_detail "$RM"
		else
			printf 'removed: worktree %s and branch %s\n' "${REPO_ROOT/#$HOME/\~}" "$BRANCH"
		fi
	else
		SW=$(git switch "$DEFAULT" 2>&1 && git branch -D "$BRANCH" 2>&1)
		SW_RC=$?
		if [ "$SW_RC" -ne 0 ]; then
			printf 'removed: no — branch %s is still here\n' "$BRANCH"
			printf 'help: run `git switch %s && git branch -D %s`\n' "$DEFAULT" "$BRANCH"
			print_detail "$SW"
		else
			printf 'removed: branch %s\n' "$BRANCH"
		fi
	fi

	# Catch the local default branch up — the objection to `wt merge` was that it
	# does this *before* the request lands, not that it does it at all.
	git -C "$MAIN_WORKTREE" fetch --prune "$REMOTE" >/dev/null 2>&1
	MAIN_HEAD=$(git -C "$MAIN_WORKTREE" branch --show-current 2>/dev/null)
	if [ "$MAIN_HEAD" = "$DEFAULT" ]; then
		if FF=$(git -C "$MAIN_WORKTREE" merge --ff-only "$REMOTE/$DEFAULT" 2>&1); then
			printf 'default: %s fast-forwarded to %s/%s\n' "$DEFAULT" "$REMOTE" "$DEFAULT"
		else
			printf 'default: %s left alone — it would not fast-forward\n' "$DEFAULT"
			print_detail "$FF"
		fi
	else
		printf 'default: %s left alone — the main worktree is on %s\n' "$DEFAULT" "$MAIN_HEAD"
	fi

	# Most repositories delete the head branch on merge; some do not. -C, like
	# every git call after the removal: the directory this script was launched
	# from is gone, so nothing here may depend on where it started.
	if git -C "$MAIN_WORKTREE" ls-remote --exit-code --heads "$REMOTE" "$BRANCH" >/dev/null 2>&1; then
		if git -C "$MAIN_WORKTREE" push "$REMOTE" --delete "$BRANCH" >/dev/null 2>&1; then
			printf 'remote: deleted %s/%s\n' "$REMOTE" "$BRANCH"
		else
			printf 'remote: %s/%s still there — delete it on GitHub\n' "$REMOTE" "$BRANCH"
		fi
	else
		printf 'remote: %s/%s already gone\n' "$REMOTE" "$BRANCH"
	fi

	printf 'cwd: %s\n' "${MAIN_WORKTREE/#$HOME/\~}"
	printf 'next: cd %s before running anything else — this directory is gone\n' \
		"${MAIN_WORKTREE/#$HOME/\~}"
	exit 0
fi

# --- gate: nothing to open -------------------------------------------------

if [ "$AHEAD" -eq 0 ] && [ -z "$PR_URL" ]; then
	print_state
	printf 'tree: clean\n'
	printf 'pr: nothing to open, %s carries no commits that %s lacks\n' "$BRANCH" "$BASE"
	printf 'next: commit some work, or switch to a branch that has some\n'
	exit 0
fi

# --- decide the plan -------------------------------------------------------

PLAN_SQUASH=false
[ "$DO_SQUASH" = true ] && [ "$AHEAD" -gt 1 ] && PLAN_SQUASH=true

PLAN_REBASE=false
if [ "$DO_REBASE" = true ] && ! git merge-base --is-ancestor "$BASE" HEAD 2>/dev/null; then
	PLAN_REBASE=true
fi

UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)

# The command that watches the checks the push is about to start. It is printed,
# never run: backgrounding belongs to the caller, and a child of this script
# would die with it and notify no one.
print_watch() {
	if [ "$WATCH" = false ]; then
		printf 'watch: skipped\n'
	elif [ -n "$1" ]; then
		printf 'watch: bash %s/checks.sh %s\n' "${SELF_DIR/#$HOME/\~}" "$1"
	else
		printf 'watch: bash %s/checks.sh <pr-url>\n' "${SELF_DIR/#$HOME/\~}"
	fi
	return 0
}

print_plan() {
	printf 'ahead: %s commit(s) on %s\n' "$AHEAD" "$BASE"
	if [ -n "$PR_URL" ]; then
		printf 'pr: %s (already open)\n' "$PR_URL"
		printf 'pr_number: %s\n' "$PR_NUM"
	fi
	printf 'plan[%s]:\n' 5
	if [ "$PLAN_SQUASH" = true ]; then
		printf '  wt step squash %s   # %s commits -> 1, runs pre-commit hooks\n' "$BASE" "$AHEAD"
	else
		printf '  wt hook pre-commit   # squash skipped, hooks still run\n'
	fi
	if [ "$PLAN_REBASE" = true ]; then
		printf '  wt step rebase %s\n' "$BASE"
	else
		printf '  (rebase skipped, already on top of %s)\n' "$BASE"
	fi
	printf '  wt hook pre-merge\n'
	if [ -n "$UPSTREAM" ] && { [ "$PLAN_SQUASH" = true ] || [ "$PLAN_REBASE" = true ]; }; then
		printf '  git push --force-with-lease\n'
	elif [ -n "$UPSTREAM" ]; then
		printf '  git push\n'
	else
		printf '  git push -u %s %s\n' "$REMOTE" "$BRANCH"
	fi
	if [ -n "$PR_URL" ]; then
		printf '  (pull request already open, none created)\n'
	else
		printf '  gh pr create --base %s --head %s\n' "$BASE" "$BRANCH"
	fi
	print_watch "$PR_URL"
	return 0
}

if [ "$MODE" = status ] || [ "$MODE" = dry-run ]; then
	print_state
	printf 'tree: clean\n'
	print_plan
	printf 'note: nothing was changed\n'
	exit 0
fi

# --- run the pipeline ------------------------------------------------------

print_state
printf 'ahead: %s commit(s) on %s\n' "$AHEAD" "$BASE"

# `wt hook <type>` exits 0 whether or not hooks are configured; the wording of
# its output is the only signal, so read it rather than the status.
run_hook() {
	local kind=$1 out rc
	out=$("$WT_PATH" hook "$kind" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		printf 'error: %s hook failed (exit %s)\n' "$kind" "$rc"
		if grep -qi 'approval' <<<"$out"; then
			printf 'cause: the hook needs approval and wt cannot prompt non-interactively\n'
			printf 'help: run `wt config approvals add` to review and approve it yourself\n'
		else
			printf 'cause: a %s hook reported failure\n' "$kind"
			printf 'help: fix what the hook reported below, then run this script again\n'
		fi
		printf 'published: nothing — the branch was not pushed\n'
		print_detail "$out"
		exit 1
	fi
	if grep -qiE "no $kind hooks configured" <<<"$out"; then
		printf 'hooks: %s none configured\n' "$kind"
	else
		printf 'hooks: %s ok\n' "$kind"
	fi
	return 0
}

# Step 1 — squash. It fires pre-commit itself, so the hook is only run
# separately when the squash is skipped and would otherwise be lost.
if [ "$PLAN_SQUASH" = true ]; then
	SQ=$("$WT_PATH" step squash "$BASE" 2>&1)
	SQ_RC=$?
	if [ "$SQ_RC" -ne 0 ]; then
		printf 'error: squash failed\n'
		if grep -qi 'approval' <<<"$SQ"; then
			printf 'cause: a project hook needs approval and wt cannot prompt non-interactively\n'
			printf 'help: run `wt config approvals add` to review and approve it yourself\n'
		elif grep -qiE 'command not found|No such file|failed to (spawn|run)|generation command failed' <<<"$SQ"; then
			printf 'cause: the configured [commit.generation] command could not run\n'
			printf 'help: check `wt config show` and confirm the generator CLI is installed, or rerun with --no-squash\n'
		elif grep -qiE 'pre-commit|hook .*failed' <<<"$SQ"; then
			printf 'cause: a pre-commit hook failed during the squash\n'
			printf 'help: fix what the hook reported below, then run this script again\n'
		else
			printf 'cause: `wt step squash` could not combine the commits\n'
			printf 'help: resolve what it reports below, or rerun with --no-squash\n'
		fi
		printf 'published: nothing — the branch was not pushed\n'
		print_detail "$SQ"
		exit 1
	fi
	printf 'hooks: pre-commit ran with the squash\n'
	printf 'squashed: %s -> 1\n' "$AHEAD"
	printf 'message: %s\n' "$(git log -1 --format=%s)"
	BACKUP=$(git for-each-ref "refs/wt-backup/$BRANCH" --format='%(objectname:short)' 2>/dev/null)
	[ -n "$BACKUP" ] && printf 'backup: refs/wt-backup/%s @ %s\n' "$BRANCH" "$BACKUP"
else
	run_hook pre-commit
	printf 'squashed: skipped\n'
fi

# Step 2 — rebase onto the base.
if [ "$PLAN_REBASE" = true ]; then
	RB=$("$WT_PATH" step rebase "$BASE" 2>&1)
	RB_RC=$?
	if [ "$RB_RC" -ne 0 ]; then
		printf 'error: rebase onto %s failed\n' "$BASE"
		if git rev-parse --verify -q REBASE_HEAD >/dev/null 2>&1 ||
			[ -d "$GIT_DIR/rebase-merge" ] || [ -d "$GIT_DIR/rebase-apply" ]; then
			printf 'cause: the rebase hit a conflict and is still open in this worktree\n'
			printf 'help: resolve the conflicts and run `git rebase --continue`, or `git rebase --abort` to back out\n'
		else
			printf 'cause: `wt step rebase` could not replay the branch onto %s\n' "$BASE"
			printf 'help: resolve what it reports below, or rerun with --no-rebase\n'
		fi
		printf 'published: nothing — the branch was not pushed\n'
		print_detail "$RB"
		exit 1
	fi
	printf 'rebased: onto %s\n' "$BASE"
else
	printf 'rebased: skipped, already on top of %s\n' "$BASE"
fi

# Step 3 — the gate that stands in for wt merge's pre-merge hooks.
run_hook pre-merge

# Step 4 — publish. This replaces wt merge's fast-forward of the target.
REWROTE=false
{ [ "$PLAN_SQUASH" = true ] || [ "$PLAN_REBASE" = true ]; } && REWROTE=true

if [ -z "$UPSTREAM" ]; then
	PUSH_DESC="git push -u $REMOTE $BRANCH"
	PUSH=$(git push -u "$REMOTE" "$BRANCH" 2>&1)
	PUSH_RC=$?
elif [ "$REWROTE" = true ]; then
	PUSH_DESC="git push --force-with-lease"
	PUSH=$(git push --force-with-lease 2>&1)
	PUSH_RC=$?
else
	PUSH_DESC="git push"
	PUSH=$(git push 2>&1)
	PUSH_RC=$?
fi

if [ "$PUSH_RC" -ne 0 ]; then
	printf 'error: push failed (%s)\n' "$PUSH_DESC"
	if grep -qiE 'stale info|rejected' <<<"$PUSH"; then
		printf 'cause: the remote branch moved since this worktree last saw it\n'
		printf 'help: run `git fetch %s` and reconcile before pushing again\n' "$REMOTE"
	else
		printf 'cause: git could not publish %s to %s\n' "$BRANCH" "$REMOTE"
		printf 'help: resolve what git reports below, then run this script again\n'
	fi
	printf 'published: nothing\n'
	print_detail "$PUSH"
	exit 1
fi
printf 'pushed: %s/%s (%s)\n' "$REMOTE" "$BRANCH" "$PUSH_DESC"

# Step 5 — the pull request itself.
if [ -n "$PR_URL" ]; then
	printf 'pr: %s (already open, none created)\n' "$PR_URL"
else
	GH_ARGS=(pr create --base "$BASE" --head "$BRANCH")
	if [ -z "$TITLE" ] && [ -z "$BODY" ]; then
		GH_ARGS+=(--fill)
	else
		[ -z "$TITLE" ] && TITLE=$(git log -1 --format=%s)
		GH_ARGS+=(--title "$TITLE" --body "$BODY")
	fi
	[ "$DRAFT" = true ] && GH_ARGS+=(--draft)

	CREATE=$("$GH_PATH" "${GH_ARGS[@]}" 2>&1)
	CREATE_RC=$?
	if [ "$CREATE_RC" -ne 0 ]; then
		printf 'error: `gh pr create` failed\n'
		printf 'cause: the branch is pushed but no pull request was opened\n'
		printf 'help: resolve what gh reports below, then run this script again\n'
		printf 'fallback: open the request at %s/compare/%s...%s\n' \
			"$(web_url "$COMPARE_SRC")" "$BASE" "$BRANCH"
		print_detail "$CREATE"
		exit 1
	fi
	PR_URL=$(printf '%s\n' "$CREATE" | strip_ansi | grep -oE 'https://[^ ]*/pull/[0-9]+' | head -1)
	PR_NUM=${PR_URL##*/}
	printf 'pr: %s\n' "${PR_URL:-opened}"
	[ -n "$PR_NUM" ] && printf 'pr_number: %s\n' "$PR_NUM"
fi

# Step 6 — hand the checks over. Nothing is removed here: the worktree is where
# a red run gets investigated, and `--merge` is what clears it away.
[ "$IS_LINKED" = true ] && printf 'worktree: kept at %s\n' "${REPO_ROOT/#$HOME/\~}"

print_watch "$PR_URL"
printf 'next: watch the checks, then `bash %s --merge` once the review passes\n' \
	"${SELF/#$HOME/\~}"
exit 0
