#!/usr/bin/env bash
# A canned `gh` for testing setup-github offline.
#
#   dir=$(bash ghshim.sh --install)
#   PATH="$dir:$PATH" bash setup-github.sh --apply --items=…
#   rm -rf "$dir"
#
# setup-github reaches GitHub only through the `$GH` it resolves from PATH, so a
# shim earlier on PATH intercepts everything with no network and no real repo.
# State lives in files under the shim directory, which is what lets an --apply
# write and the verification step read the result back.
set -euo pipefail

if [ "${1:-}" = "--install" ]; then
	dir=$(mktemp -d "${TMPDIR:-/tmp}/gh-shim.XXXXXX")
	cp "${BASH_SOURCE[0]}" "$dir/_ghshim.sh"
	cat >"$dir/gh" <<EOF
#!/usr/bin/env bash
GH_SHIM_STATE="$dir" exec bash "$dir/_ghshim.sh" "\$@"
EOF
	chmod +x "$dir/gh"
	# Start from a repo with every setting off and no rulesets, so an --apply has
	# something pending to do — the script exits before the achieved table when
	# nothing is pending.
	cat >"$dir/repo.json" <<'EOF'
{
  "nameWithOwner": "acme/widget",
  "private": true,
  "default_branch": "main",
  "permissions": { "admin": true },
  "delete_branch_on_merge": false,
  "allow_auto_merge": false,
  "allow_update_branch": false,
  "allow_squash_merge": true,
  "allow_merge_commit": true,
  "allow_rebase_merge": true
}
EOF
	printf '[]\n' >"$dir/rulesets.json"
	printf 'false\n' >"$dir/alerts"
	printf 'false\n' >"$dir/fixes"
	printf '%s\n' "$dir"
	exit 0
fi

S=${GH_SHIM_STATE:?ghshim: GH_SHIM_STATE unset}

# Merge a JSON object into repo.json — how a real PATCH behaves.
patch_repo() {
	local body
	body=$(cat)
	jq -s '.[0] * .[1]' "$S/repo.json" <(printf '%s' "$body") >"$S/repo.json.new" &&
		mv "$S/repo.json.new" "$S/repo.json"
}

case "${1:-}" in
auth) exit 0 ;;
repo)
	jq -r '.nameWithOwner' "$S/repo.json"
	exit 0
	;;
api) ;;
*) exit 1 ;;
esac
shift

METHOD=GET
INPUT=""
ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
	-X)
		METHOD=$2
		shift 2
		;;
	--input)
		INPUT=$2
		shift 2
		;;
	--silent | -q)
		shift
		;;
	*)
		ARGS+=("$1")
		shift
		;;
	esac
done
EP=${ARGS[0]:-}

# Most specific first: `repos/*` would otherwise swallow every sub-resource.
case "$METHOD:$EP" in
GET:repos/*/rulesets/*) jq -r '.[0]' "$S/rulesets.json" ;;
GET:repos/*/rulesets) cat "$S/rulesets.json" ;;
GET:repos/*/vulnerability-alerts) [ "$(cat "$S/alerts")" = true ] ;;
GET:repos/*/automated-security-fixes) printf '{"enabled":%s,"paused":false}\n' "$(cat "$S/fixes")" ;;
GET:repos/*/branches/*/protection) exit 1 ;;
PUT:repos/*/vulnerability-alerts) printf 'true\n' >"$S/alerts" ;;
PUT:repos/*/automated-security-fixes) printf 'true\n' >"$S/fixes" ;;
POST:repos/*/rulesets | PUT:repos/*/rulesets/*)
	# Record what was asked for, so the verification reads back a real ruleset
	# rather than a hardcoded success.
	[ "$INPUT" = "-" ] && cat | jq '[. + {id: 1}]' >"$S/rulesets.json"
	;;
PATCH:repos/*)
	[ "$INPUT" = "-" ] && patch_repo
	;;
GET:repos/*) cat "$S/repo.json" ;;
*) exit 1 ;;
esac
exit 0
