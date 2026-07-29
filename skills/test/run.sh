#!/usr/bin/env bash
# Assertion runner for the setup-* skills.
#
#   bash run.sh                      # every case, current bash
#   bash run.sh --only shim          # cases whose name contains "shim"
#   bash run.sh --bash /bin/bash     # re-run under macOS bash 3.2
#   bash run.sh --keep               # leave fixtures on disk for inspection
#
# Assertions read the skills' own machine-readable output — `key: value` lines
# and `table[N]{col,col}:` headers. That contract is the test API; asserting on
# prose would make every wording change a false failure.
#
# Cases are written to fail against the unfixed scripts. A green run means the
# defect is gone, not that the case is weak.
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILLS=${SKILLS:-$(cd "$SELF_DIR/../custom" && pwd)}
BASH_BIN=bash
ONLY=""
KEEP=false

while [ $# -gt 0 ]; do
	case "$1" in
	--bash)
		BASH_BIN=$2
		shift 2
		;;
	--only)
		ONLY=$2
		shift 2
		;;
	--keep)
		KEEP=true
		shift
		;;
	-h | --help)
		sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		printf 'run: unknown option %s\n' "$1" >&2
		exit 2
		;;
	esac
done

PASS=0
FAIL=0
ROWS=()
FIXTURES=()

fixture() {
	local f
	f=$("$BASH_BIN" "$SELF_DIR/mkfixture.sh" "$@") || return 1
	FIXTURES+=("$f")
	printf '%s' "$f"
}

sgh() { "$BASH_BIN" "$SKILLS/setup-git-hooks/setup-git-hooks.sh" "$@" 2>&1; }
swt() { "$BASH_BIN" "$SKILLS/setup-worktrunk/setup-worktrunk.sh" "$@" 2>&1; }
# The roll-up takes no flags in any case here, but keep the pass-through so a
# future case can hand it one.
# shellcheck disable=SC2120
srepo() { "$BASH_BIN" "$SKILLS/setup-repo/setup-repo.sh" "$@" 2>&1; }

DIAG=""

# Assert $1 (haystack) contains $2 (needle, fixed string).
has() {
	printf '%s' "$1" | grep -qF -- "$2" && return 0
	DIAG="expected to find: $2"
	return 1
}

# Assert $1 does NOT contain $2.
lacks() {
	printf '%s' "$1" | grep -qF -- "$2" || return 0
	DIAG="expected NOT to find: $2"
	return 1
}

# Assert $1 matches extended regex $2.
matches() {
	printf '%s' "$1" | grep -qE -- "$2" && return 0
	DIAG="expected to match: $2"
	return 1
}

run_case() {
	local name=$1
	[ -n "$ONLY" ] && case "$name" in *"$ONLY"*) ;; *) return 0 ;; esac
	DIAG=""
	if "case_$name"; then
		ROWS+=("  $name,pass")
		PASS=$((PASS + 1))
	else
		ROWS+=("  $name,FAIL")
		FAIL=$((FAIL + 1))
		[ -n "$DIAG" ] && ROWS+=("    ^ $DIAG")
	fi
	return 0
}

# --- change 1: shim ownership ----------------------------------------------

# --apply must refuse rather than delete a hook another tool installed. Uses
# pre-commit because detection always yields hooks for that stage, so the apply
# genuinely wants the slot — a stage with nothing to install never contends.
case_foreign-shim-preserved() {
	local f out
	f=$(fixture --foreign-pre-commit) || return 1
	out=$(cd "$f" && sgh --apply --accept)
	# The marker bytes must still be on disk whatever the script decided.
	grep -qF 'FIXTURE_FOREIGN_HOOK_DO_NOT_DELETE' "$f/.git/hooks/pre-commit" || {
		DIAG="foreign pre-commit was destroyed by --apply --accept"
		return 1
	}
	has "$out" "error:" || return 1
	has "$out" "--force" || return 1
}

# ...and --force must still be able to take the slot.
case_foreign-shim-force-overrides() {
	local f
	f=$(fixture --foreign-pre-commit) || return 1
	(cd "$f" && sgh --apply --accept --force >/dev/null) || return 1
	grep -q 'prek' "$f/.git/hooks/pre-commit" || {
		DIAG="--force did not install prek's shim"
		return 1
	}
}

