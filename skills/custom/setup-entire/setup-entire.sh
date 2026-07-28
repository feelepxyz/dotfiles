#!/usr/bin/env bash
# shellcheck disable=SC2016 # backticks in help prose are literal markup, not substitution
# Enable Entire in this repository, install hooks for each wanted agent, and set
# commit_linking in .entire/settings.local.json.
#
# Output follows AXI conventions: structured key/value and TOON tables on stdout
# (errors included), progress on stderr, exit 0 for success and no-ops, 1 for
# errors, 2 for usage.
#
# Invoke with `bash setup-entire.sh` — `npx skills` copies skill files without
# the executable bit, so a direct exec would fail.

set -uo pipefail

SELF=${BASH_SOURCE[0]}
DEFAULT_AGENTS="claude-code,codex,pi,gemini"

MODE=check
AGENTS=$DEFAULT_AGENTS
COMMIT_LINKING=always
FORCE=false

usage() {
	printf 'bin: %s\n' "${SELF/#$HOME/\~}"
	printf 'description: Enable Entire in this repo, install agent hooks, and set commit_linking\n'
	printf 'modes[2]{mode,writes,job}:\n'
	printf '  --check,nothing,"Report what Entire setup this repo has and what is missing (default)"\n'
	printf '  --apply,".entire + agent hook files","Enable Entire, install hooks, write commit_linking"\n'
	printf 'flags[3]{flag,effect}:\n'
	printf '  --agents=a\\,b,"Agents to install hooks for (default: %s)"\n' "$DEFAULT_AGENTS"
	printf '  --commit-linking=always|prompt,"Value to write (default: always)"\n'
	printf '  --force,"With --apply: reinstall hooks that are already present"\n'
	printf 'examples[3]:\n'
	printf '  bash %s\n' "${SELF/#$HOME/\~}"
	printf '  bash %s --apply\n' "${SELF/#$HOME/\~}"
	printf '  bash %s --apply --agents=claude-code,codex\n' "${SELF/#$HOME/\~}"
}

flag_error() {
	printf 'error: %s\n' "$1"
	printf 'help: valid flags: --check --apply --agents= --commit-linking= --force --help\n'
	exit 2
}

for arg in "$@"; do
	case "$arg" in
	--check) MODE=check ;;
	--apply) MODE=apply ;;
	--agents=*) AGENTS=${arg#--agents=} ;;
	--commit-linking=*) COMMIT_LINKING=${arg#--commit-linking=} ;;
	--force) FORCE=true ;;
	-h | --help)
		usage
		exit 0
		;;
	*) flag_error "unknown flag $arg" ;;
	esac
done

# Reject a flag that cannot act in the chosen mode rather than dropping it
# silently — a swallowed --force would look like a deliberate no-op.
if [ "$MODE" != apply ] && [ "$FORCE" = true ]; then
	flag_error "--force only applies to --apply"
fi

# entire rejects anything outside this pair, and a bad value makes *every*
# subsequent entire command fail to load settings. Catch it before we write.
case "$COMMIT_LINKING" in
always | prompt) ;;
*)
	printf 'error: invalid --commit-linking value %s\n' "$COMMIT_LINKING"
	printf 'help: entire accepts only `always` or `prompt`\n'
	exit 2
	;;
esac

WANT=()
IFS=',' read -r -a WANT_RAW <<<"$AGENTS"
for a in ${WANT_RAW[@]+"${WANT_RAW[@]}"}; do
	[ -n "$a" ] || flag_error "--agents= contains an empty name"
	WANT+=("$a")
