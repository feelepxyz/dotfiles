#!/usr/bin/env bash
# shellcheck disable=SC2016 # backticks in help prose are literal markup, not substitution
# Converge a GitHub repository's housekeeping settings: merge hygiene, a
# guardrail ruleset on the default branch, Dependabot, and secret scanning.
#
# Output follows AXI conventions: structured key/value and TOON tables on stdout
# (errors included), progress on stderr, exit 0 for success and no-ops, 1 for
# errors, 2 for usage.
#
# Invoke with `bash setup-github.sh` — `npx skills` copies skill files without
# the executable bit, so a direct exec would fail.

set -uo pipefail

SELF=${BASH_SOURCE[0]}
SEP=$'\037'

# Rulesets carry no comment field, so the name is the only ownership handle we
# get. A ruleset by this name is treated as ours and converged; any other branch
# ruleset overlapping the default branch is someone else's and blocks --apply.
RULESET_NAME="default-branch-guardrails"

# The two rules the ruleset writes. Signing is deliberately absent: requiring
# signatures would gate agent commits on a signing key being present.
RULESET_RULES='[{"type":"deletion"},{"type":"non_fast_forward"}]'

ALL_ITEMS="delete-branch-on-merge auto-merge update-branch ruleset dependabot-alerts dependabot-security-updates secret-scanning push-protection squash-only"
RECOMMENDED="delete-branch-on-merge auto-merge update-branch ruleset dependabot-alerts dependabot-security-updates secret-scanning push-protection"

MODE=plan
ACCEPT=false
FORCE=false
REPO_ARG=""
SEL_ITEMS=""
SEL_GIVEN=false

usage() {
	printf 'bin: %s\n' "${SELF/#$HOME/\~}"
	printf 'description: Converge a GitHub repo to merge hygiene, branch guardrails, Dependabot and secret scanning\n'
	printf 'modes[3]{mode,writes,job}:\n'
	printf '  --plan,nothing,"Probe the repo and print the item table (default)"\n'
	printf '  --apply,"GitHub repo settings","Converge the selected items"\n'
	printf '  --status,nothing,"Report what is set right now"\n'
	printf 'flags[4]{flag,effect}:\n'
	printf '  --repo=owner/name,"Act on this repo instead of resolving one from the cwd"\n'
	printf '  --accept,"With --apply: take the recommended set"\n'
	printf '  --items=a\\,b,"With --apply: the exact item ids"\n'
	printf '  --force,"With --apply: add the guardrail ruleset alongside a foreign one (never removes it)"\n'
	printf 'items[9]{id,recommended}:\n'
	local i
	for i in $ALL_ITEMS; do
		if is_recommended "$i"; then printf '  %s,yes\n' "$i"; else printf '  %s,no\n' "$i"; fi
	done
	printf 'examples[3]:\n'
	printf '  bash %s\n' "${SELF/#$HOME/\~}"
	printf '  bash %s --apply --accept\n' "${SELF/#$HOME/\~}"
	printf '  bash %s --apply --items=ruleset,delete-branch-on-merge\n' "${SELF/#$HOME/\~}"
}

flag_error() {
	printf 'error: %s\n' "$1"
	printf 'help: valid flags: --plan --apply --status --repo= --accept --items= --force --help\n'
	exit 2
}

is_recommended() {
	local i
	for i in $RECOMMENDED; do [ "$i" = "$1" ] && return 0; done
	return 1
}

is_known_item() {
	local i
	for i in $ALL_ITEMS; do [ "$i" = "$1" ] && return 0; done
	return 1
}

for arg in "$@"; do
	case "$arg" in
	--plan) MODE=plan ;;
	--apply) MODE=apply ;;
	--status) MODE=status ;;
	--repo=*) REPO_ARG=${arg#--repo=} ;;
	--accept) ACCEPT=true ;;
	--items=*)
		SEL_ITEMS=${arg#--items=}
		SEL_GIVEN=true
		;;
	--force) FORCE=true ;;
	-h | --help)
		usage
		exit 0
		;;
	*) flag_error "unknown flag $arg" ;;
	esac
