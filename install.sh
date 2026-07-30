#!/usr/bin/env bash
# shellcheck shell=bash
#
# install.sh - install the DomainSaver /domain-lookup skill for Claude Code.
#
#     ./install.sh              # symlink the toolkit into ~/.claude/skills
#     ./install.sh --copy       # copy it instead (for a machine without the repo)
#     ./install.sh --uninstall  # remove it again
#
# WHAT IT INSTALLS
#   <skills-dir>/domain-lookup/
#     SKILL.md      the skill definition the agent reads
#     scripts/      bootstrap.sh, generate.sh, check.sh, sweep.sh, quote.sh, lib.sh
#     wordlists/    curated candidate wordlists
#     data/         the derived caches (created by bootstrap.sh if absent)
#
#   SYMLINK MODE (default) links each of those to this checkout, so `git pull`
#   updates the installed skill and the caches in data/ are shared with the
#   repo. COPY MODE takes a snapshot, which survives the checkout being moved
#   or deleted but has to be re-installed to update.
#
# DESIGN CONSTRAINTS (same as the rest of the toolkit, deliberate):
#   * bash 3.2 compatible - no associative arrays, no `declare -A`, no readarray.
#   * POSIX-ish tools only, no GNU-only flags, never `sed -i`.
#   * Idempotent, and never destructive by surprise: an existing installation is
#     only replaced with --force, and --uninstall refuses to delete a directory
#     it cannot prove it created.
#   * No credentials are read, written or needed. PORKBUN_API_KEY /
#     PORKBUN_SECRET_KEY stay in your shell, and only quote.sh ever reads them.

set -euo pipefail

IN_VERSION="1.0.0"
IN_SKILL_NAME="domain-lookup"
IN_MARKER=".domainsaver-install"

# Everything installed, in order. Missing optional items are skipped with a
# note rather than failing the install.
IN_REQUIRED_ITEMS="SKILL.md scripts"
IN_OPTIONAL_ITEMS="wordlists data README.md LICENSE"

IN_MODE="symlink" # symlink | copy
IN_ACTION="install"
IN_FORCE=0
IN_DRYRUN=0
IN_QUIET=0
IN_SKILLS_DIR=""

# ---------------------------------------------------------------------------
# SECTION 1: output helpers
# ---------------------------------------------------------------------------

_in_say() {
	[ "$IN_QUIET" = "1" ] && return 0
	printf '%s\n' "$*"
	return 0
}

_in_warn() {
	printf 'WARN: %s\n' "$*" >&2
	return 0
}

_in_die() {
	printf 'FATAL: %s\n' "$*" >&2
	exit 1
}

# _in_run <description> <command...>
#   Runs a command, or prints it under --dry-run. Every filesystem mutation in
#   this script goes through here, so --dry-run is genuinely side-effect free.
_in_run() {
	_inr_what="$1"
	shift
	if [ "$IN_DRYRUN" = "1" ]; then
		printf 'would %s\n' "$_inr_what"
		return 0
	fi
	"$@" || _in_die "failed to $_inr_what"
	unset _inr_what
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 2: usage
# ---------------------------------------------------------------------------

_in_usage() {
	cat <<EOF
install.sh $IN_VERSION - install the DomainSaver "/$IN_SKILL_NAME" skill

USAGE
  ./install.sh [options]
  ./install.sh --uninstall [options]

OPTIONS
      --copy           copy the toolkit instead of symlinking it. Use this when
                       the checkout will be moved or deleted; you must re-run
                       install.sh to pick up later changes.
      --symlink        link to this checkout (the default): 'git pull' updates
                       the installed skill, and data/ caches are shared.
      --uninstall      remove an installed skill and exit.
  -p, --prefix DIR     skills directory to install into.
                       Default: \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills
  -f, --force          replace an existing installation (or, with --uninstall,
                       remove a directory this script cannot prove it created).
  -n, --dry-run        print what would happen and change nothing.
  -q, --quiet          only warnings and errors.
  -h, --help           this text.
  -V, --version        print the version and exit.

AFTER INSTALLING
  1. Populate the caches (public data, no credentials needed):
         <skill-dir>/scripts/bootstrap.sh
  2. Optional but recommended - real per-name quotes, which are the only way
     the toolkit can ever say AVAILABLE rather than UNREGISTERED:
         export PORKBUN_API_KEY='pk1_...'
         export PORKBUN_SECRET_KEY='sk1_...'
     Get a key at https://porkbun.com/account/api. Keep it out of the repo.
  3. Start a new Claude Code session and ask it to find or check a domain.

EXIT STATUS
  0  installed, uninstalled, or nothing to do
  1  failure (bad path, refused overwrite, missing files)
  2  usage error
EOF
}

_in_usage_error() {
	printf 'usage error: %s\n\n' "$*" >&2
	_in_usage >&2
	exit 2
}

# ---------------------------------------------------------------------------
# SECTION 3: argument parsing
# ---------------------------------------------------------------------------

_in_parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--copy) IN_MODE="copy" ;;
		--symlink | --link) IN_MODE="symlink" ;;
		--uninstall | --remove) IN_ACTION="uninstall" ;;
		-f | --force) IN_FORCE=1 ;;
		-n | --dry-run) IN_DRYRUN=1 ;;
		-q | --quiet) IN_QUIET=1 ;;
		-p | --prefix)
			[ "$#" -ge 2 ] || _in_usage_error "--prefix needs a directory"
			shift
			IN_SKILLS_DIR="$1"
			;;
		--prefix=*) IN_SKILLS_DIR="${1#*=}" ;;
		-h | --help)
			_in_usage
			exit 0
			;;
		-V | --version)
			printf 'install.sh %s (DomainSaver)\n' "$IN_VERSION"
			exit 0
			;;
		--)
			shift
			[ "$#" -eq 0 ] || _in_usage_error "unexpected argument: $1"
			break
			;;
		-*) _in_usage_error "unknown option: $1" ;;
		*) _in_usage_error "unexpected argument: $1 (this script takes options only)" ;;
		esac
		shift
	done
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 4: paths
# ---------------------------------------------------------------------------

