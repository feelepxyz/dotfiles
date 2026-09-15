#!/usr/bin/env bash
# Exercise setup in disposable homes; never install packages or remote skills.
# Follows skills/test/run.sh: named cases, --only, --bash, --keep, and a summary.
# shellcheck disable=SC2016 # Shell snippets are interpreted in fixture processes.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
BASH_BIN=$BASH
ONLY=""
KEEP=false
while [ $# -gt 0 ]; do
	case "$1" in
	--bash | --only)
		[ $# -ge 2 ] || { printf '%s needs a value\n' "$1" >&2; exit 2; }
		case "$1" in
		--bash) BASH_BIN=$(command -v "$2") || exit 2 ;;
		--only) ONLY=$2 ;;
		esac
		shift 2
		;;
	--keep) KEEP=true; shift ;;
	-h | --help)
		echo "usage: bash script/test-setup.sh [--only name] [--bash path] [--keep]"
		exit 0 ;;
	*) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
	esac
done

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles test.XXXXXX") || exit 1
trap 'if $KEEP; then printf "fixtures: %s\n" "$TEST_ROOT"; else rm -rf "$TEST_ROOT"; fi' EXIT

fixture() {
	FIXTURE="$TEST_ROOT/$1"
	TEST_HOME="$FIXTURE/home"
	BIN="$FIXTURE/bin"
	CALLS="$FIXTURE/calls"
	PLATFORM=Linux
	FAIL_TOOL=""
	ENTRY="$ROOT/script/setup"
	mkdir -p "$TEST_HOME" "$BIN" "$FIXTURE/tmp" || return 1
	# Allow only setup's local utilities. Removing npx must work even on a host
	# with /usr/bin/npx, and package/skill commands must never escape the stubs.
	local tool
	for tool in dirname readlink git mktemp mkdir mv ln rm; do
		ln -s "$(command -v "$tool")" "$BIN/$tool" || return 1
	done
	ln -s "$BASH_BIN" "$BIN/bash" || return 1
	cat >"$BIN/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$TEST_PLATFORM"
EOF
	cat >"$BIN/tool" <<'EOF'
#!/usr/bin/env bash
name=${0##*/}
printf '%s' "$name" >>"$CALLS"
if [ "$#" -gt 0 ]; then printf ' <%s>' "$@" >>"$CALLS"; fi
printf '\n' >>"$CALLS"
if [ "$name" = "$FAIL_TOOL" ]; then exit 1; fi
# Model a CLI that consumes stdin: skill restoration must keep reading its
# manifest on a separate descriptor.
if [ "$name" = npx ]; then
  case "$4" in
    /*) ;;
    *) git ls-remote --get-url "https://github.com/$4" >>"$CALLS.urls" || exit 1 ;;
  esac
  while IFS= read -r _; do :; done
fi
EOF
	chmod +x "$BIN/uname" "$BIN/tool" || return 1
	for tool in brew omarchy npx; do
		ln -s tool "$BIN/$tool" || return 1
	done
}

DIAG=""
check() {
	"$@" && return 0
	printf -v DIAG '%q ' "$@"
	DIAG="failed: $DIAG"
	return 1
}

# First argument is the expected exit status; remaining arguments go to setup.
setup() {
	local expected=$1 status=0
	shift
	(cd "$FIXTURE" && env -i HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_HOME/.config" \
		PATH="$BIN" TMPDIR="$FIXTURE/tmp" CALLS="$CALLS" TEST_PLATFORM="$PLATFORM" FAIL_TOOL="$FAIL_TOOL" \
		GIT_CONFIG_NOSYSTEM=1 "$BASH_BIN" "$ENTRY" "$@") >"$FIXTURE/setup.log" 2>&1 || status=$?
	check [ "$status" -eq "$expected" ]
}

case_links-backups-and-rerun() {
	printf '# original\n' >"$TEST_HOME/.gitconfig"
	ln -s missing-target "$TEST_HOME/.vimrc" || return 1
	mkdir -p "$TEST_HOME/.config/nvim" "$TEST_HOME/.pi/agent/extensions" "$TEST_HOME/.claude" || return 1
	printf '%s\n' '-- original editor' >"$TEST_HOME/.config/nvim/init.lua"
	printf '// original extension\n' >"$TEST_HOME/.pi/agent/extensions/local.ts"
	printf 'preserve me\n' >"$TEST_HOME/.claude/credentials.json"
	setup 0 --skip-skills || return 1

	local relative backup backups
	for relative in .gitconfig .zsh/config .config/ghostty/config .config/herdr/config.toml \
		.config/ripgrep/config .pi/agent/AGENTS.md .config/nvim .pi/agent/extensions; do
		check [ "$(readlink "$TEST_HOME/$relative")" = "$ROOT/home/$relative" ] || return 1
	done
	check [ ! -e "$TEST_HOME/.Brewfile" ] || return 1
	check [ ! -L "$TEST_HOME/.Brewfile" ] || return 1
	check [ ! -e "$TEST_HOME/.tool-versions" ] || return 1
	check [ ! -L "$TEST_HOME/.tool-versions" ] || return 1
	check [ "$(readlink "$TEST_HOME/.local/bin/wta")" = "$ROOT/home/.bin/wta" ] || return 1
	check [ "$(cat "$TEST_HOME/.claude/credentials.json")" = 'preserve me' ] || return 1
	backups=("$TEST_HOME"/.dotfiles-backup.*)
	check [ "${#backups[@]}" -eq 1 ] || return 1
	backup=${backups[0]}
	check [ "$(cat "$backup/.gitconfig")" = '# original' ] || return 1
	check [ "$(readlink "$backup/.vimrc")" = missing-target ] || return 1
	check [ "$(cat "$backup/.config/nvim/init.lua")" = '-- original editor' ] || return 1
	check [ "$(cat "$backup/.pi/agent/extensions/local.ts")" = '// original extension' ] || return 1
	setup 0 --skip-skills || return 1
	check [ "$(cat "$FIXTURE/setup.log")" = 'Dotfiles installed (linux).' ] || return 1
	backups=("$TEST_HOME"/.dotfiles-backup.*)
	check [ "${#backups[@]}" -eq 1 ] || return 1
	check [ "${backups[0]}" = "$backup" ] || return 1
	check [ -z "$(ls -A "$FIXTURE/tmp")" ] || return 1
	check [ ! -e "$CALLS" ]
}

case_public-skills-use-https() {
	setup 0 --skip-skills || return 1
	awk 'NF && $1 !~ /^#/ { print "https://github.com/" $1 }' \
		"$ROOT/skills/manifest.txt" >"$FIXTURE/expected-urls"
	# Setup reruns and standalone skill restoration keep public sources on HTTPS.
	for ENTRY in "$ROOT/script/setup" "$ROOT/install/skills.sh"; do
		: >"$CALLS.urls"
		setup 0 || return 1
		check cmp "$FIXTURE/expected-urls" "$CALLS.urls" || return 1
	done
}

case_retired-attributes-link() {
	ln -s "$ROOT/home/.gitattributes" "$TEST_HOME/.gitattributes" || return 1
	setup 0 --skip-skills || return 1
	check [ ! -L "$TEST_HOME/.gitattributes" ] || return 1
	printf '*.rb diff=ruby\n' >"$TEST_HOME/.gitattributes"
	setup 0 --skip-skills || return 1
	check [ "$(cat "$TEST_HOME/.gitattributes")" = '*.rb diff=ruby' ]
}

case_failed-file-list-stops-before-installing() {
	rm "$BIN/git" || return 1
	cat >"$BIN/git" <<'EOF'
#!/usr/bin/env bash
# Even a partial file list must not be installed when Git exits unsuccessfully.
printf 'home/.gitconfig\0'
printf 'fixture: git index unavailable\n' >&2
exit 128
EOF
	chmod +x "$BIN/git" || return 1
	setup 128 --packages || return 1
	check grep -qF 'fixture: git index unavailable' "$FIXTURE/setup.log" || return 1
	check [ -z "$(ls -A "$TEST_HOME")" ] || return 1
	check [ -z "$(ls -A "$FIXTURE/tmp")" ] || return 1
	check [ ! -e "$CALLS" ]
}

case_platform-packages-and-skills() {
	local platform signing_program actual expected
	for platform in Linux Darwin; do
		fixture "packages-$platform" || return 1
		PLATFORM=$platform
		setup 0 --packages || return 1
		if [ "$platform" = Linux ]; then
			signing_program=/opt/1Password/op-ssh-sign
			check grep -q '^omarchy <pkg> <add>.*<ghostty>.*<github-cli>.*<zsh>' "$CALLS" || return 1
			check grep -q '^omarchy <pkg> <aur> <add>' "$CALLS" || return 1
		else
			signing_program=/Applications/1Password.app/Contents/MacOS/op-ssh-sign
			check grep -q '^brew <bundle> <check>' "$CALLS" || return 1
			check [ -L "$TEST_HOME/.Brewfile" ] || return 1
			check [ -L "$TEST_HOME/.tool-versions" ] || return 1
		fi
		expected=$(awk 'NF && $1 !~ /^#/ { n++ } END { print n + 1 }' "$ROOT/skills/manifest.txt")
		actual=$(grep -c '^npx <--yes> <skills@latest> <add>' "$CALLS")
		check [ "$actual" -eq "$expected" ] || return 1
		check [ "$(tail -n 1 "$CALLS")" = "npx <--yes> <skills@latest> <add> <$ROOT/skills/custom> <-g> <-s> <*> <-a> <claude-code> <codex> <pi> <antigravity-cli> <-y>" ] || return 1
		actual=$(env -i HOME="$TEST_HOME" PATH="$BIN" GIT_CONFIG_NOSYSTEM=1 \
			git config --includes --global gpg.ssh.program) || return 1
		check [ "$actual" = "$signing_program" ] || return 1
	done
}

case_failed-installs-stop-before-linking() {
	local tool
	for tool in omarchy npx; do
		fixture "failed-$tool" || return 1
		FAIL_TOOL=$tool
		setup 1 --packages || return 1
		check [ -z "$(ls -A "$TEST_HOME")" ] || return 1
	done
}

case_missing-npx-can-be-skipped() {
	rm "$BIN/npx" || return 1
	setup 1 || return 1
	check grep -qF 'Node.js/npm' "$FIXTURE/setup.log" || return 1
	check [ -z "$(ls -A "$TEST_HOME")" ] || return 1
	setup 0 --skip-skills
}

case_symlink-entrypoint-and-cli-errors() {
	# Resolve a relative symlink through another symlink, from outside the repo.
	ln -s "$ROOT/script/setup" "$FIXTURE/setup-target" || return 1
	ln -s setup-target "$FIXTURE/setup link" || return 1
	ENTRY="$FIXTURE/setup link"
	setup 0 --skip-skills || return 1
	check [ -L "$TEST_HOME/.gitconfig" ] || return 1
	setup 0 --help || return 1
	check grep -q 'usage:' "$FIXTURE/setup.log" || return 1
	setup 2 --unknown || return 1
	PLATFORM=Other
	setup 1 --skip-skills
}

case_shared-agent-json-is-valid() {
	check jq empty "$ROOT/home/.codex/hooks.json" "$ROOT/home/.claude/settings.json"
}

case_zsh-mkcd() {
	local output
	output=$(env -i HOME="$TEST_HOME" PATH="$BIN" DOTFILES="$ROOT" \
		"$(command -v zsh)" -f -c '
			source "$DOTFILES/home/.zsh/scripts"
			mkcd >/dev/null 2>&1
			[[ $? -ne 0 ]] || exit 1
			print survived
			mkcd "$HOME/directory with spaces" || exit 1
			[[ "$PWD" == "$HOME/directory with spaces" ]] || exit 1
			mkcd "$HOME/directory with spaces" || exit 1
			print entered
		') || return 1
	check [ "$output" = $'survived\nentered' ]
}

case_zsh-clone-failure() {
	check env -i HOME="$TEST_HOME" PATH="$BIN" DOTFILES="$ROOT" \
		"$(command -v zsh)" -f -c '
			source "$DOTFILES/home/.zsh/scripts"
			builtin cd "$HOME" || exit 1
			git() { return 42; }
			gh-clone https://github.com/example/repo.git >/dev/null 2>&1
			[[ $? -eq 42 && "$PWD" == "$HOME" ]]
		'
}

case_zsh-clone-destination() {
	check env -i HOME="$TEST_HOME" PATH="$BIN" DOTFILES="$ROOT" \
		"$(command -v zsh)" -f -c '
			source "$DOTFILES/home/.zsh/scripts"
			git() { mkdir -p -- "${@[-1]}"; }
			gh-clone https://github.com/example/project.github.git || exit 1
			[[ "$PWD" == "$HOME/src/github.com/example/project.github" ]] || exit 1
			gh-clone git@github.com:example/ssh-repo.git || exit 1
			[[ "$PWD" == "$HOME/src/github.com/example/ssh-repo" ]] || exit 1
			gh-clone https://github.com/../../outside >/dev/null 2>&1
			[[ $? -ne 0 && "$PWD" == "$HOME/src/github.com/example/ssh-repo" ]]
		'
}

case_zsh-startup() {
	setup 0 --skip-skills || return 1
	# Environment managers can restore PATH saved by an older parent shell.
	cat >"$BIN/mise" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'path=( bin .bundle/bin node_modules/.bin $path )'
EOF
	chmod +x "$BIN/mise" || return 1
	local output
	output=$(cd "$TEST_HOME" && env -i HOME="$TEST_HOME" \
		PATH="$BIN:bin:/usr/bin:$BIN:.bundle/bin:node_modules/.bin" \
		TERM=xterm-256color DOTFILES="$ROOT" "$(command -v zsh)" -f -i -c '
			source "$DOTFILES/home/.zshrc"
			source "$DOTFILES/home/.zshrc"
			for entry in $path; do [[ "$entry" == /* ]] || exit 1; done
			typeset -a unique_path
			unique_path=( ${(u)path} )
			[[ $#path -eq $#unique_path ]] || exit 1
			for name in cat cp mv rm mkdir; do
				(( ! $+aliases[$name] )) || exit 1
			done
			(( ! $+aliases[edotfiles] && $+functions[zmv] )) || exit 1
			print ready
		' 2>&1) || { DIAG="$output"; return 1; }
	check [ "$output" = ready ]
}

case_zsh-macos-startup() {
	setup 0 --skip-skills || return 1
	local prefix="$TEST_HOME/homebrew"
	mkdir -p "$prefix/share/zsh-autosuggestions" \
		"$prefix/opt/zsh-fast-syntax-highlighting/share/zsh-fast-syntax-highlighting" || return 1
	printf '(( $+functions[compdef] )) || exit 1\nloaded_autosuggestions=1\n' \
		>"$prefix/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
	printf '[[ "$loaded_autosuggestions" == 1 ]] || exit 1\nloaded_highlighting=1\n' \
		>"$prefix/opt/zsh-fast-syntax-highlighting/share/zsh-fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh"
	check env -i HOME="$TEST_HOME" PATH="$BIN:/usr/bin" HOMEBREW_PREFIX="$prefix" \
		TERM=xterm-256color DOTFILES="$ROOT" "$(command -v zsh)" -f -i -c '
			OSTYPE=darwin
			source "$DOTFILES/home/.zshrc"
			[[ "$EDITOR" == zed && "$loaded_highlighting" == 1 ]]
		'
}

case_macos-post-setup() {
	local bootstrap="$FIXTURE/dotfiles"
	mkdir -p "$bootstrap/script" "$bootstrap/install" || return 1
	cp "$ROOT/script/strap-after-setup" "$bootstrap/script/strap-after-setup" || return 1
	ln -s "$BIN/tool" "$bootstrap/script/touchid-enable-pam-sudo" || return 1
	ln -s "$BIN/tool" "$bootstrap/install/mac.sh" || return 1
	ln -s tool "$BIN/chsh" || return 1
	check env -i HOME="$TEST_HOME" PATH="$BIN" USER=test SHELL=/bin/bash \
		CALLS="$CALLS" TEST_PLATFORM=Darwin FAIL_TOOL= \
		"$BASH_BIN" "$bootstrap/script/strap-after-setup" || return 1
	check [ "$(cat "$CALLS")" = $'touchid-enable-pam-sudo <--quiet>\nchsh <-s> </bin/zsh> <test>\nmac.sh' ]
}

case_git-force-push() {
	setup 0 --skip-skills || return 1
	check env -i HOME="$TEST_HOME" PATH="$BIN" GIT_CONFIG_NOSYSTEM=1 \
		GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
		"$BASH_BIN" -e -c '
			git init --bare "$HOME/remote.git"
			git clone "$HOME/remote.git" "$HOME/work"
			cd "$HOME/work"
			git commit --allow-empty -m initial
			git push -u origin HEAD
			git commit --amend --allow-empty -m amended
			git pushf
			git clone "$HOME/remote.git" "$HOME/other"
			git -C "$HOME/other" commit --allow-empty -m remote-change
			git -C "$HOME/other" push
			git commit --amend --allow-empty -m amended-again
			if git pushf; then exit 1; fi
			git branch -m renamed
			if git push; then exit 1; fi
		' >"$FIXTURE/git.log" 2>&1 || { cat "$FIXTURE/git.log"; return 1; }
}

PASS=0
FAIL=0
ROWS=()
shopt -s nullglob
run_case() {
	local name=$1
	case "$name" in *"$ONLY"*) ;; *) return 0 ;; esac
	DIAG=""
	if fixture "$name" && "case_$name"; then
		ROWS+=("  $name,pass")
		PASS=$((PASS + 1))
	else
		ROWS+=("  $name,FAIL" "    ^ $DIAG")
		FAIL=$((FAIL + 1))
		[ ! -f "$FIXTURE/setup.log" ] || cat "$FIXTURE/setup.log" >&2
	fi
}

run_case links-backups-and-rerun
run_case public-skills-use-https
run_case retired-attributes-link
run_case failed-file-list-stops-before-installing
run_case platform-packages-and-skills
run_case failed-installs-stop-before-linking
run_case missing-npx-can-be-skipped
run_case symlink-entrypoint-and-cli-errors
run_case shared-agent-json-is-valid
run_case zsh-mkcd
run_case zsh-clone-failure
run_case zsh-clone-destination
run_case zsh-startup
run_case zsh-macos-startup
run_case macos-post-setup
run_case git-force-push

# shellcheck disable=SC2016 # Expanded by the Bash under test.
printf 'bash: %s (%s)\n' "$BASH_BIN" "$("$BASH_BIN" -c 'printf %s "$BASH_VERSION"')"
printf 'cases[%d]{name,result}:\n' $((PASS + FAIL))
printf '%s\n' "${ROWS[@]:-}"
printf 'passed: %d\nfailed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
