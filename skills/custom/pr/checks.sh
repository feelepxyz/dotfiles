#!/usr/bin/env bash
# shellcheck disable=SC2016 # backticks in help prose are literal markup, not substitution
# Watch a pull request's checks until they settle, then report one verdict.
#
# Built to be run in the background: everything on stdout is a single terminal
# block printed once, at the end, so one notification carries the whole answer.
# Progress goes to stderr. The `checks:` line is the discriminator — a red CI is
# an outcome, not a script fault, so it still exits 0.
#
# The pull request URL resolves its own repository, so the watch does not depend
# on the working directory and survives the worktree it started in.
#
# Output follows AXI conventions: structured key/value on stdout (errors
# included), progress on stderr, exit 0 for a completed watch, 1 for errors,
# 2 for usage.
#
# Invoke with `bash checks.sh` — `npx skills` copies skill files without the
# executable bit, so a direct exec would fail.

set -uo pipefail

SELF=${BASH_SOURCE[0]}
SELF_DIR=$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)
INTERVAL=300
DEADLINE=1200
GRACE=60
PROBE=15
ONCE=false
TARGET=""

# How much of each failing job's log to keep, and how many jobs to fetch. A
# verdict the agent has to page through is no better than the web UI.
MAX_JOBS=3
LOG_TAIL=200

usage() {
	printf 'bin: %s\n' "${SELF/#$HOME/\~}"
	printf 'description: Watch a pull request'"'"'s checks and report one verdict\n'
	printf 'args[1]{arg,meaning}:\n'
	printf '  <pr>,"Pull request URL or number (default: the current branch'"'"'s)"\n'
	printf 'flags[5]{flag,effect}:\n'
	printf '  --interval <s>,"Seconds between polls (default %s)"\n' "$INTERVAL"
	printf '  --deadline <s>,"Stop watching after this many seconds (default %s)"\n' "$DEADLINE"
	printf '  --grace <s>,"Seconds to wait for checks to appear before reporting none (default %s)"\n' "$GRACE"
	printf '  --once,"Poll once and report, even if the checks are still running"\n'
	printf '  --help,"This text"\n'
	printf 'verdicts[5]{checks,meaning}:\n'
	printf '  pass,"every check succeeded or was skipped"\n'
	printf '  fail,"at least one check failed or was cancelled; see log:"\n'
	printf '  pending,"still running (--once only)"\n'
	printf '  timeout,"still running when the deadline arrived"\n'
	printf '  none,"the request reports no checks at all"\n'
}

need_value() {
	case ${2:-} in
	"" | --*)
		printf 'error: %s requires a value\n' "$1"
		usage
		exit 2
		;;
	esac
}

# Seconds only — a bad value would otherwise turn into an infinite watch.
need_seconds() {
	case ${2:-} in
	'' | *[!0-9]*)
		printf 'error: %s takes a whole number of seconds, got %s\n' "$1" "${2:-}"
		exit 2
		;;
	esac
}

while [ $# -gt 0 ]; do
	case "$1" in
	--interval)
		need_value "$1" "${2:-}"
		need_seconds "$1" "$2"
		INTERVAL=$2
		shift
		;;
	--interval=*)
		need_seconds --interval "${1#--interval=}"
		INTERVAL=${1#--interval=}
		;;
	--deadline)
		need_value "$1" "${2:-}"
		need_seconds "$1" "$2"
		DEADLINE=$2
		shift
		;;
	--deadline=*)
		need_seconds --deadline "${1#--deadline=}"
		DEADLINE=${1#--deadline=}
		;;
	--grace)
		need_value "$1" "${2:-}"
		need_seconds "$1" "$2"
		GRACE=$2
		shift
		;;
	--grace=*)
		need_seconds --grace "${1#--grace=}"
		GRACE=${1#--grace=}
		;;
	--once) ONCE=true ;;
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
		if [ -n "$TARGET" ]; then
			printf 'error: only one pull request can be watched, got %s and %s\n' "$TARGET" "$1"
			exit 2
		fi
		TARGET=$1
		;;
	esac
	shift
done

# The grace probe must not overshoot the grace window itself.
[ "$PROBE" -gt "$GRACE" ] && PROBE=$GRACE

# --- locate the tools ------------------------------------------------------

if ! GH_PATH=$(command -v gh 2>/dev/null); then
	printf 'error: `gh` not found on PATH\n'
	printf 'cause: the GitHub CLI is what reports check status\n'
	printf 'help: install it with `brew install gh`\n'
	exit 1
fi