# _in_resolve_self_dir
#   Stdout: the absolute directory containing this script, following symlinks,
#   so `~/bin/domainsaver-install -> .../DomainSaver/install.sh` still finds the
#   real checkout.
_in_resolve_self_dir() {
	_ins_src="${BASH_SOURCE[0]:-$0}"
	while [ -h "$_ins_src" ]; do
		_ins_dir=$(cd -P "$(dirname "$_ins_src")" >/dev/null 2>&1 && pwd)
		_ins_src=$(readlink "$_ins_src")
		case "$_ins_src" in
		/*) ;;
		*) _ins_src="$_ins_dir/$_ins_src" ;;
		esac
	done
	cd -P "$(dirname "$_ins_src")" >/dev/null 2>&1 && pwd
}

# _in_skills_dir
#   Stdout: the skills directory to install into. --prefix wins, then
#   CLAUDE_CONFIG_DIR, then ~/.claude.
_in_skills_dir() {
	if [ -n "$IN_SKILLS_DIR" ]; then
		printf '%s\n' "$IN_SKILLS_DIR"
		return 0
	fi
	printf '%s/skills\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 5: checks
# ---------------------------------------------------------------------------

# _in_check_source <src>
#   Fatal unless <src> looks like a DomainSaver checkout with a usable skill.
_in_check_source() {
	_inc_src="$1"

	[ -f "$_inc_src/SKILL.md" ] ||
		_in_die "no SKILL.md beside install.sh ($_inc_src) - run this from a DomainSaver checkout"
	grep -q "^name:[ ]*$IN_SKILL_NAME" "$_inc_src/SKILL.md" ||
		_in_die "$_inc_src/SKILL.md does not declare 'name: $IN_SKILL_NAME'"
	[ -d "$_inc_src/scripts" ] ||
		_in_die "no scripts/ directory in $_inc_src - the checkout is incomplete"

	for _inc_s in lib.sh bootstrap.sh generate.sh check.sh sweep.sh quote.sh; do
		[ -f "$_inc_src/scripts/$_inc_s" ] ||
			_in_die "missing $_inc_src/scripts/$_inc_s - the checkout is incomplete"
	done

	unset _inc_src _inc_s 2>/dev/null || true
	return 0
}

# _in_check_deps
#   Warns about anything the toolkit needs at run time. Never fatal: installing
#   on a machine that has yet to `brew install jq` is entirely reasonable.
_in_check_deps() {
	_ind_missing=""
	for _ind_t in bash curl jq awk whois; do
		command -v "$_ind_t" >/dev/null 2>&1 || _ind_missing="$_ind_missing $_ind_t"
	done
	if [ -n "$_ind_missing" ]; then
		_in_warn "not on PATH:$_ind_missing"
		case "$_ind_missing" in
		*jq*) _in_warn "  jq is required by bootstrap.sh and quote.sh" ;;
		esac
		case "$_ind_missing" in
		*whois*) _in_warn "  whois is required for .io/.co/.uk and all Identity Digital TLDs" ;;
		esac
		case "$_ind_missing" in
		*curl*) _in_warn "  curl is required for every RDAP lookup" ;;
		esac
	fi
	unset _ind_missing _ind_t 2>/dev/null || true
	return 0
}

# _in_is_ours <dest>
#   Exit 0 if <dest> is an installation this script made, or is unmistakably a
#   DomainSaver skill directory. Used to refuse deleting somebody else's files.
_in_is_ours() {
	[ -e "$1/$IN_MARKER" ] && return 0
	[ -f "$1/SKILL.md" ] && grep -q "^name:[ ]*$IN_SKILL_NAME" "$1/SKILL.md" 2>/dev/null && return 0
	return 1
}

# _in_remove <dest>
#   Removes an installed skill directory (or a symlink standing in for one).
_in_remove() {
	if [ -h "$1" ]; then
		_in_run "remove symlink $1" rm -f "$1"
	else
		_in_run "remove directory $1" rm -rf "$1"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 6: install / uninstall
# ---------------------------------------------------------------------------

# _in_install_item <src> <dest> <name>
#   Installs one top-level item, symlinked or copied. An existing entry of the
#   same name is replaced (the directory itself was already cleared or is new).
_in_install_item() {
	_ini_src="$1/$3"
	_ini_dst="$2/$3"

	[ -e "$_ini_src" ] || return 1

	if [ -e "$_ini_dst" ] || [ -h "$_ini_dst" ]; then
		_in_run "replace $_ini_dst" rm -rf "$_ini_dst"
	fi

	if [ "$IN_MODE" = "copy" ]; then
		# -R (not -a, not -L): the only spelling portable across BSD and GNU cp.
		# It copies the data/ alias symlinks as symlinks, which is correct -
		# they are relative, so they keep resolving inside the snapshot.
		_in_run "copy $3 -> $_ini_dst" cp -R "$_ini_src" "$_ini_dst"
	else
		# Absolute target: the link keeps working from any cwd, and it is
		# obvious in `ls -l` where the real files live.
		_in_run "link $3 -> $_ini_dst" ln -s "$_ini_src" "$_ini_dst"
	fi

	unset _ini_src _ini_dst 2>/dev/null || true
	return 0
}

# _in_write_marker <src> <dest>
#   Records what was installed, how and from where. --uninstall trusts this
#   file, and it is the fastest way to answer "which checkout is this skill?".
_in_write_marker() {
	if [ "$IN_DRYRUN" = "1" ]; then
		printf 'would write %s/%s\n' "$2" "$IN_MARKER"
		return 0
	fi
	{
		printf '# DomainSaver skill installation marker - safe to delete.\n'
		printf '# Its presence is what lets install.sh --uninstall remove this\n'
		printf '# directory without being asked to --force.\n'
		printf 'skill=%s\n' "$IN_SKILL_NAME"
		printf 'source=%s\n' "$1"
		printf 'mode=%s\n' "$IN_MODE"
		printf 'installer=%s\n' "$IN_VERSION"
		printf 'installed=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown')"
	} >"$2/$IN_MARKER" || _in_die "cannot write $2/$IN_MARKER"
	return 0
}

_in_do_install() {
	_ind_src="$1"
	_ind_dest="$2"

	_in_check_source "$_ind_src"

	if [ -e "$_ind_dest" ] || [ -h "$_ind_dest" ]; then
		if [ "$IN_FORCE" != "1" ]; then
			printf 'FATAL: %s already exists.\n' "$_ind_dest" >&2
			if _in_is_ours "$_ind_dest"; then
				printf '       It looks like an existing DomainSaver install; re-run with --force to replace it.\n' >&2
			else
				printf '       It does NOT look like a DomainSaver install, so this script will not touch it.\n' >&2
				printf '       Move it aside, or re-run with --force if you are sure.\n' >&2
			fi
			exit 1
		fi
		_in_say "replacing existing installation at $_ind_dest"
		_in_remove "$_ind_dest"
	fi

	_in_run "create $_ind_dest" mkdir -p "$_ind_dest"

	for _ind_item in $IN_REQUIRED_ITEMS; do
		_in_install_item "$_ind_src" "$_ind_dest" "$_ind_item" ||
			_in_die "required item missing from the checkout: $_ind_item"
	done
	for _ind_item in $IN_OPTIONAL_ITEMS; do
		if [ -e "$_ind_src/$_ind_item" ]; then
			_in_install_item "$_ind_src" "$_ind_dest" "$_ind_item" || true
		fi
	done

	_in_write_marker "$_ind_src" "$_ind_dest"

	# The scripts are run directly by the agent, so make sure they are runnable
	# even from a checkout that lost its permission bits (a zip download will).
	if [ "$IN_MODE" = "copy" ] && [ "$IN_DRYRUN" != "1" ]; then
		chmod 0755 "$_ind_dest"/scripts/*.sh 2>/dev/null || true
	fi

	_in_check_deps

	_in_say ""
	_in_say "installed: $_ind_dest"
	_in_say "  mode:    $IN_MODE ($( [ "$IN_MODE" = symlink ] && printf 'tracks %s' "$_ind_src" || printf 'snapshot of %s' "$_ind_src" ))"
	_in_say "  skill:   /$IN_SKILL_NAME"
	_in_say ""
	_in_say "Next steps:"
	_in_say "  1. $_ind_dest/scripts/bootstrap.sh"
	_in_say "       downloads the IANA RDAP map and the public Porkbun price list."
	_in_say "       No credentials needed."
	_in_say "  2. optional, for real per-name quotes (the only way to get a verdict"
	_in_say "     of AVAILABLE instead of UNREGISTERED):"
	_in_say "       export PORKBUN_API_KEY='pk1_...'"
	_in_say "       export PORKBUN_SECRET_KEY='sk1_...'"
	_in_say "       key: https://porkbun.com/account/api  (never commit it)"
	_in_say "  3. start a new Claude Code session and ask it to find or check a domain."
	if [ "$IN_MODE" = "symlink" ]; then
		_in_say ""
		_in_say "Note: this install points at $_ind_src."
		_in_say "      Moving or deleting that checkout breaks the skill; re-run"
		_in_say "      install.sh --copy --force if you want a standalone snapshot."
	fi

	unset _ind_src _ind_dest _ind_item 2>/dev/null || true
	return 0
}

_in_do_uninstall() {
	_inu_dest="$1"

	if [ ! -e "$_inu_dest" ] && [ ! -h "$_inu_dest" ]; then
		_in_say "nothing to do: $_inu_dest does not exist"
		return 0
	fi

	if ! _in_is_ours "$_inu_dest" && [ "$IN_FORCE" != "1" ]; then
		printf 'FATAL: %s is not recognisably a DomainSaver install\n' "$_inu_dest" >&2
		printf '       (no %s marker and no matching SKILL.md).\n' "$IN_MARKER" >&2
		printf '       Refusing to delete it. Re-run with --force if you are sure.\n' >&2
		exit 1
	fi

	_in_remove "$_inu_dest"
	_in_say "removed: $_inu_dest"
	_in_say "note: caches in the original checkout's data/ were not touched."
	unset _inu_dest
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 7: main
# ---------------------------------------------------------------------------

main() {
	_in_parse_args "$@"

	IN_SRC=$(_in_resolve_self_dir) || _in_die "cannot resolve the directory of this script"
	IN_SKILLS=$(_in_skills_dir)
	IN_DEST="$IN_SKILLS/$IN_SKILL_NAME"

	[ "$IN_DRYRUN" = "1" ] && _in_say "dry run: nothing will be changed"

	case "$IN_ACTION" in
	uninstall)
		_in_do_uninstall "$IN_DEST"
		;;
	install)
		_in_say "installing the /$IN_SKILL_NAME skill"
		_in_say "  from: $IN_SRC"
		_in_say "  to:   $IN_DEST"
		if [ ! -d "$IN_SKILLS" ]; then
			_in_run "create $IN_SKILLS" mkdir -p "$IN_SKILLS"
		fi
		[ -w "$IN_SKILLS" ] || [ "$IN_DRYRUN" = "1" ] ||
			_in_die "$IN_SKILLS is not writable"
		_in_do_install "$IN_SRC" "$IN_DEST"
		;;
	esac
	return 0
}

main "$@"

# End of install.sh