# A foreign hook that chains to prek's shim is the healthy end state, not drift.
case_chained-shim-is-healthy() {
	local f out
	f=$(fixture --chained-pre-push --managed-prek) || return 1
	out=$(cd "$f" && sgh --status)
	has "$out" "pre-push=chained" || return 1
}

# --heal --fix must not reinstall over a foreign shim either.
case_heal-preserves-foreign-shim() {
	local f
	f=$(fixture --foreign-pre-push --managed-prek) || return 1
	(cd "$f" && sgh --heal --fix >/dev/null)
	grep -qF 'FIXTURE_FOREIGN_HOOK_DO_NOT_DELETE' "$f/.git/hooks/pre-push" || {
		DIAG="foreign pre-push was destroyed by --heal --fix"
		return 1
	}
}

# --- change 2: entry_is_dead ------------------------------------------------

# `npm --prefix <dir> run <script>` must resolve against <dir>/package.json.
# The fixture has one live entry and one genuinely dead one.
case_heal-parses-prefix-entries() {
	local f out
	f=$(fixture --managed-prek) || return 1
	out=$(cd "$f" && sgh --heal)
	lacks "$out" "dead: factory-model-lint" || return 1
	has "$out" "dead: factory-model-ghost" || return 1
}

# --- change 3: roll-up ------------------------------------------------------

# `${NEXT[@]}` unguarded aborts under bash 3.2 with set -u. It is reachable
# whenever every area lands in a state that pushes no next[] entry — copying
# setup-repo.sh somewhere with no sibling skills makes all three `unavailable`,
# which is the cheapest way to produce exactly that.
case_rollup-survives-empty-next() {
	local lonely repo out
	lonely=$(mktemp -d "${TMPDIR:-/tmp}/sgh-lonely.XXXXXX")
	FIXTURES+=("$lonely")
	cp "$SKILLS/setup-repo/setup-repo.sh" "$lonely/" || return 1
	repo=$(fixture) || return 1
	out=$(cd "$repo" && "$BASH_BIN" "$lonely/setup-repo.sh" 2>&1)
	lacks "$out" "unbound variable" || return 1
	# And no dead ends: an area that counts as unfinished must carry a step, or
	# the report says "pending: 4 of 4" with nothing to do about it.
	local pending next
	pending=$(printf '%s' "$out" | sed -n 's/^pending: \([0-9]*\) of.*/\1/p')
	next=$(printf '%s' "$out" | sed -n 's/^next\[\([0-9]*\)\].*/\1/p')
	[ -n "$pending" ] && [ "$pending" -gt 0 ] && [ "${next:-0}" -eq 0 ] && {
		DIAG="pending=$pending but next[] is empty"
		return 1
	}
	return 0
}

# A healthy worktrunk config must report a hook count, not "unknown".
case_rollup-reads-hook-count() {
	local f out
	f=$(fixture) || return 1
	(cd "$f" && swt --apply --accept >/dev/null 2>&1) || true
	# shellcheck disable=SC2119
	out=$(cd "$f" && srepo)
	lacks "$out" "hooks unknown" || return 1
}

# --- change 4: generator hygiene --------------------------------------------

# The generated config must survive the end-of-file-fixer it installs, and a
# second --apply must be a byte-for-byte no-op.
case_prek-config-ends-cleanly() {
	local f
	f=$(fixture) || return 1
	(cd "$f" && sgh --apply --accept >/dev/null) || return 1
	[ "$(tail -c2 "$f/prek.toml" | od -An -c | tr -s ' ')" != " \n \n" ] || {
		DIAG="prek.toml ends on a blank line"
		return 1
	}
	[ -n "$(tail -c1 "$f/prek.toml")" ] && {
		DIAG="prek.toml has no trailing newline"
		return 1
	}
	cp "$f/prek.toml" "$f/.first"
	(cd "$f" && sgh --apply --accept >/dev/null) || return 1
	cmp -s "$f/.first" "$f/prek.toml" || {
		DIAG="--apply --accept is not idempotent"
		return 1
	}
	return 0
}