done
[ ${#WANT[@]} -gt 0 ] || flag_error "--agents= names no agents"

# --- preflight -------------------------------------------------------------

if ! ENTIRE=$(command -v entire 2>/dev/null); then
	printf 'error: `entire` not found on PATH\n'
	printf 'cause: entire is the CLI this skill configures\n'
	printf 'help: install it with `brew install entire`\n'
	exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
	printf 'error: `jq` not found on PATH\n'
	printf 'cause: settings are merged rather than overwritten, which needs a JSON parser\n'
	printf 'help: install it with `brew install jq`\n'
	exit 1
fi

# The safety gate. `entire enable -y` in a non-repo directory will initialise a
# git repo *and create a private GitHub repo*; refusing here — and passing
# --no-init-repo on every call below — keeps that from ever firing.
if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || [ -z "$REPO_ROOT" ]; then
	printf 'error: not a git repository\n'
	printf 'cwd: %s\n' "${PWD/#$HOME/\~}"
	printf 'cause: entire tracks sessions against a repo, and would offer to create one here\n'
	printf 'help: cd into a repository, or run `git init` yourself first\n'
	exit 1
fi
REPO=$(basename "$REPO_ROOT")
ENTIRE_DIR="$REPO_ROOT/.entire"
LOCAL_FILE="$ENTIRE_DIR/settings.local.json"

if ! "$ENTIRE" auth status >/dev/null 2>&1; then
	printf 'error: not logged in to entire\n'
	printf 'repo: %s\n' "$REPO"
	printf 'cause: enabling a repo registers it against your Entire account\n'
	printf 'help: run `entire login`, then re-run this script\n'
	exit 1
fi

# --- detect ----------------------------------------------------------------

# Print a settings file as compact JSON. Missing is an empty object; malformed
# is a failure the caller must report rather than silently overwrite.
read_settings() {
	[ -f "$1" ] || {
		printf '{}'
		return 0
	}
	jq -e 'type == "object"' "$1" >/dev/null 2>&1 || return 1
	jq -c '.' "$1" 2>/dev/null
}

PROJECT_BAD=false
LOCAL_BAD=false
PROJECT_JSON=$(read_settings "$ENTIRE_DIR/settings.json") || PROJECT_BAD=true
LOCAL_JSON=$(read_settings "$LOCAL_FILE") || LOCAL_BAD=true
[ "$PROJECT_BAD" = true ] && PROJECT_JSON='{}'
[ "$LOCAL_BAD" = true ] && LOCAL_JSON='{}'

# Local settings win over project settings, matching how entire merges them.
MERGED=$(jq -cn --argjson a "$PROJECT_JSON" --argjson b "$LOCAL_JSON" '$a * $b' 2>/dev/null)
ENABLED=$(jq -r '.enabled // false' <<<"$MERGED" 2>/dev/null)
CUR_LINKING=$(jq -r '.commit_linking // "unset"' <<<"$MERGED" 2>/dev/null)
[ "$LOCAL_BAD" = true ] && CUR_LINKING="unreadable"

# `entire agent list --json` is not supported — it prints the usage block and
# exits 0 — so installed agents come from the ✓ markers in the human output.
installed_agents() {
	"$ENTIRE" agent list 2>/dev/null | awk '/✓/ { print $NF }'
}
INSTALLED=$(installed_agents)

is_installed() {
	printf '%s\n' "$INSTALLED" | grep -qx -- "$1"
}

MISSING=()
for a in "${WANT[@]}"; do
	if [ "$FORCE" = true ] || ! is_installed "$a"; then
		MISSING+=("$a")
	fi
done
LINKING_PENDING=false
[ "$CUR_LINKING" = "$COMMIT_LINKING" ] || LINKING_PENDING=true
PENDING=${#MISSING[@]}
[ "$LINKING_PENDING" = true ] && PENDING=$((PENDING + 1))

print_header() {
	printf 'bin: %s\n' "${SELF/#$HOME/\~}"
	printf 'repo: %s\n' "$REPO"
	printf 'enabled: %s\n' "$ENABLED"
	printf 'commit_linking: %s\n' "$CUR_LINKING"
}

print_agents() {
	printf 'agents[%d]{agent,state}:\n' "${#WANT[@]}"
	local a
	for a in "${WANT[@]}"; do
		if is_installed "$a"; then
			printf '  %s,installed\n' "$a"
		else
			printf '  %s,missing\n' "$a"
		fi
	done
}

# Only the paths this script can touch, so the report stays comparable to
# `git status --porcelain` over those same paths.
print_changed() {
	local out n
	out=$(cd "$REPO_ROOT" && git status --porcelain -- \
		.entire .claude .codex .gemini .pi 2>/dev/null)
	if [ -z "$out" ]; then
		printf 'changed: 0 paths — nothing for git to record\n'
		return 0
	fi
	n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
	printf 'changed[%d]{status,path}:\n' "$n"
	printf '%s\n' "$out" | sed 's/^ *\([^ ]*\) */  \1,/'
}

bad_local_settings() {
	printf 'error: .entire/settings.local.json is not valid JSON\n'
	printf 'repo: %s\n' "$REPO"
	printf 'cause: entire fails to load settings while it stays that way\n'
	printf 'help: inspect or delete it — it is gitignored and local to you — then re-run\n'
	exit 1
}

if [ "$PROJECT_BAD" = true ]; then
	printf 'error: .entire/settings.json is not valid JSON\n'
	printf 'repo: %s\n' "$REPO"
	printf 'cause: entire cannot load settings from it, so no command will work\n'
	printf 'help: inspect or delete .entire/settings.json, then re-run\n'
	exit 1
fi

# --- check -----------------------------------------------------------------

if [ "$MODE" = check ]; then
	[ "$LOCAL_BAD" = true ] && bad_local_settings
	print_header
	print_agents
	if [ "$PENDING" -eq 0 ]; then
		printf 'pending: 0 — already converged (no-op)\n'
		exit 0
	fi
	printf 'pending[%d]:\n' "$PENDING"
	for a in ${MISSING[@]+"${MISSING[@]}"}; do
		printf '  install hooks for %s\n' "$a"
	done
	[ "$LINKING_PENDING" = true ] &&
		printf '  set commit_linking=%s (currently %s)\n' "$COMMIT_LINKING" "$CUR_LINKING"
	printf 'help: run `bash %s --apply` to converge\n' "${SELF/#$HOME/\~}"
	exit 0
fi

# --- apply -----------------------------------------------------------------

[ "$LOCAL_BAD" = true ] && bad_local_settings

if [ "$PENDING" -eq 0 ]; then
	print_header
	print_agents
	printf 'applied: 0 changes — already converged (no-op)\n'
	exit 0
fi

FAILED=()
for a in ${MISSING[@]+"${MISSING[@]}"}; do
	printf 'installing hooks for %s...\n' "$a" >&2
	if [ "$FORCE" = true ]; then
		"$ENTIRE" enable -y --agent "$a" --no-init-repo --force >&2 || FAILED+=("$a")
	else
		"$ENTIRE" enable -y --agent "$a" --no-init-repo >&2 || FAILED+=("$a")
	fi
done

if [ ${#FAILED[@]} -gt 0 ]; then
	printf 'error: entire could not install hooks for: %s\n' "${FAILED[*]}"
	printf 'repo: %s\n' "$REPO"
	printf 'cause: the enable call failed — its output is above on stderr\n'
	printf 'help: check the agent names against `entire agent list`, then re-run --apply\n'
	exit 1
fi

# `entire enable` replaces .entire/settings.local.json wholesale with
# {"enabled":true} whenever that file already exists — it does not merge, and
# --project does not stop it. So this runs after every enable call, and folds
# $LOCAL_JSON (snapshotted before them) back over the result, or a
# commit_linking set on an earlier run would silently vanish here. `enabled` is
# left to entire, since enabling is exactly what we just did.
printf 'setting commit_linking=%s...\n' "$COMMIT_LINKING" >&2
if ! mkdir -p "$ENTIRE_DIR" 2>/dev/null ||
	! TMP=$(mktemp "$ENTIRE_DIR/.settings.local.json.XXXXXX" 2>/dev/null); then
	printf 'error: could not write into %s\n' '.entire'
	printf 'repo: %s\n' "$REPO"
	printf 'cause: the directory is missing or not writable\n'
	printf 'help: check its permissions, then re-run --apply\n'
	exit 1
fi
AFTER_JSON=$(read_settings "$LOCAL_FILE") || AFTER_JSON='{}'
jq -n --argjson after "$AFTER_JSON" --argjson prior "$LOCAL_JSON" \
	--arg v "$COMMIT_LINKING" \
	'($after * ($prior | del(.enabled))) | .commit_linking = $v' >"$TMP" 2>/dev/null
JQ_RC=$?
if [ "$JQ_RC" -ne 0 ] || [ ! -s "$TMP" ]; then
	rm -f "$TMP"
	printf 'error: could not set commit_linking in .entire/settings.local.json\n'
	printf 'repo: %s\n' "$REPO"
	printf 'cause: jq did not produce a merged object\n'
	printf 'help: inspect .entire/settings.local.json, then re-run --apply\n'
	exit 1
fi
mv "$TMP" "$LOCAL_FILE"

# --- report the achieved state, re-read rather than assumed ----------------

INSTALLED=$(installed_agents)
PROJECT_JSON=$(read_settings "$ENTIRE_DIR/settings.json") || PROJECT_JSON='{}'
LOCAL_JSON=$(read_settings "$LOCAL_FILE") || LOCAL_JSON='{}'
MERGED=$(jq -cn --argjson a "$PROJECT_JSON" --argjson b "$LOCAL_JSON" '$a * $b' 2>/dev/null)
ENABLED=$(jq -r '.enabled // false' <<<"$MERGED" 2>/dev/null)
CUR_LINKING=$(jq -r '.commit_linking // "unset"' <<<"$MERGED" 2>/dev/null)

print_header
print_agents
printf 'applied: %d hook install(s), commit_linking=%s\n' "${#MISSING[@]}" "$COMMIT_LINKING"
print_changed
printf 'note: .entire/settings.local.json is gitignored, so commit_linking stays local to you\n'
printf 'help: review the changed paths, then commit them\n'
exit 0