note() { printf '%s\n' "$*" >&2; }

# --- resolve the pull request ----------------------------------------------

# Templated explicitly: BSD and GNU mktemp disagree about bare `-t` prefixes.
VIEW_ERR=$(mktemp "${TMPDIR:-/tmp}/pr-checks-view.XXXXXX")
trap 'rm -f "$VIEW_ERR"' EXIT

if [ -n "$TARGET" ]; then
	VIEW=$("$GH_PATH" pr view "$TARGET" --json url,number,state 2>"$VIEW_ERR")
else
	VIEW=$("$GH_PATH" pr view --json url,number,state 2>"$VIEW_ERR")
fi
if [ -z "$VIEW" ]; then
	printf 'error: no pull request to watch\n'
	if [ -z "$TARGET" ]; then
		printf 'cause: no request was named and the current branch has none open\n'
		printf 'help: pass the pull request URL or number, or run this from a branch with an open request\n'
	else
		printf 'cause: gh could not resolve %s\n' "$TARGET"
		printf 'help: pass the full pull request URL, or a number from inside its repository\n'
	fi
	printf 'detail:\n'
	sed 's/^/  /' <"$VIEW_ERR"
	exit 1
fi

PR_URL=$(printf '%s' "$VIEW" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
PR_NUM=$(printf '%s' "$VIEW" | sed -n 's/.*"number":\([0-9]*\).*/\1/p')
PR_STATE=$(printf '%s' "$VIEW" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')

# https://github.com/OWNER/REPO/pull/N -> OWNER/REPO
SLUG=${PR_URL#*://}
SLUG=${SLUG#*/}
SLUG=${SLUG%%/pull/*}

print_head() {
	printf 'pr: %s\n' "$PR_URL"
	printf 'pr_number: %s\n' "$PR_NUM"
	return 0
}

if [ "$PR_STATE" != OPEN ]; then
	print_head
	printf 'checks: none\n'
	printf 'state: %s\n' "$PR_STATE"
	printf 'next: nothing to watch — this request is already %s\n' "$(printf '%s' "$PR_STATE" | tr '[:upper:]' '[:lower:]')"
	exit 0
fi

# --- polling ---------------------------------------------------------------

START=$SECONDS
elapsed() { printf '%s' "$((SECONDS - START))"; }

POLL_ERR=$(mktemp "${TMPDIR:-/tmp}/pr-checks-poll.XXXXXX")
trap 'rm -f "$VIEW_ERR" "$POLL_ERR"' EXIT

# One line per check: bucket<TAB>name<TAB>link. Empty means no checks reported.
ROWS=""
poll() {
	ROWS=$("$GH_PATH" pr checks "$PR_URL" \
		--json bucket,name,link \
		--jq '.[] | [.bucket, .name, .link] | @tsv' 2>"$POLL_ERR")
	return 0
}

rows_matching() {
	[ -z "$ROWS" ] && return 0
	printf '%s\n' "$ROWS" | awk -F'\t' -v want="$1" '$1 == want'
	return 0
}

count_matching() {
	local out
	out=$(rows_matching "$1")
	[ -z "$out" ] && printf 0 && return 0
	printf '%s' "$out" | grep -c . || printf 0
	return 0
}

# name-only block, e.g. pending[2]{name}:
print_names() {
	local key=$1 rows=$2 n
	n=$(printf '%s' "$rows" | grep -c . || true)
	printf '%s[%s]{name}:\n' "$key" "$n"
	printf '%s\n' "$rows" | while IFS=$'\t' read -r _ name _; do
		[ -z "$name" ] && continue
		printf '  "%s"\n' "$name"
	done
	return 0
}

# Fetch the failing steps of each failing job into one file. Only GitHub Actions
# links carry a job id; anything else (an external CI status) is named but not
# fetched, so the caller is never told a log exists when it does not.
LOG_PATH=""
capture_logs() {
	local rows=$1 path job dir fetched=0 skipped=0
	dir=${TMPDIR:-/tmp}
	path=${dir%/}/pr-checks-${SLUG//\//-}-${PR_NUM}.log
	: >"$path" || return 1
	while IFS=$'\t' read -r _ name link; do
		[ -z "$name" ] && continue
		[ "$fetched" -ge "$MAX_JOBS" ] && {
			skipped=$((skipped + 1))
			continue
		}
		job=$(printf '%s' "$link" | sed -n 's|.*/job/\([0-9][0-9]*\).*|\1|p')
		{
			printf '=== %s\n' "$name"
			printf '=== %s\n' "$link"
		} >>"$path"
		if [ -z "$job" ]; then
			printf '(no GitHub Actions job behind this check — open the link)\n\n' >>"$path"
			continue
		fi
		note "checks: fetching log for $name"
		"$GH_PATH" run view -R "$SLUG" -j "$job" --log-failed 2>&1 |
			tail -n "$LOG_TAIL" >>"$path"
		printf '\n' >>"$path"
		fetched=$((fetched + 1))
	done <<<"$rows"
	if [ "$skipped" -gt 0 ]; then
		printf '(%s further failing job(s) not fetched)\n' "$skipped" >>"$path"
	fi
	LOG_PATH=$path
	return 0
}

report_pass() {
	print_head
	printf 'checks: pass\n'
	printf 'passed: %s of %s\n' "$(count_matching pass)" "$(printf '%s\n' "$ROWS" | grep -c . || printf 0)"
	printf 'elapsed: %ss\n' "$(elapsed)"
	printf 'next: bash %s/pr.sh --merge, once the review passes\n' "${SELF_DIR/#$HOME/\~}"
	exit 0
}

report_fail() {
	local failing n logline
	failing=$(
		rows_matching fail
		rows_matching cancel
	)
	failing=$(printf '%s\n' "$failing" | grep . || true)
	n=$(printf '%s\n' "$failing" | grep -c . || true)
	# Fetch the logs before printing anything. Fetching takes seconds, and a
	# watcher run in the background delivers stdout as it arrives — a block
	# interrupted mid-way arrives as two notifications instead of one verdict.
	if capture_logs "$failing"; then
		logline="log: $LOG_PATH"
	else
		logline="log: none — could not write to ${TMPDIR:-/tmp}"
	fi
	print_head
	printf 'checks: fail\n'
	printf 'failed[%s]{name,link}:\n' "$n"
	printf '%s\n' "$failing" | while IFS=$'\t' read -r _ name link; do
		[ -z "$name" ] && continue
		printf '  "%s",%s\n' "$name" "$link"
	done
	printf '%s\n' "$logline"
	printf 'elapsed: %ss\n' "$(elapsed)"
	printf 'help: read the log, fix the branch in this worktree, then commit and push again\n'
	exit 0
}

report_pending() {
	local verdict=$1
	print_head
	printf 'checks: %s\n' "$verdict"
	print_names pending "$(rows_matching pending)"
	printf 'elapsed: %ss\n' "$(elapsed)"
	printf 'help: run `bash %s/checks.sh %s` to keep watching\n' \
		"${SELF_DIR/#$HOME/\~}" "$PR_URL"
	exit 0
}

report_none() {
	print_head
	printf 'checks: none\n'
	printf 'elapsed: %ss\n' "$(elapsed)"
	printf 'detail:\n'
	sed 's/^/  /' <"$POLL_ERR" | head -3
	printf 'next: nothing to watch — this repository reports no checks for the request\n'
	exit 0
}

# --- grace probe -----------------------------------------------------------
# `gh pr checks` says "no checks reported" both when a repository has no CI and
# when GitHub has not registered the run yet. Poll briefly to tell them apart,
# rather than making a CI-less repository wait for the first full interval.

note "checks: watching $PR_URL (interval ${INTERVAL}s, deadline ${DEADLINE}s)"
while :; do
	poll
	[ -n "$ROWS" ] && break
	[ "$(elapsed)" -ge "$GRACE" ] && report_none
	note "checks: none reported yet, probing again in ${PROBE}s"
	sleep "$PROBE"
done

# --- watch -----------------------------------------------------------------

while :; do
	PENDING=$(count_matching pending)
	if [ "$PENDING" -eq 0 ]; then
		if [ "$(count_matching fail)" -gt 0 ] || [ "$(count_matching cancel)" -gt 0 ]; then
			report_fail
		fi
		report_pass
	fi

	[ "$ONCE" = true ] && report_pending pending

	NOW=$(elapsed)
	[ "$NOW" -ge "$DEADLINE" ] && report_pending timeout

	NAP=$INTERVAL
	REMAINING=$((DEADLINE - NOW))
	[ "$NAP" -gt "$REMAINING" ] && NAP=$REMAINING
	note "checks: $PENDING still running at ${NOW}s, next poll in ${NAP}s"
	sleep "$NAP"
	poll
	# Checks can vanish between polls only if the run was deleted; treat an
	# empty read as "still waiting" rather than silently reporting a pass.
	[ -z "$ROWS" ] && report_pending timeout
done