case_wt-config-ends-cleanly() {
	local f
	f=$(fixture) || return 1
	(cd "$f" && swt --apply --accept >/dev/null 2>&1) || true
	[ -f "$f/.config/wt.toml" ] || {
		DIAG=".config/wt.toml was not written"
		return 1
	}
	[ "$(tail -c2 "$f/.config/wt.toml" | od -An -c | tr -s ' ')" != " \n \n" ] || {
		DIAG="wt.toml ends on a blank line"
		return 1
	}
	return 0
}

# --- change 5: TOML escaping ------------------------------------------------

# A regex carrying a backslash must survive into a valid config.
case_extra-regex-with-backslash() {
	local f out
	f=$(fixture --extra-json) || return 1
	out=$(cd "$f" && sgh --apply --accept --extra=extra.json)
	lacks "$out" "did not validate" || return 1
	has "$out" "wrote: prek.toml" || return 1
	command -v prek >/dev/null || return 0
	(cd "$f" && prek validate-config prek.toml >/dev/null 2>&1) || {
		DIAG="prek rejected the generated config"
		return 1
	}
}

# An `exclude` in an extra must reach the config.
case_extra-supports-exclude() {
	local f
	f=$(fixture --extra-json) || return 1
	(cd "$f" && sgh --apply --accept --extra=extra.json >/dev/null) || return 1
	grep -qF 'generated' "$f/prek.toml" || {
		DIAG="the extra's exclude never reached prek.toml"
		return 1
	}
}

# --- change 6: --extra semantics --------------------------------------------

# An extra passed but not named in an explicit selection must be a loud error,
# in both skills, rather than being silently dropped or silently forced in.
case_extra-unnamed-is-an-error() {
	local f out
	f=$(fixture --extra-json) || return 1
	out=$(cd "$f" && sgh --apply --pre-commit=shellcheck --extra=extra.json)
	has "$out" "fixture-lint" || return 1
	matches "$out" '^error:' || return 1
}

# The sibling must agree — the two used to disagree, which is the root cause.
case_extra-unnamed-is-an-error-wt() {
	local f out
	f=$(fixture) || return 1
	printf '[{"id":"sidecar","dir":".","command":"echo hi"}]\n' >"$f/panes.json"
	out=$(cd "$f" && swt --apply --panes=agent --steps=herdr --extra=panes.json)
	has "$out" "sidecar" || return 1
	matches "$out" '^error:' || return 1
}

# --- change 7: non-ASCII and spaces -----------------------------------------

# The Swedish directory must be visible to detection at all.
case_wt-sees-non-ascii-dir() {
	local f out
	f=$(fixture) || return 1
	out=$(cd "$f" && swt --plan)
	has "$out" "Affärsplan" || return 1
}

# --heal must not truncate it to "Aff" and call the pane dead.
case_wt-heal-no-ascii-truncation() {
	local f out
	f=$(fixture) || return 1
	(cd "$f" && swt --apply --accept >/dev/null 2>&1) || true
	out=$(cd "$f" && swt --heal)
	lacks "$out" "Aff/" || return 1
}

# --- change 8: sub-package hooks --------------------------------------------

# Plain --plan, with no --scan and no --extra, must find the real checks.
case_sub-package-hooks-detected() {
	local f out
	f=$(fixture) || return 1
	out=$(cd "$f" && sgh --plan)
	has "$out" "factory-model-lint" || return 1
	has "$out" "factory-model-typecheck" || return 1
	has "$out" "affarsplan-typecheck" || return 1
	has "$out" "factory-model-test" || return 1
}

# Detection and heal must agree: what --apply writes, --heal calls healthy.
case_detected-hooks-survive-heal() {
	local f out
	f=$(fixture) || return 1
	(cd "$f" && sgh --apply --accept >/dev/null) || return 1
	out=$(cd "$f" && sgh --heal)
	lacks "$out" "dead:" || return 1
}

# --- change 9: frontend fallback --------------------------------------------

# A Vite app with no `dev` script still deserves a pane. The id keeps the
# directory's own case, the way `web` does — only the accent is folded.
case_vite-without-dev-script() {
	local f out
	f=$(fixture) || return 1
	out=$(cd "$f" && swt --plan)
	matches "$out" '[Aa]ffarsplan,Aff.rsplan,npm install && npx vite' || return 1
	# and --scan must show where the inference came from
	out=$(cd "$f" && swt --scan)
	has "$out" "Affärsplan/vite.config.ts,present" || return 1
}