done

# Reject a flag that cannot act in the chosen mode rather than dropping it
# silently — a swallowed --items would look like a deliberate selection.
if [ "$MODE" != apply ]; then
	[ "$ACCEPT" = true ] && flag_error "--accept only applies to --apply"
	[ "$SEL_GIVEN" = true ] && flag_error "--items only applies to --apply"
	[ "$FORCE" = true ] && flag_error "--force only applies to --apply"
fi

if [ "$MODE" = apply ]; then
	if [ "$ACCEPT" = true ] && [ "$SEL_GIVEN" = true ]; then
		flag_error "--accept and --items are mutually exclusive"
	fi
	if [ "$ACCEPT" = false ] && [ "$SEL_GIVEN" = false ]; then
		printf 'error: --apply needs a selection\n'
		printf 'cause: these settings are visible to everyone with access to the repo, so the set is never implied\n'
		printf 'help: pass --accept for the recommended set, or --items=a,b for an exact one\n'
		exit 2
	fi
fi

WANT=()
if [ "$ACCEPT" = true ]; then
	for i in $RECOMMENDED; do WANT+=("$i"); done
elif [ "$SEL_GIVEN" = true ]; then
	IFS=',' read -r -a WANT_RAW <<<"$SEL_ITEMS"
	for i in ${WANT_RAW[@]+"${WANT_RAW[@]}"}; do
		[ -n "$i" ] || flag_error "--items= contains an empty id"
		if ! is_known_item "$i"; then
			printf 'error: unknown item id %s\n' "$i"
			printf 'help: valid ids: %s\n' "${ALL_ITEMS// /, }"
			exit 2
		fi
		WANT+=("$i")
	done
	[ ${#WANT[@]} -gt 0 ] || flag_error "--items= names no items"
fi

wanted() {
	local i
	for i in ${WANT[@]+"${WANT[@]}"}; do [ "$i" = "$1" ] && return 0; done
	return 1
}

# --- preflight -------------------------------------------------------------

if ! GH=$(command -v gh 2>/dev/null); then
	printf 'error: `gh` not found on PATH\n'
	printf 'cause: every setting this skill reads or writes goes through the GitHub API\n'
	printf 'help: install it with `brew install gh`\n'
	exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
	printf 'error: `jq` not found on PATH\n'
	printf 'cause: settings are read and built as JSON before being sent\n'
	printf 'help: install it with `brew install jq`\n'
	exit 1
fi

if ! "$GH" auth status >/dev/null 2>&1; then
	printf 'error: not logged in to GitHub\n'
	printf 'cause: reading and changing repo settings needs an authenticated token\n'
	printf 'help: run `gh auth login`, then re-run this script\n'
	exit 1
fi

# A repo named outright skips cwd resolution entirely — that is what lets this
# script report on a repo you are not sitting in.
if [ -n "$REPO_ARG" ]; then
	case "$REPO_ARG" in
	*/*) REPO=$REPO_ARG ;;
	*)
		printf 'error: --repo needs the owner/name form\n'
		printf 'cause: %s names no owner, so the API cannot resolve it\n' "$REPO_ARG"
		printf 'help: pass --repo=owner/name\n'
		exit 2
		;;
	esac
elif ! REPO=$("$GH" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || [ -z "$REPO" ]; then
	# Not resolving splits two ways, and only one of them is an error.
	if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
		printf 'error: not a git repository\n'
		printf 'cwd: %s\n' "${PWD/#$HOME/\~}"
		printf 'cause: this skill configures a GitHub repo, and there is none to resolve here\n'
		printf 'help: cd into a repository, or name one with --repo=owner/name\n'
		exit 1
	fi
	printf 'github: skipped — no github remote\n'
	printf 'repo: %s\n' "$(basename "$(git rev-parse --show-toplevel)")"
	printf 'cause: the repo has no remote on github.com, so there are no settings to converge\n'
	printf 'help: add one with `gh repo create --source=. --remote=origin`, then re-run\n'
	exit 0
fi

# --- probe -----------------------------------------------------------------

if ! REPO_JSON=$("$GH" api "repos/$REPO" 2>/dev/null) || [ -z "$REPO_JSON" ]; then
	printf 'error: could not read repos/%s\n' "$REPO"
	printf 'cause: the repo does not exist, or this token cannot see it\n'
	printf 'help: check the name, and that `gh auth status` lists a token with `repo` scope\n'
	exit 1
fi

j() { jq -r "$1" <<<"$REPO_JSON" 2>/dev/null; }

ADMIN=$(j '.permissions.admin // false')
PRIVATE=$(j '.private // false')
DEFAULT_BRANCH=$(j '.default_branch // "main"')
CUR_DELETE=$(j '.delete_branch_on_merge // false')
CUR_AUTO=$(j '.allow_auto_merge // false')
CUR_UPDATE=$(j '.allow_update_branch // false')
CUR_MERGE_COMMIT=$(j '.allow_merge_commit // false')
CUR_REBASE=$(j '.allow_rebase_merge // false')
CUR_SECRET=$(j '.security_and_analysis.secret_scanning.status // "unavailable"')
CUR_PUSHPROT=$(j '.security_and_analysis.secret_scanning_push_protection.status // "unavailable"')

# Every security setting below is admin-only to read: without admin the API
# omits security_and_analysis and 404s the two Dependabot endpoints, which is
# indistinguishable from them being off. Say `unknown` rather than guess.
if [ "$ADMIN" != true ]; then
	SECRET_STATE=unknown
	SECRET_DETAIL="not readable without admin on this repo"
	CUR_ALERTS=unknown
	CUR_FIXES=unknown
else
	# Secret scanning is free on public repos and needs GitHub Advanced Security
	# on private ones, where the whole block comes back null.
	if [ "$(j '.security_and_analysis | type')" = null ]; then
		SECRET_STATE=unavailable
		if [ "$PRIVATE" = true ]; then
			SECRET_DETAIL="needs GitHub Advanced Security on a private repo"
		else
			SECRET_DETAIL="GitHub returned no security_and_analysis block for this repo"
		fi
	else
		SECRET_STATE=readable
		SECRET_DETAIL=""
	fi

	# 204 means alerts are on, 404 means off — the body is empty either way.
	if "$GH" api "repos/$REPO/vulnerability-alerts" --silent >/dev/null 2>&1; then
		CUR_ALERTS=enabled
	else
		CUR_ALERTS=disabled
	fi

	if FIX_JSON=$("$GH" api "repos/$REPO/automated-security-fixes" 2>/dev/null) &&
		[ "$(jq -r '.enabled // false' <<<"$FIX_JSON" 2>/dev/null)" = true ]; then
		CUR_FIXES=enabled
	else
		CUR_FIXES=disabled
	fi
fi

# Rulesets. The list response omits conditions, so branch rulesets are fetched
# individually to find out which ones actually reach the default branch.
# Wrapped in a function so the post-apply verification can re-run the *same*
# comparison. Counting rulesets by name after an apply would report a drifted
# ruleset as present, since the name survives whatever happened to the rules.
ruleset_probe() {
	RULESET_ID=""
	RULESET_MATCHES=false
	FOREIGN_OVERLAP=""
	INEFFECTIVE=""
	if RS_LIST=$("$GH" api "repos/$REPO/rulesets" 2>/dev/null); then
		while IFS=$'\t' read -r rs_id rs_name rs_target; do
			[ -n "$rs_id" ] || continue
			[ "$rs_target" = branch ] || continue
			rs=$("$GH" api "repos/$REPO/rulesets/$rs_id" 2>/dev/null) || continue
			includes=$(jq -r '(.conditions.ref_name.include // []) | join(",")' <<<"$rs" 2>/dev/null)
			types=$(jq -r '[.rules[].type] | sort | join(",")' <<<"$rs" 2>/dev/null)
			if [ "$rs_name" = "$RULESET_NAME" ]; then
				RULESET_ID=$rs_id
				want_types=$(jq -r '[.[].type] | sort | join(",")' <<<"$RULESET_RULES" 2>/dev/null)
				if [ "$includes" = "~DEFAULT_BRANCH" ] && [ "$types" = "$want_types" ] &&
					[ "$(jq -r '.enforcement' <<<"$rs" 2>/dev/null)" = active ]; then
					RULESET_MATCHES=true
				fi
				continue
			fi
			# Someone else's ruleset. It only conflicts if it reaches the default
			# branch; one whose include list is empty reaches nothing at all, which
			# is worth saying out loud rather than silently ignoring.
			case ",$includes," in
			*",~ALL,"* | *",~DEFAULT_BRANCH,"* | *",refs/heads/$DEFAULT_BRANCH,"*)
				FOREIGN_OVERLAP="$rs_name (id $rs_id)"
				;;
			esac
			[ -z "$includes" ] && INEFFECTIVE="$rs_name (id $rs_id)"
		done < <(jq -r '.[] | [.id, .name, .target] | @tsv' <<<"$RS_LIST" 2>/dev/null)
	fi

	if [ -n "$RULESET_ID" ]; then
		RULESET_STATE=$([ "$RULESET_MATCHES" = true ] && echo managed || echo drifted)
	else
		RULESET_STATE=absent
	fi
	return 0
}

ruleset_probe

# Classic branch protection coexists with rulesets and both enforce, so it is
# reported in full and never touched.
CLASSIC=""
if PROT=$("$GH" api "repos/$REPO/branches/$DEFAULT_BRANCH/protection" 2>/dev/null); then
	CLASSIC=$(jq -r '[
		(if .required_signatures.enabled then "required_signatures" else empty end),
		(if .enforce_admins.enabled then "enforce_admins" else empty end),
		(if .required_linear_history.enabled then "required_linear_history" else empty end),
		(if (.allow_force_pushes.enabled | not) then "no_force_push" else empty end),
		(if (.allow_deletions.enabled | not) then "no_deletion" else empty end),
		(if .required_pull_request_reviews then "required_pull_request_reviews" else empty end)
	] | join(",")' <<<"$PROT" 2>/dev/null)
	[ -n "$CLASSIC" ] || CLASSIC="present"
fi

# --- item model ------------------------------------------------------------

ITEMS=()
# id, current (on|off|unavailable), detail
add_item() { ITEMS+=("$1$SEP$2$SEP$3"); }

on_off() {
	case "$1" in
	true | enabled) printf 'on' ;;
	*) printf 'off' ;;
	esac
}

add_item delete-branch-on-merge "$(on_off "$CUR_DELETE")" "delete the head branch once a PR merges"
add_item auto-merge "$(on_off "$CUR_AUTO")" "let a PR merge itself once checks pass"
add_item update-branch "$(on_off "$CUR_UPDATE")" "offer the update-branch button on stale PRs"

case "$RULESET_STATE" in
managed) add_item ruleset on "$RULESET_NAME on ~DEFAULT_BRANCH: deletion, non_fast_forward" ;;
drifted) add_item ruleset off "$RULESET_NAME exists but has drifted from deletion, non_fast_forward" ;;
absent) add_item ruleset off "no $RULESET_NAME ruleset: default branch can be deleted or force-pushed" ;;
esac

if [ "$CUR_ALERTS" = unknown ]; then
	add_item dependabot-alerts unknown "not readable without admin on this repo"
	add_item dependabot-security-updates unknown "not readable without admin on this repo"
else
	add_item dependabot-alerts "$(on_off "$CUR_ALERTS")" "alert on vulnerable dependencies"
	add_item dependabot-security-updates "$(on_off "$CUR_FIXES")" "open PRs that fix vulnerable dependencies"
fi

case "$SECRET_STATE" in
readable)
	add_item secret-scanning "$(on_off "$CUR_SECRET")" "scan for committed credentials"
	add_item push-protection "$(on_off "$CUR_PUSHPROT")" "reject pushes that carry a secret"
	;;
*)
	add_item secret-scanning "$SECRET_STATE" "$SECRET_DETAIL"
	add_item push-protection "$SECRET_STATE" "$SECRET_DETAIL"
	;;
esac

SQUASH_ONLY=off
[ "$CUR_MERGE_COMMIT" = false ] && [ "$CUR_REBASE" = false ] && SQUASH_ONLY=on
add_item squash-only "$SQUASH_ONLY" "squash is the only merge method offered"

# --- reporting -------------------------------------------------------------

print_header() {
	printf 'bin: %s\n' "${SELF/#$HOME/\~}"
	printf 'repo: %s\n' "$REPO"
	printf 'visibility: %s\n' "$([ "$PRIVATE" = true ] && echo private || echo public)"
	printf 'default_branch: %s\n' "$DEFAULT_BRANCH"
	printf 'admin: %s\n' "$ADMIN"
}

print_findings() {
	[ -n "$CLASSIC" ] && printf 'classic_protection: %s (reported, never changed by this skill)\n' "$CLASSIC"
	case "$CLASSIC" in
	*required_signatures*)
		printf 'note: classic protection requires signed commits on %s — the ruleset does not, but classic wins\n' "$DEFAULT_BRANCH"
		;;
	esac
	[ -n "$FOREIGN_OVERLAP" ] &&
		printf 'foreign_ruleset: %s also governs %s\n' "$FOREIGN_OVERLAP" "$DEFAULT_BRANCH"
	[ -n "$INEFFECTIVE" ] &&
		printf 'ineffective_ruleset: %s has an empty ref_name.include, so it protects nothing\n' "$INEFFECTIVE"
	return 0
}

print_item_table() {
	local rows=() rec id state detail mark
	for rec in ${ITEMS[@]+"${ITEMS[@]}"}; do
		IFS="$SEP" read -r id state detail <<<"$rec"
		if [ ${#WANT[@]} -gt 0 ]; then
			wanted "$id" && mark=Y || mark=""
		else
			is_recommended "$id" && mark=Y || mark=""
		fi
		rows+=("  $mark,$id,$state,\"$detail\"")
	done
	printf 'items[%s]{on,id,current,detail}:\n' "${#rows[@]}"
	printf '%s\n' "${rows[@]}"
	return 0
}

# The set that --apply would actually change: wanted, currently off, available.
PENDING=()
compute_pending() {
	PENDING=()
	local rec id state detail sel
	for rec in ${ITEMS[@]+"${ITEMS[@]}"}; do
		IFS="$SEP" read -r id state detail <<<"$rec"
		if [ ${#WANT[@]} -gt 0 ]; then
			wanted "$id" && sel=1 || sel=0
		else
			is_recommended "$id" && sel=1 || sel=0
		fi
		[ "$sel" = 1 ] || continue
		[ "$state" = off ] || continue
		PENDING+=("$id")
	done
	return 0
}

print_pending() {
	compute_pending
	if [ "$ADMIN" != true ]; then
		printf 'pending: %d blocked — this token has no admin permission on %s\n' "${#PENDING[@]}" "$REPO"
		printf 'help: ask an owner to grant admin, or run this against a repo you administer\n'
		return 0
	fi
	if [ ${#PENDING[@]} -eq 0 ]; then
		printf 'pending: 0 — already converged (no-op)\n'
		return 0
	fi
	printf 'pending[%d]:\n' "${#PENDING[@]}"
	printf '  %s\n' "${PENDING[@]}"
	return 0
}

# --- status ----------------------------------------------------------------

if [ "$MODE" = status ]; then
	print_header
	print_findings
	print_item_table
	exit 0
fi

# --- plan ------------------------------------------------------------------

if [ "$MODE" = plan ]; then
	print_header
	print_findings
	print_item_table
	print_pending
	if [ "$ADMIN" = true ] && [ ${#PENDING[@]} -gt 0 ]; then
		printf 'help: run `bash %s --apply --accept` to take the recommended set\n' "${SELF/#$HOME/\~}"
	fi
	exit 0
fi

# --- apply -----------------------------------------------------------------

if [ "$ADMIN" != true ]; then
	printf 'error: no admin permission on %s\n' "$REPO"
	printf 'cause: changing repo settings, rulesets and security features all require it\n'
	printf 'help: ask an owner to grant admin, then re-run — `--plan` still reports read-only\n'
	exit 1
fi

if wanted ruleset && [ -n "$FOREIGN_OVERLAP" ] && [ "$FORCE" != true ]; then
	printf 'error: %s already governs %s and this skill did not write it\n' "$FOREIGN_OVERLAP" "$DEFAULT_BRANCH"
	printf 'repo: %s\n' "$REPO"
	printf 'cause: two overlapping rulesets both enforce, so adding one silently tightens the branch\n'
	printf 'help: review it, then re-run with --force to add %s alongside it, or drop ruleset from --items\n' "$RULESET_NAME"
	exit 1
fi

compute_pending
if [ ${#PENDING[@]} -eq 0 ]; then
	print_header
	print_findings
	print_item_table
	printf 'applied: 0 changes — already converged (no-op)\n'
	exit 0
fi

# One PATCH carries every repos/{owner}/{repo} field that changed.
PATCH_BODY='{}'
patch_set() { PATCH_BODY=$(jq -c --argjson v "$2" ". + {\"$1\": \$v}" <<<"$PATCH_BODY"); }

for id in "${PENDING[@]}"; do
	case "$id" in
	delete-branch-on-merge) patch_set delete_branch_on_merge true ;;
	auto-merge) patch_set allow_auto_merge true ;;
	update-branch) patch_set allow_update_branch true ;;
	squash-only)
		patch_set allow_squash_merge true
		patch_set allow_merge_commit false
		patch_set allow_rebase_merge false
		;;
	esac
done

FAILED=()

if [ "$PATCH_BODY" != '{}' ]; then
	printf 'patching repo settings...\n' >&2
	"$GH" api -X PATCH "repos/$REPO" --input - <<<"$PATCH_BODY" >/dev/null 2>&1 ||
		FAILED+=("repo-settings")
fi

# Alerts must exist before Dependabot can open a fix PR for them.
for id in "${PENDING[@]}"; do
	case "$id" in
	dependabot-alerts)
		printf 'enabling dependabot alerts...\n' >&2
		"$GH" api -X PUT "repos/$REPO/vulnerability-alerts" >/dev/null 2>&1 ||
			FAILED+=("dependabot-alerts")
		;;
	esac
done
for id in "${PENDING[@]}"; do
	case "$id" in
	dependabot-security-updates)
		printf 'enabling dependabot security updates...\n' >&2
		"$GH" api -X PUT "repos/$REPO/automated-security-fixes" >/dev/null 2>&1 ||
			FAILED+=("dependabot-security-updates")
		;;
	esac
done

# Push protection has no meaning without scanning, and GitHub rejects the pair
# in one call on a repo where scanning is still off — so try both together and
# fall back to two ordered calls.
SEC_BODY='{}'
for id in "${PENDING[@]}"; do
	case "$id" in
	secret-scanning) SEC_BODY=$(jq -c '.secret_scanning = {status:"enabled"}' <<<"$SEC_BODY") ;;
	push-protection) SEC_BODY=$(jq -c '.secret_scanning_push_protection = {status:"enabled"}' <<<"$SEC_BODY") ;;
	esac
done
if [ "$SEC_BODY" != '{}' ]; then
	printf 'enabling secret scanning...\n' >&2
	send_sec() {
		"$GH" api -X PATCH "repos/$REPO" --input - \
			<<<"$(jq -cn --argjson s "$1" '{security_and_analysis: $s}')" >/dev/null 2>&1
	}
	if ! send_sec "$SEC_BODY"; then
		OK=true
		SCAN_ONLY=$(jq -c 'del(.secret_scanning_push_protection)' <<<"$SEC_BODY")
		PUSH_ONLY=$(jq -c 'del(.secret_scanning)' <<<"$SEC_BODY")
		[ "$SCAN_ONLY" != '{}' ] && { send_sec "$SCAN_ONLY" || OK=false; }
		[ "$PUSH_ONLY" != '{}' ] && { send_sec "$PUSH_ONLY" || OK=false; }
		[ "$OK" = true ] || FAILED+=("secret-scanning")
	fi
fi

for id in "${PENDING[@]}"; do
	case "$id" in
	ruleset)
		RS_BODY=$(jq -cn --arg name "$RULESET_NAME" --argjson rules "$RULESET_RULES" '{
			name: $name,
			target: "branch",
			enforcement: "active",
			conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
			rules: $rules,
			bypass_actors: []
		}')
		if [ -n "$RULESET_ID" ]; then
			printf 'converging ruleset %s...\n' "$RULESET_NAME" >&2
			"$GH" api -X PUT "repos/$REPO/rulesets/$RULESET_ID" --input - <<<"$RS_BODY" >/dev/null 2>&1 ||
				FAILED+=("ruleset")
		else
			printf 'creating ruleset %s...\n' "$RULESET_NAME" >&2
			"$GH" api -X POST "repos/$REPO/rulesets" --input - <<<"$RS_BODY" >/dev/null 2>&1 ||
				FAILED+=("ruleset")
		fi
		;;
	esac
done

# --- report the achieved state, re-read rather than assumed ----------------

printf 're-reading %s...\n' "$REPO" >&2
ACHIEVED=$("$GH" api "repos/$REPO" 2>/dev/null) || ACHIEVED='{}'
a() { jq -r "$1" <<<"$ACHIEVED" 2>/dev/null; }

print_header
print_findings

# Built as an array so the count cannot drift from the contents. It did: the
# header was a hardcoded 7 and there was no row for automated-security-fixes or
# for the squash-only fields — and since an item with no row can never be
# reported as not having reached its target, applying them was unverifiable.
ROWS=()
ROWS+=("  delete_branch_on_merge,$(a '.delete_branch_on_merge // false')")
ROWS+=("  allow_auto_merge,$(a '.allow_auto_merge // false')")
ROWS+=("  allow_update_branch,$(a '.allow_update_branch // false')")
# squash-only is a conjunction of three fields, so one row cannot express which
# part of it failed.
ROWS+=("  allow_squash_merge,$(a '.allow_squash_merge // false')")
ROWS+=("  allow_merge_commit,$(a '.allow_merge_commit // false')")
ROWS+=("  allow_rebase_merge,$(a '.allow_rebase_merge // false')")
ROWS+=("  secret_scanning,$(a '.security_and_analysis.secret_scanning.status // "unavailable"')")
ROWS+=("  secret_scanning_push_protection,$(a '.security_and_analysis.secret_scanning_push_protection.status // "unavailable"')")
if "$GH" api "repos/$REPO/vulnerability-alerts" --silent >/dev/null 2>&1; then
	ROWS+=("  vulnerability_alerts,enabled")
else
	ROWS+=("  vulnerability_alerts,disabled")
fi
if FIX_AFTER=$("$GH" api "repos/$REPO/automated-security-fixes" 2>/dev/null) &&
	[ "$(jq -r '.enabled // false' <<<"$FIX_AFTER" 2>/dev/null)" = true ]; then
	ROWS+=("  automated_security_fixes,enabled")
else
	ROWS+=("  automated_security_fixes,disabled")
fi
# Re-run the probe's own comparison rather than counting by name: a ruleset
# whose rules were changed out from under us keeps its name and would otherwise
# verify as present.
ruleset_probe
ROWS+=("  ruleset_$RULESET_NAME,$RULESET_STATE")

printf 'achieved[%d]{setting,value}:\n' "${#ROWS[@]}"
printf '%s\n' "${ROWS[@]}"

if [ ${#FAILED[@]} -gt 0 ]; then
	printf 'error: could not converge: %s\n' "${FAILED[*]}"
	printf 'repo: %s\n' "$REPO"
	printf 'cause: the API rejected the change — the achieved table above shows what did land\n'
	printf 'help: check `gh auth status` lists `repo` scope, then re-run --apply for the rest\n'
	exit 1
fi

printf 'applied: %d item(s) — %s\n' "${#PENDING[@]}" "${PENDING[*]}"
printf 'note: these settings live on GitHub, not in the repo, so there is nothing to commit\n'
exit 0