# --- change 10: setup-github verification -----------------------------------

sgh_github() {
	local shim=$1 repo=$2
	shift 2
	# The inner script runs in the bash under test, with the shim ahead of the
	# real gh on PATH; the quotes stay single so it expands there, not here.
	# shellcheck disable=SC2016
	PATH="$shim:$PATH" "$BASH_BIN" -c \
		'cd "$1" && shift && bash "$@"' _ "$repo" \
		"$SKILLS/setup-github/setup-github.sh" "$@" 2>&1
}

gh_fixture() {
	local d
	d=$("$BASH_BIN" "$SELF_DIR/ghshim.sh" --install) || return 1
	FIXTURES+=("$d")
	printf '%s' "$d"
}

# Every item --apply writes must appear in achieved[], or a failure to converge
# it can never be reported.
case_github-achieved-covers-applied() {
	local shim repo out
	shim=$(gh_fixture) || return 1
	repo=$(fixture) || return 1
	out=$(sgh_github "$shim" "$repo" --apply --accept)
	has "$out" "automated_security_fixes," || return 1
	has "$out" "allow_squash_merge," || return 1
	has "$out" "vulnerability_alerts," || return 1
	# The row count must match the rows, not a hardcoded literal.
	local declared actual
	declared=$(printf '%s' "$out" | sed -n 's/^achieved\[\([0-9]*\)\].*/\1/p')
	actual=$(printf '%s' "$out" | sed -n '/^achieved\[/,/^applied:/p' | grep -c '^  [a-z]')
	[ "$declared" = "$actual" ] || {
		DIAG="achieved[$declared] but $actual rows"
		return 1
	}
}

# A ruleset whose rules were changed out from under us keeps its name, so
# counting by name reports it present. It must read as drifted.
case_github-detects-drifted-ruleset() {
	local shim repo out
	shim=$(gh_fixture) || return 1
	repo=$(fixture) || return 1
	printf '%s\n' '[{"id":1,"name":"default-branch-guardrails","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"deletion"}]}]' \
		>"$shim/rulesets.json"
	out=$(sgh_github "$shim" "$repo" --status)
	has "$out" "drifted" || return 1
}

# --- run --------------------------------------------------------------------

CASES=(
	foreign-shim-preserved
	foreign-shim-force-overrides
	chained-shim-is-healthy
	heal-preserves-foreign-shim
	heal-parses-prefix-entries
	rollup-survives-empty-next
	rollup-reads-hook-count
	prek-config-ends-cleanly
	wt-config-ends-cleanly
	extra-regex-with-backslash
	extra-supports-exclude
	extra-unnamed-is-an-error
	extra-unnamed-is-an-error-wt
	wt-sees-non-ascii-dir
	wt-heal-no-ascii-truncation
	sub-package-hooks-detected
	detected-hooks-survive-heal
	vite-without-dev-script
	github-achieved-covers-applied
	github-detects-drifted-ruleset
)

printf 'bin: %s\n' "${BASH_SOURCE[0]/#$HOME/\~}"
printf 'skills: %s\n' "${SKILLS/#$HOME/\~}"
# The inner expansion is deliberately unexpanded here — it has to resolve in the
# bash under test, not in this one.
# shellcheck disable=SC2016
printf 'bash: %s (%s)\n' "$BASH_BIN" "$("$BASH_BIN" -c 'printf %s "${BASH_VERSION}"')"

for c in "${CASES[@]}"; do run_case "$c"; done

printf 'cases[%d]{name,result}:\n' $((PASS + FAIL))
printf '%s\n' "${ROWS[@]}"
printf 'passed: %d\n' "$PASS"
printf 'failed: %d\n' "$FAIL"

if $KEEP; then
	printf 'fixtures[%d]:\n' "${#FIXTURES[@]}"
	printf '  %s\n' "${FIXTURES[@]}"
else
	for f in "${FIXTURES[@]:-}"; do [ -n "$f" ] && rm -rf "$f"; done
fi

[ "$FAIL" -eq 0 ]
