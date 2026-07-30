#!/usr/bin/env bash
# shellcheck shell=bash
#
# sweep.sh - DomainSaver's large-scale parallel sweep engine.
#
#     sweep.sh [options] <file-of-domains>
#     cat names.txt | sweep.sh [options] -
#
# WHAT IT IS FOR
#   Probing tens of thousands of candidate names without getting banned, and
#   without lying about the result. Two ideas do all the work:
#
#   1. WORK IS GROUPED BY REGISTRY ENDPOINT, NOT BY NAME.
#      A sweep is bounded by the slowest, angriest registry it touches. Every
#      domain is resolved to the registry that will answer for it (an RDAP base
#      URL, or a whois server) and each of those registries gets its own
#      concurrency budget from data/registry-limits.tsv. Identity Digital gets 1
#      slot, Google's pubapi gets 12, and a list full of .info can no longer
#      stall the .com work happening beside it.
#
#   2. NOTHING IS EVER SILENTLY DROPPED.
#      Exactly one output row is emitted per unique input name, in input order.
#      Blank lines, duplicates, unparseable names, unroutable TLDs, a full retry
#      queue, an interrupted run, a crashed worker - every one of those is
#      reported loudly on stderr AND materialised as an explicit ERROR row. If
#      the count of output rows ever disagrees with the count of input names,
#      that is a bug, not a truncation you were supposed to notice.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   It does not print AVAILABLE. lib.sh's probes answer UNREGISTERED /
#   REGISTERED / ERROR, and UNREGISTERED means "absent from the registry" -
#   which covers genuinely available, registry-RESERVED and PREMIUM-PRICED.
#   Measured: shed.link looked free and quoted $819.27/yr against a $7.72 list
#   price. Promoting UNREGISTERED to AVAILABLE requires a real per-name quote
#   and is the pricing layer's job, never a sweep's.
#
# OUTPUT (TSV, one row per unique input name, in input order)
#   status  domain  tld  endpoint  attempts  detail
#     status    UNREGISTERED | REGISTERED | ERROR
#     endpoint  the registry group that answered, e.g. rdap:rdap.verisign.com
#     attempts  how many probes this name cost (>1 means it was retried)
#     detail    lib.sh's probe detail, e.g. "rdap:404", "whois:whois.nic.uk"
#
# EXIT CODES
#   0    finished, every name resolved to UNREGISTERED or REGISTERED
#   1    usage error or fatal precondition (via ds_die)
#   2    finished, but at least one row is ERROR
#   130  interrupted; partial results were still written and flagged
#
# DESIGN CONSTRAINTS (same as lib.sh - deliberate, do not "modernise" away)
#   * bash 3.2. No associative arrays, no `wait -n`, no `mapfile`. Lookup
#     tables are TSV read with awk; the scheduler polls for sentinel files
#     because bash 3.2 cannot wait for "whichever child finishes first", and
#     because `kill -0` on an unreaped child is true even after it has exited.
#   * POSIX-ish tools only: awk, sort, xargs, tr, mktemp. No GNU-only flags.
#   * Every fan-out goes through `xargs -P`, which is the only portable
#     bounded-parallelism primitive available here.

set -euo pipefail

DS_SWEEP_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# SECTION 1: locate and load the shared library
# ---------------------------------------------------------------------------

_SW_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)
_SW_SELF="$_SW_DIR/$(basename "${BASH_SOURCE[0]:-$0}")"

if [ ! -r "$_SW_DIR/lib.sh" ]; then
	printf '[ds] FATAL: cannot read %s/lib.sh (sweep.sh must sit beside it)\n' "$_SW_DIR" >&2
	exit 1
fi
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$_SW_DIR/lib.sh"

# Workers are re-executions of this same file. Invoke them through the running
# bash rather than relying on the executable bit or the shebang, so a freshly
# cloned repo sweeps correctly before anyone has run chmod.
_SW_BASH="${BASH:-/bin/bash}"

# ---------------------------------------------------------------------------
# SECTION 2: defaults and tunables (all env-overridable)
# ---------------------------------------------------------------------------

: "${DS_SWEEP_PARALLEL:=16}"    # global cap on concurrent lookups
: "${DS_SWEEP_ROUNDS:=3}"       # max attempts per name, including retries
: "${DS_SWEEP_RETRY_CAP:=2000}" # max names re-queued per retry round (0 = no cap)
: "${DS_SWEEP_LIMITS:=$DS_DATA_DIR/registry-limits.tsv}"
: "${DS_SWEEP_PROGRESS_EVERY:=2}" # seconds between progress repaints

_SW_PARALLEL="$DS_SWEEP_PARALLEL"
_SW_ROUNDS="$DS_SWEEP_ROUNDS"
_SW_RETRY_CAP="$DS_SWEEP_RETRY_CAP"
_SW_LIMITS_FILE="$DS_SWEEP_LIMITS"
_SW_OUT=""
_SW_INPUT=""
_SW_HEADER=1
_SW_PROGRESS=1
_SW_FALLBACK=1
_SW_DRYRUN=0
_SW_KEEP_TEMP=0

_SW_TMPDIR=""
_SW_RAW=""
_SW_ABORT=""
_SW_INTERRUPTED=0
_SW_T0=0
_SW_LAST_PROGRESS=0
_SW_PROGRESS_OPEN=0
_SW_NAP="0.2"
_SW_LIMITS_BUILTIN=0

# Details that mean "the registry was busy/unreachable", i.e. worth retrying.
# Everything else (invalid name, unparsed whois, no endpoint) is a permanent
# ERROR and is reported as such rather than burned on pointless retries.
_SW_RETRYABLE_RE='rdap:(429|503|502|504|408|000)|rate-limited|rate limit|timeout|timed out|empty response|network'

# ---------------------------------------------------------------------------
# SECTION 3: usage
# ---------------------------------------------------------------------------

_sw_usage() {
	cat <<EOF
sweep.sh $DS_SWEEP_VERSION - DomainSaver parallel registry sweep

USAGE
  sweep.sh [options] <file-of-domains>
  cat names.txt | sweep.sh [options] -

OPTIONS
  -p, --parallel N    global cap on concurrent lookups (default $DS_SWEEP_PARALLEL)
  -o, --out FILE      write the TSV here instead of stdout (written atomically)
  -r, --rounds N      max attempts per name, including retries (default $DS_SWEEP_ROUNDS)
      --retry-cap N   max names re-queued per retry round (default $DS_SWEEP_RETRY_CAP; 0 = no cap)
  -l, --limits FILE   per-registry concurrency table
                      (default $DS_SWEEP_LIMITS)
      --no-fallback   do not fall back from RDAP to whois on the final round
      --no-header     omit the leading '# status ...' header row
      --no-progress   no progress meter on stderr
  -n, --dry-run       print the work plan (groups, limits, counts) and exit
      --explain-limit HOST [rdap|whois]
                      print the concurrency limit that would apply to HOST, and exit
      --keep-temp     keep the working directory and print its path
  -q, --quiet         suppress informational logging
  -v, --verbose       verbose tracing (DS_DEBUG=1)
  -h, --help          this text
  -V, --version       print version and exit

INPUT
  One domain per line. Blank lines and '#' comments are skipped, names are
  lowercased, CRLF and trailing dots are stripped, duplicates are collapsed -
  and every one of those adjustments is counted and reported on stderr.

OUTPUT (TSV, one row per unique input name, in input order)
  status  domain  tld  endpoint  attempts  detail

  UNREGISTERED IS NOT AVAILABLE. It means "absent from the registry", which
  also covers registry-reserved and premium-priced names. Feed the UNREGISTERED
  rows to the pricing layer before believing any of them are purchasable.

THROUGHPUT
  -p is a ceiling, not a target. Real throughput is set by the per-registry
  limits in the limits table: a sweep of nothing but .info runs at Identity
  Digital's 1 slot no matter what -p says. Use --dry-run to see the plan.

ENVIRONMENT
  DS_SWEEP_PARALLEL, DS_SWEEP_ROUNDS, DS_SWEEP_RETRY_CAP, DS_SWEEP_LIMITS
    defaults for the options above
  DS_SWEEP_PROGRESS_EVERY   seconds between progress repaints (default 2)
  DS_HTTP_TIMEOUT, DS_CONNECT_TIMEOUT, DS_WHOIS_TIMEOUT, DS_RDAP_RETRIES,
  DS_RDAP_BACKOFF_BASE, DS_RDAP_BACKOFF_MAX
    per-lookup tunables, honoured by lib.sh inside every worker
  DS_DATA_DIR, DS_QUIET, DS_DEBUG

EXAMPLES
  sweep.sh candidates.txt > swept.tsv
  sweep.sh -p 32 -o swept.tsv wordlists/three-letter.txt
  sweep.sh --dry-run candidates.txt        # what will it hit, and how hard?
  sweep.sh --explain-limit whois.nic.uk whois
  awk -F'\t' '\$1 == "UNREGISTERED" { print \$2 }' swept.tsv   # feed the pricer

EXIT CODES
  0 all names resolved   2 finished with ERROR rows
  1 usage/fatal          130 interrupted (partial results still written)
EOF
}

# ---------------------------------------------------------------------------
# SECTION 4: small helpers
# ---------------------------------------------------------------------------

# _sw_is_uint <string>
#   Internal. True if the argument is a non-negative decimal integer.
_sw_is_uint() {
	case "${1:-}" in
	'' | *[!0-9]*) return 1 ;;
	esac
	return 0
}

# _sw_nap
#   Internal. Short sleep used by the scheduler's poll loop. Sub-second sleeps
#   are not POSIX, but both BSD and GNU sleep accept them; we probe once at
#   startup and fall back to a full second if not.
_sw_nap() { sleep "$_SW_NAP" 2>/dev/null || sleep 1; }

# _sw_detect_nap
#   Internal. Decides whether fractional sleeps work, once per run.
_sw_detect_nap() {
	if ! sleep 0.05 2>/dev/null; then
		_SW_NAP="1"
		ds_debug "fractional sleep unsupported; scheduler polls once a second"
	fi
	return 0
}

# _sw_count_lines <file>
#   Internal. Line count of a file, or 0 if it does not exist. Never fails.
_sw_count_lines() {
	[ -s "${1:-}" ] || {
		printf '0\n'
		return 0
	}
	wc -l <"$1" | tr -d ' '
}

# _sw_stat <stats-file> <key>
#   Internal. Reads a "key<TAB>value" line out of a stats file; prints 0 if the
#   key is absent.
_sw_stat() {
	awk -F'\t' -v k="$2" '$1 == k { print $2; found = 1; exit } END { if (!found) print 0 }' \
		"$1" 2>/dev/null || printf '0\n'
}

# ---------------------------------------------------------------------------
# SECTION 5: per-registry concurrency limits
# ---------------------------------------------------------------------------

# _sw_builtin_limit <host> <method>
#   Internal. Cold-cache safety net, mirroring the shipped
#   data/registry-limits.tsv. Used only when the limits file is missing, so a
#   wiped data/ degrades into "cautious but still correct" rather than into
#   "hammer Identity Digital with 16 threads".
_sw_builtin_limit() {
	case "$1" in
	*identitydigital* | *afilias* | *donuts* | *rightside*) printf '1\n' ;;
	whois.iana.org) printf '1\n' ;;
	pubapi.registry.google) printf '12\n' ;;
	*.registry.google) printf '6\n' ;;
	rdap.verisign.com) printf '10\n' ;;
	whois.verisign-grs.com) printf '8\n' ;;
	rdap.nominet.uk | whois.nic.uk) printf '4\n' ;;
	rdap.publicinterestregistry.org) printf '6\n' ;;
	whois.registry.co | whois.nic.io | whois.denic.de) printf '2\n' ;;
	*)
		case "$2" in
		rdap) printf '6\n' ;;
		*) printf '2\n' ;;
		esac
		;;
	esac
}

# _sw_limit_for <host> <method>
#   Internal. Resolves the concurrency limit for a registry host, applying the
#   precedence documented in data/registry-limits.tsv: exact host beats longest
#   .suffix beats '*', and a method-scoped rule ("whois:...") outranks the
#   unscoped rule it ties with.
#   Stdout: a positive integer. Never fails - always prints something usable.
_sw_limit_for() {
	_swl_host="${1:-}"
	_swl_method="${2:-rdap}"

	if [ -n "$_SW_LIMITS_FILE" ] && [ -s "$_SW_LIMITS_FILE" ]; then
		_swl_val=$(awk -F'\t' -v host="$_swl_host" -v method="$_swl_method" '
			/^[ \t]*#/ { next }
			NF < 2     { next }
			{
				key = tolower($1)
				lim = $2 + 0
				if (lim < 1) next

				scope = ""
				pat = key
				c = index(key, ":")
				if (c > 0) { scope = substr(key, 1, c - 1); pat = substr(key, c + 1) }
				if (scope != "" && scope != method) next

				# Specificity first, method-scope only as a tiebreak.
				if (pat == "*") {
					score = 1
				} else if (substr(pat, 1, 1) == ".") {
					if (length(host) <= length(pat)) next
					if (substr(host, length(host) - length(pat) + 1) != pat) next
					score = 100 + length(pat)
				} else if (pat == host) {
					score = 900
				} else {
					next
				}
				if (scope != "") score = score + 1

				if (score > best) { best = score; val = lim }
			}
			END { if (best > 0) print val; else exit 1 }
		' "$_SW_LIMITS_FILE" 2>/dev/null) || _swl_val=""
		if [ -n "$_swl_val" ]; then
			printf '%s\n' "$_swl_val"
			return 0
		fi
	fi

	_sw_builtin_limit "$_swl_host" "$_swl_method"
}

# ---------------------------------------------------------------------------
# SECTION 6: worker mode (one process per domain, spawned by xargs)
# ---------------------------------------------------------------------------

# _sw_probe_one <method> <group> <round> <endpoint> <domain>
#   Internal. The unit of work. Probes exactly one name against exactly one
#   pre-resolved endpoint (no per-name endpoint resolution in the hot loop) and
#   appends one row to $DS_SWEEP_RAW:
#
#       round <TAB> status <TAB> domain <TAB> group <TAB> detail
#
#   The append is a single write() to an O_APPEND fd, which is atomic for the
#   short lines we emit - that is what makes it safe for every worker in every
#   group to share one results file.
#   Always exits 0: a failed probe is data (an ERROR row), not a process error,
#   and a non-zero exit here would only make xargs noisy.
_sw_probe_one() {
	if [ "$#" -lt 5 ]; then
		ds_warn "internal: --probe-one needs 5 arguments, got $#"
		return 0
	fi
	_swp_method="$1"
	_swp_group="$2"
	_swp_round="$3"
	_swp_endpoint="$4"
	_swp_domain="$5"
	_swp_raw="${DS_SWEEP_RAW:-}"

	if [ -z "$_swp_raw" ]; then
		ds_warn "internal: DS_SWEEP_RAW is unset; worker cannot report $_swp_domain"
		return 0
	fi

	# Cooperative abort: after Ctrl-C the parent touches this file, so the
	# thousands of workers still queued inside xargs exit instantly instead of
	# starting new network calls. Not reporting a row is correct here - the
	# assembler turns every unreported name into a visible ERROR.
	if [ -n "${DS_SWEEP_ABORT:-}" ] && [ -f "$DS_SWEEP_ABORT" ]; then
		return 0
	fi

	case "$_swp_method" in
	rdap) _swp_line=$(ds_probe_rdap "$_swp_domain" "$_swp_endpoint") || true ;;
	whois) _swp_line=$(ds_probe_whois "$_swp_domain" "$_swp_endpoint") || true ;;
	*) _swp_line="ERROR|$_swp_domain|internal: unknown method $_swp_method" ;;
	esac

	# Defensive: the contract is one line, so honour only the first.
	_swp_line=${_swp_line%%$'\n'*}
	if [ -z "$_swp_line" ]; then
		_swp_line="ERROR|$_swp_domain|probe returned nothing"
	fi

	_swp_status=${_swp_line%%|*}
	_swp_rest=${_swp_line#*|}
	_swp_dom=${_swp_rest%%|*}
	_swp_detail=${_swp_rest#*|}
	[ -n "$_swp_dom" ] || _swp_dom="$_swp_domain"

	printf '%s\t%s\t%s\t%s\t%s\n' \
		"$_swp_round" "$_swp_status" "$_swp_dom" "$_swp_group" "$_swp_detail" \
		>>"$_swp_raw"
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 7: input parsing
# ---------------------------------------------------------------------------

# _sw_read_input <order-file> <valid-file> <invalid-file> <stats-file>
#   Internal. Reads the domain list from $_SW_INPUT (or stdin when '-') and
#   splits it into:
#     order-file    every unique candidate string, in input order (this is the
#                   authoritative row list for the output; invalid names are in
#                   here too, so they cannot vanish)
#     valid-file    the subset that is worth probing
#     invalid-file  "name<TAB>reason" for the rest
#     stats-file    counts of blank/comment/duplicate/invalid/valid/total
_sw_read_input() {
	_swr_order="$1"
	_swr_valid="$2"
	_swr_invalid="$3"
	_swr_stats="$4"

	{
		if [ "$_SW_INPUT" = "-" ]; then
			cat
		else
			cat -- "$_SW_INPUT"
		fi
	} | tr -d '\r' | awk -v order="$_swr_order" -v valid="$_swr_valid" \
		-v invalid="$_swr_invalid" -v stats="$_swr_stats" '
		function bad(d, reason) {
			gsub(/\t/, " ", d)
			print d "\t" reason > (invalid)
		}
		function labels_ok(d,   n, p, i, lab) {
			n = split(d, p, ".")
			if (n < 2) return 0
			for (i = 1; i <= n; i++) {
				lab = p[i]
				if (length(lab) < 1 || length(lab) > 63) return 0
				if (substr(lab, 1, 1) == "-") return 0
				if (substr(lab, length(lab), 1) == "-") return 0
			}
			if (length(p[n]) < 2) return 0
			if (p[n] ~ /^[0-9]+$/) return 0
			return 1
		}
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			sub(/[ \t]+$/, "", line)
			if (line == "")               { blank++;   next }
			if (substr(line, 1, 1) == "#") { comment++; next }

			d = tolower(line)
			sub(/\.$/, "", d)
			if (d in seen) { dup++; next }
			seen[d] = 1

			print d > (order)

			if (length(d) > 253) {
				bad(d, "invalid name: longer than 253 characters"); nbad++; next
			}
			if (d !~ /^[a-z0-9.-]+$/) {
				bad(d, "invalid name: illegal characters (IDNs must be punycode, xn--...)"); nbad++; next
			}
			if (!labels_ok(d)) {
				bad(d, "invalid name: not a registrable domain (need name.tld with valid labels)"); nbad++; next
			}
			print d > (valid)
			ngood++
		}
		END {
			printf "blank\t%d\ncomment\t%d\nduplicate\t%d\ninvalid\t%d\nvalid\t%d\ntotal\t%d\n",
				blank + 0, comment + 0, dup + 0, nbad + 0, ngood + 0, (nbad + 0) + (ngood + 0) > (stats)
		}
	'
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 8: registry routing (one resolution per distinct TLD, never per name)
# ---------------------------------------------------------------------------

# _sw_resolve_tlds <domain-list> <mode> <out-tsv> <unroutable-file>
#   Internal. Resolves each DISTINCT TLD in <domain-list> exactly once - the
#   expensive part (a live `whois -h whois.iana.org` for an unknown ccTLD) is
#   therefore paid once per TLD per run, serially, and cached by lib.sh for
#   every future run.
#   mode: "auto"  = lib.sh's routing (RDAP where usable, else whois)
#         "whois" = force whois (used for the final-round RDAP fallback)
#   Writes <out-tsv>:  tld <TAB> method <TAB> endpoint <TAB> host
#   Writes <unroutable-file>: tld <TAB> reason, for TLDs with no route at all.
_sw_resolve_tlds() {
	_swt_list="$1"
	_swt_mode="$2"
	_swt_out="$3"
	_swt_unroutable="$4"

	: >"$_swt_out"
	: >"$_swt_unroutable"

	_swt_tlds=$(awk -F'\t' '{
		n = split($0, p, ".")
		if (n >= 2 && !(p[n] in seen)) { seen[p[n]] = 1; print p[n] }
	}' "$_swt_list")

	_swt_total=$(printf '%s\n' "$_swt_tlds" | awk 'NF' | wc -l | tr -d ' ')
	[ "$_swt_total" = "0" ] && return 0
	ds_log "resolving registry endpoints for $_swt_total TLD(s)..."

	_swt_i=0
	# A here-string keeps the loop in this shell, so lib.sh's per-process
	# caches and one-time warnings are shared instead of re-paid per TLD.
	while IFS= read -r _swt_tld; do
		[ -n "$_swt_tld" ] || continue
		_swt_i=$((_swt_i + 1))

		_swt_method=""
		_swt_endpoint=""
		if [ "$_swt_mode" != "whois" ]; then
			if _swt_endpoint=$(ds_rdap_endpoint "$_swt_tld"); then
				_swt_method="rdap"
				_swt_host=$(_ds_url_host "$_swt_endpoint")
			fi
		fi
		if [ -z "$_swt_method" ]; then
			if _swt_endpoint=$(ds_whois_server "$_swt_tld"); then
				_swt_method="whois"
				_swt_host="$_swt_endpoint"
			fi
		fi

		if [ -z "$_swt_method" ] || [ -z "$_swt_endpoint" ]; then
			printf '%s\t%s\n' "$_swt_tld" \
				"no RDAP endpoint and no whois server for .$_swt_tld" >>"$_swt_unroutable"
			ds_debug "route[.$_swt_tld]: unroutable"
			continue
		fi

		printf '%s\t%s\t%s\t%s\n' "$_swt_tld" "$_swt_method" "$_swt_endpoint" "$_swt_host" >>"$_swt_out"
		ds_debug "route[.$_swt_tld]: $_swt_method $_swt_endpoint"
	done <<EOF
$_swt_tlds
EOF
	return 0
}

# _sw_build_groups <domain-list> <tld-tsv> <round-dir> <groups-tsv>
#   Internal. Buckets the domains into per-registry groups and writes:
#     <round-dir>/g.<gid>.in   "endpoint domain" pairs (xargs -n 2 fodder)
#     <groups-tsv>             gid <TAB> group <TAB> method <TAB> host
#                              <TAB> limit <TAB> count, sorted biggest first
#   Domains whose TLD is not in the tld table are written to
#   <round-dir>/unrouted.txt so the caller can turn them into ERROR rows.
#   Stdout: nothing. Exit: 0, even when every group is empty.
_sw_build_groups() {
	_swg_list="$1"
	_swg_tlds="$2"
	_swg_dir="$3"
	_swg_out="$4"

	rm -f "$_swg_dir"/g.*.in "$_swg_dir"/g.*.done "$_swg_dir"/g.*.done.tmp 2>/dev/null || true
	: >"$_swg_out"
	: >"$_swg_dir/unrouted.txt"

	[ -s "$_swg_list" ] || return 0
	[ -s "$_swg_tlds" ] || {
		cp "$_swg_list" "$_swg_dir/unrouted.txt"
		return 0
	}

	# Pass 1: assign a group id to each distinct method+host, and fan the
	# domains out into per-group input files.
	awk -F'\t' -v dir="$_swg_dir" -v meta="$_swg_dir/groups.meta" \
		-v unrouted="$_swg_dir/unrouted.txt" '
		FNR == NR {
			method[$1] = $2; endpoint[$1] = $3; host[$1] = $4
			next
		}
		{
			d = $0
			n = split(d, p, ".")
			t = (n >= 2) ? p[n] : ""
			if (t == "" || !(t in method)) { print d > (unrouted); next }
			key = method[t] ":" host[t]
			if (!(key in gid)) {
				gid[key] = ++ngroups
				gmethod[key] = method[t]
				ghost[key] = host[t]
			}
			print endpoint[t] " " d > (dir "/g." gid[key] ".in")
			count[key]++
		}
		END {
			for (k in gid)
				printf "%d\t%s\t%s\t%s\t%d\n", gid[k], k, gmethod[k], ghost[k], count[k] > (meta)
		}
	' "$_swg_tlds" "$_swg_list"

	[ -s "$_swg_dir/groups.meta" ] || return 0

	# Pass 2: attach the concurrency limit for each group (a handful of awk
	# lookups, not one per domain) and clamp it to the global cap.
	while IFS=$'\t' read -r _swg_gid _swg_key _swg_method _swg_host _swg_count; do
		[ -n "$_swg_gid" ] || continue
		_swg_limit=$(_sw_limit_for "$_swg_host" "$_swg_method")
		_sw_is_uint "$_swg_limit" || _swg_limit=1
		[ "$_swg_limit" -lt 1 ] && _swg_limit=1
		[ "$_swg_limit" -gt "$_SW_PARALLEL" ] && _swg_limit="$_SW_PARALLEL"
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$_swg_gid" "$_swg_key" "$_swg_method" "$_swg_host" "$_swg_limit" "$_swg_count"
	done <"$_swg_dir/groups.meta" | sort -t$'\t' -k6,6nr -k2,2 >"$_swg_out"

	rm -f "$_swg_dir/groups.meta"
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 9: the scheduler
# ---------------------------------------------------------------------------

# _sw_progress <round> <round-total> <active> <queued> <force>
#   Internal. Repaints the stderr progress meter, at most once every
#   DS_SWEEP_PROGRESS_EVERY seconds unless <force> is 1. Counts are recomputed
#   from the raw results file, taking the latest row per domain so a retried
#   name is never double-counted.
_sw_progress() {
	[ "$_SW_PROGRESS" = "1" ] || return 0
	_swp_round="$1"
	_swp_total="$2"
	_swp_active="$3"
	_swp_queued="$4"
	_swp_force="${5:-0}"

	_swp_now=$(date +%s)
	if [ "$_swp_force" != "1" ] &&
		[ "$((_swp_now - _SW_LAST_PROGRESS))" -lt "$DS_SWEEP_PROGRESS_EVERY" ]; then
		return 0
	fi
	_SW_LAST_PROGRESS="$_swp_now"

	_swp_counts=$(awk -F'\t' -v round="$_swp_round" '
		{ st[$3] = $2; if ($1 == round) done++ }
		END {
			for (d in st) c[st[d]]++
			printf "%d %d %d %d",
				c["REGISTERED"] + 0, c["UNREGISTERED"] + 0, c["ERROR"] + 0, done + 0
		}
	' "$_SW_RAW" 2>/dev/null) || _swp_counts="0 0 0 0"
	[ -n "$_swp_counts" ] || _swp_counts="0 0 0 0"
	read -r _swp_reg _swp_unreg _swp_err _swp_done <<EOF
$_swp_counts
EOF

	_swp_msg=$(printf 'sweep r%s: %s/%s | REGISTERED %s UNREGISTERED %s ERROR %s | groups %s running %s queued | %ss' \
		"$_swp_round" "$_swp_done" "$_swp_total" "$_swp_reg" "$_swp_unreg" "$_swp_err" \
		"$_swp_active" "$_swp_queued" "$((_swp_now - _SW_T0))")

	if [ -t 2 ]; then
		printf '\r[ds] %-118s' "$_swp_msg" >&2
		_SW_PROGRESS_OPEN=1
	else
		[ "${DS_QUIET:-0}" = "1" ] || printf '[ds] %s\n' "$_swp_msg" >&2
	fi
	return 0
}

# _sw_progress_close
#   Internal. Terminates an in-place progress line so the next message starts
#   on a clean row.
_sw_progress_close() {
	if [ "$_SW_PROGRESS_OPEN" = "1" ]; then
		printf '\n' >&2
		_SW_PROGRESS_OPEN=0
	fi
	return 0
}

# _sw_run_round <round-dir> <groups-tsv> <round> <total>
#   Internal. Runs one full pass over the groups.
#
#   Concurrency model: every group is an `xargs -P <limit>` fan-out running in
#   its own background subshell, and the scheduler starts groups (biggest
#   first) only while the sum of their limits fits inside the global -p budget.
#   Completion is detected by a sentinel file rather than by `kill -0`, because
#   an exited-but-unreaped child still answers `kill -0` - polling on that
#   would deadlock the run.
_sw_run_round() {
	_swr_dir="$1"
	_swr_groups="$2"
	_swr_round="$3"
	_swr_total="$4"

	[ -s "$_swr_groups" ] || return 0

	# Load the plan. Arrays are fine in bash 3.2; only associative ones are not.
	_swr_g_gid=()
	_swr_g_key=()
	_swr_g_method=()
	_swr_g_limit=()
	while IFS=$'\t' read -r _f1 _f2 _f3 _f4 _f5 _f6; do
		[ -n "$_f1" ] || continue
		_swr_g_gid[${#_swr_g_gid[@]}]="$_f1"
		_swr_g_key[${#_swr_g_key[@]}]="$_f2"
		_swr_g_method[${#_swr_g_method[@]}]="$_f3"
		_swr_g_limit[${#_swr_g_limit[@]}]="$_f5"
	done <"$_swr_groups"

	_swr_ngroups=${#_swr_g_gid[@]}
	[ "$_swr_ngroups" -gt 0 ] || return 0

	_swr_next=0
	_swr_used=0
	_swr_pids=()
	_swr_slots=()
	_swr_ids=()
	_swr_names=()

	while :; do
		# --- launch whatever fits in the budget ---------------------------
		while [ "$_SW_INTERRUPTED" = "0" ] && [ "$_swr_next" -lt "$_swr_ngroups" ]; do
			_swr_lim=${_swr_g_limit[$_swr_next]}
			_swr_gid=${_swr_g_gid[$_swr_next]}
			_swr_in="$_swr_dir/g.$_swr_gid.in"
			if [ ! -s "$_swr_in" ]; then
				_swr_next=$((_swr_next + 1))
				continue
			fi
			# Always allow one group to run even if its limit somehow exceeds
			# the remaining budget - otherwise a misconfigured limit deadlocks.
			if [ "$((_swr_used + _swr_lim))" -gt "$_SW_PARALLEL" ] && [ "$_swr_used" -gt 0 ]; then
				break
			fi

			# Capture into scalars before forking: the subshell must not be
			# reading an index the parent is about to advance.
			_swr_key="${_swr_g_key[$_swr_next]}"
			_swr_method="${_swr_g_method[$_swr_next]}"
			_swr_done_file="$_swr_dir/g.$_swr_gid.done"
			rm -f "$_swr_done_file" 2>/dev/null || true
			ds_debug "round $_swr_round: starting $_swr_key limit=$_swr_lim"
			(
				_rc=0
				# One xargs pool per registry. Input lines are
				# "<endpoint> <domain>" and -n 2 hands both to one worker, so a
				# single host serving many TLDs on different base paths (all of
				# CentralNic, com+net on Verisign) shares ONE budget while each
				# name still goes to its own base URL.
				xargs -P "$_swr_lim" -n 2 \
					"$_SW_BASH" "$_SW_SELF" --probe-one \
					"$_swr_method" "$_swr_key" "$_swr_round" \
					<"$_swr_in" >/dev/null 2>>"$_swr_dir/workers.err" || _rc=$?
				printf '%s\n' "$_rc" >"$_swr_done_file.tmp" 2>/dev/null &&
					mv "$_swr_done_file.tmp" "$_swr_done_file" 2>/dev/null
			) &
			_swr_pids[${#_swr_pids[@]}]=$!
			_swr_slots[${#_swr_slots[@]}]="$_swr_lim"
			_swr_ids[${#_swr_ids[@]}]="$_swr_gid"
			_swr_names[${#_swr_names[@]}]="$_swr_key"
			_swr_used=$((_swr_used + _swr_lim))
			_swr_next=$((_swr_next + 1))
		done

		_swr_nactive=${#_swr_pids[@]}
		if [ "$_swr_nactive" -eq 0 ]; then
			# Nothing running: either we are done, or an interrupt stopped us
			# from launching the rest.
			if [ "$_SW_INTERRUPTED" != "0" ] || [ "$_swr_next" -ge "$_swr_ngroups" ]; then
				break
			fi
			_sw_nap
			continue
		fi

		# --- reap finished groups -----------------------------------------
		_swr_keep_pids=()
		_swr_keep_slots=()
		_swr_keep_ids=()
		_swr_keep_names=()
		_swr_i=0
		while [ "$_swr_i" -lt "$_swr_nactive" ]; do
			_swr_gid=${_swr_ids[$_swr_i]}
			if [ -f "$_swr_dir/g.$_swr_gid.done" ]; then
				wait "${_swr_pids[$_swr_i]}" 2>/dev/null || true
				_swr_rc=$(cat "$_swr_dir/g.$_swr_gid.done" 2>/dev/null || printf '0')
				if [ "$_swr_rc" != "0" ]; then
					_sw_progress_close
					ds_warn "group ${_swr_names[$_swr_i]} finished with xargs status $_swr_rc (round $_swr_round); affected names are reported as ERROR rows"
				fi
				_swr_used=$((_swr_used - _swr_slots[_swr_i]))
				[ "$_swr_used" -lt 0 ] && _swr_used=0
				ds_debug "round $_swr_round: finished ${_swr_names[$_swr_i]}"
			else
				_swr_keep_pids[${#_swr_keep_pids[@]}]="${_swr_pids[$_swr_i]}"
				_swr_keep_slots[${#_swr_keep_slots[@]}]="${_swr_slots[$_swr_i]}"
				_swr_keep_ids[${#_swr_keep_ids[@]}]="${_swr_ids[$_swr_i]}"
				_swr_keep_names[${#_swr_keep_names[@]}]="${_swr_names[$_swr_i]}"
			fi
			_swr_i=$((_swr_i + 1))
		done
		_swr_pids=()
		_swr_slots=()
		_swr_ids=()
		_swr_names=()
		_swr_i=0
		while [ "$_swr_i" -lt "${#_swr_keep_pids[@]}" ]; do
			_swr_pids[${#_swr_pids[@]}]="${_swr_keep_pids[$_swr_i]}"
			_swr_slots[${#_swr_slots[@]}]="${_swr_keep_slots[$_swr_i]}"
			_swr_ids[${#_swr_ids[@]}]="${_swr_keep_ids[$_swr_i]}"
			_swr_names[${#_swr_names[@]}]="${_swr_keep_names[$_swr_i]}"
			_swr_i=$((_swr_i + 1))
		done

		_sw_progress "$_swr_round" "$_swr_total" "${#_swr_pids[@]}" \
			"$((_swr_ngroups - _swr_next))" 0

		if [ "${#_swr_pids[@]}" -eq 0 ] && [ "$_swr_next" -ge "$_swr_ngroups" ]; then
			break
		fi
		[ "${#_swr_pids[@]}" -gt 0 ] && _sw_nap
	done

	_sw_progress "$_swr_round" "$_swr_total" 0 0 1
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 10: retry queue
# ---------------------------------------------------------------------------

# _sw_collect_retries <round> <out-list> <out-detail-tsv>
#   Internal. Finds the names whose LATEST result is a retryable ERROR - a 429,
#   a 503, a timeout, a curl-level failure or a whois rate-limit - and writes
#   them to <out-list> (one per line, input order preserved via the raw file's
#   natural ordering) plus <out-detail-tsv> (domain <TAB> group <TAB> detail),
#   so that a name dropped by the retry cap can still report which registry
#   failed it and why.
#   Permanent errors (invalid name, unparsed whois response, no endpoint) are
#   deliberately NOT retried: they are real findings that need triage.
_sw_collect_retries() {
	_swc_round="$1"
	_swc_list="$2"
	_swc_details="$3"

	: >"$_swc_list"
	: >"$_swc_details"
	[ -s "$_SW_RAW" ] || return 0

	awk -F'\t' -v round="$_swc_round" -v re="$_SW_RETRYABLE_RE" \
		-v list="$_swc_list" -v details="$_swc_details" '
		$1 == round {
			if ($2 != "ERROR") next
			if (tolower($5) !~ re) next
			if ($3 in seen) next
			seen[$3] = 1
			print $3 > (list)
			print $3 "\t" $4 "\t" $5 > (details)
		}
	' "$_SW_RAW"
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 11: assembly
# ---------------------------------------------------------------------------

# _sw_assemble <order-file> <raw-file> <out-file> <stats-file>
#   Internal. Joins the raw probe rows back onto the ordered list of unique
#   input names and emits the final TSV. This is the function that makes the
#   "nothing is silently dropped" promise true: it walks the INPUT list, not
#   the results, so a name with no result at all becomes a loud ERROR row
#   rather than a missing line nobody notices.
_sw_assemble() {
	_swa_order="$1"
	_swa_raw="$2"
	_swa_out="$3"
	_swa_stats="$4"

	# NB: the two input files are distinguished by FILENAME, not by the usual
	# FNR==NR idiom - an interrupted run can leave raw.tsv empty, and FNR==NR
	# would then silently treat the ORDER file as results and emit nothing.
	awk -F'\t' -v OFS='\t' -v header="$_SW_HEADER" -v stats="$_swa_stats" \
		-v rawfile="$_swa_raw" '
		FILENAME == rawfile {
			d = $3
			if (d == "") next
			# Rounds are executed strictly in sequence, so the last row seen
			# for a name is its latest attempt.
			status[d] = $2
			group[d]  = $4
			detail[d] = $5
			if (!(d in firstdetail)) firstdetail[d] = $5
			if ($1 ~ /^[0-9]+$/) attempts[d]++
			next
		}
		{
			d = $0
			if (d == "") next
			rows++
			if (d in status) {
				st = status[d]
				g  = group[d]
				det = detail[d]
				a = attempts[d] + 0
				if (a > 1 && firstdetail[d] != det)
					det = det "; first attempt: " firstdetail[d]
			} else {
				st = "ERROR"
				g = "-"
				det = "no result returned (worker lost, or run interrupted before this name was probed)"
				a = 0
				missing++
			}
			n = split(d, p, ".")
			tld = (n >= 2) ? p[n] : "-"
			if (header && !printed) {
				print "# status", "domain", "tld", "endpoint", "attempts", "detail"
				printed = 1
			}
			print st, d, tld, g, a, det
			count[st]++
			if (a > 1) retried++
		}
		END {
			printf "rows\t%d\nREGISTERED\t%d\nUNREGISTERED\t%d\nERROR\t%d\nmissing\t%d\nretried\t%d\n",
				rows + 0, count["REGISTERED"] + 0, count["UNREGISTERED"] + 0,
				count["ERROR"] + 0, missing + 0, retried + 0 > (stats)
		}
	' "$_swa_raw" "$_swa_order" >"$_swa_out"
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 12: signal handling and cleanup
# ---------------------------------------------------------------------------

# _sw_cleanup
#   Internal. EXIT trap: removes the working directory unless --keep-temp.
# shellcheck disable=SC2329  # invoked via `trap ... EXIT`
_sw_cleanup() {
	_swx_rc=$?
	if [ -n "$_SW_TMPDIR" ] && [ -d "$_SW_TMPDIR" ]; then
		if [ "$_SW_KEEP_TEMP" = "1" ]; then
			ds_warn "working directory kept: $_SW_TMPDIR"
		else
			rm -rf "$_SW_TMPDIR" 2>/dev/null || true
		fi
	fi
	return "$_swx_rc"
}

# _sw_on_signal <name>
#   Internal. First Ctrl-C: drop an abort marker. Every queued worker checks it
#   at startup and exits immediately, so the xargs pools drain in seconds while
#   in-flight lookups finish under their existing timeouts - and we still get to
#   write (clearly flagged) partial results. Second Ctrl-C: kill the pools.
# shellcheck disable=SC2329  # invoked via `trap ... INT/TERM`
_sw_on_signal() {
	if [ "$_SW_INTERRUPTED" = "0" ]; then
		_SW_INTERRUPTED=1
		[ -n "$_SW_ABORT" ] && : >"$_SW_ABORT" 2>/dev/null
		_sw_progress_close
		ds_warn "$1 received - draining in-flight lookups, partial results will still be written."
		ds_warn "  press Ctrl-C again to stop immediately."
	else
		_SW_INTERRUPTED=2
		_sw_progress_close
		ds_warn "$1 again - killing worker pools now."
		if _ds_have pkill; then
			for _swk_pid in $(jobs -p 2>/dev/null); do
				pkill -TERM -P "$_swk_pid" 2>/dev/null || true
			done
		fi
		for _swk_pid in $(jobs -p 2>/dev/null); do
			kill -TERM "$_swk_pid" 2>/dev/null || true
		done
	fi
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 13: argument parsing
# ---------------------------------------------------------------------------

_sw_parse_args() {
	while [ "$#" -gt 0 ]; do
		_swa_arg="$1"
		_swa_val=""
		# Support --opt=value as well as --opt value.
		case "$_swa_arg" in
		--*=*)
			_swa_val=${_swa_arg#*=}
			_swa_arg=${_swa_arg%%=*}
			set -- "$_swa_arg" "$_swa_val" "${@:2}"
			;;
		esac

		case "$1" in
		-p | --parallel)
			[ "$#" -ge 2 ] || ds_die "$1 needs a value"
			_SW_PARALLEL="$2"
			shift 2
			;;
		-o | --out | --output)
			[ "$#" -ge 2 ] || ds_die "$1 needs a value"
			_SW_OUT="$2"
			shift 2
			;;
		-r | --rounds)
			[ "$#" -ge 2 ] || ds_die "$1 needs a value"
			_SW_ROUNDS="$2"
			shift 2
			;;
		--retry-cap)
			[ "$#" -ge 2 ] || ds_die "$1 needs a value"
			_SW_RETRY_CAP="$2"
			shift 2
			;;
		-l | --limits)
			[ "$#" -ge 2 ] || ds_die "$1 needs a value"
			_SW_LIMITS_FILE="$2"
			shift 2
			;;
		--no-fallback)
			_SW_FALLBACK=0
			shift
			;;
		--no-header)
			_SW_HEADER=0
			shift
			;;
		--no-progress)
			_SW_PROGRESS=0
			shift
			;;
		-n | --dry-run)
			_SW_DRYRUN=1
			shift
			;;
		--explain-limit)
			# Diagnostic: "why is this registry only getting N slots?"
			[ "$#" -ge 2 ] || ds_die "$1 needs a hostname"
			printf '%s\t%s\n' "$2" "$(_sw_limit_for "$2" "${3:-rdap}")"
			exit 0
			;;
		--keep-temp)
			_SW_KEEP_TEMP=1
			shift
			;;
		-q | --quiet)
			DS_QUIET=1
			export DS_QUIET
			shift
			;;
		-v | --verbose)
			DS_DEBUG=1
			export DS_DEBUG
			shift
			;;
		-h | --help)
			_sw_usage
			exit 0
			;;
		-V | --version)
			printf 'sweep.sh %s (lib.sh %s)\n' "$DS_SWEEP_VERSION" "$DS_LIB_VERSION"
			exit 0
			;;
		--)
			shift
			[ "$#" -gt 0 ] && _SW_INPUT="$1"
			break
			;;
		-)
			_SW_INPUT="-"
			shift
			;;
		-*)
			ds_die "unknown option: $1 (try --help)"
			;;
		*)
			[ -z "$_SW_INPUT" ] || ds_die "only one input file may be given (got '$_SW_INPUT' and '$1')"
			_SW_INPUT="$1"
			shift
			;;
		esac
	done

	# Input: a file, an explicit '-', or stdin when it is not a terminal.
	if [ -z "$_SW_INPUT" ]; then
		if [ -t 0 ]; then
			_sw_usage >&2
			ds_die "no input: give a file of domains, or pipe them in and pass '-'"
		fi
		_SW_INPUT="-"
	fi
	if [ "$_SW_INPUT" != "-" ] && [ ! -r "$_SW_INPUT" ]; then
		ds_die "cannot read input file: $_SW_INPUT"
	fi

	_sw_is_uint "$_SW_PARALLEL" && [ "$_SW_PARALLEL" -ge 1 ] ||
		ds_die "--parallel must be a positive integer (got '$_SW_PARALLEL')"
	_sw_is_uint "$_SW_ROUNDS" && [ "$_SW_ROUNDS" -ge 1 ] ||
		ds_die "--rounds must be a positive integer (got '$_SW_ROUNDS')"
	_sw_is_uint "$_SW_RETRY_CAP" ||
		ds_die "--retry-cap must be a non-negative integer (got '$_SW_RETRY_CAP')"

	if [ -n "$_SW_OUT" ]; then
		_swa_dir=$(dirname "$_SW_OUT")
		[ -d "$_swa_dir" ] || ds_die "output directory does not exist: $_swa_dir"
		[ -w "$_swa_dir" ] || ds_die "output directory is not writable: $_swa_dir"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 14: plan reporting
# ---------------------------------------------------------------------------

# _sw_report_plan <groups-tsv> <label>
#   Internal. Prints the work plan - which registry, how many names, how many
#   slots - so it is obvious before a long run where the time will go.
_sw_report_plan() {
	[ -s "$1" ] || return 0
	_swp_peak=$(awk -F'\t' -v cap="$_SW_PARALLEL" '
		{ s += $5 } END { print (s > cap ? cap : s) + 0 }
	' "$1")
	ds_log "$2"
	# Written with awk rather than ds_log for alignment, so it has to honour
	# DS_QUIET itself.
	if [ "${DS_QUIET:-0}" != "1" ]; then
		awk -F'\t' '{ printf "[ds]   %-44s %6d name(s)  %2d slot(s)\n", $2, $6, $5 }' "$1" >&2
	fi
	ds_log "peak concurrency: $_swp_peak (global cap $_SW_PARALLEL)"
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 15: main
# ---------------------------------------------------------------------------

_sw_main() {
	_sw_parse_args "$@"
	ds_require awk sort xargs mktemp tr

	_SW_T0=$(date +%s)
	_SW_LAST_PROGRESS=0
	_sw_detect_nap

	if [ ! -s "$_SW_LIMITS_FILE" ]; then
		_SW_LIMITS_BUILTIN=1
		ds_warn "registry limits table missing: $_SW_LIMITS_FILE"
		ds_warn "  falling back to built-in conservative limits; the sweep will be SLOWER,"
		ds_warn "  restore data/registry-limits.tsv to get the tuned per-registry budgets."
	fi

	_SW_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/domainsaver-sweep.XXXXXXXX") ||
		ds_die "cannot create a working directory"
	trap _sw_cleanup EXIT
	trap '_sw_on_signal SIGINT' INT
	trap '_sw_on_signal SIGTERM' TERM

	_SW_RAW="$_SW_TMPDIR/raw.tsv"
	_SW_ABORT="$_SW_TMPDIR/abort"
	: >"$_SW_RAW"

	# Workers are separate processes spawned by xargs, so everything they need
	# has to travel through the environment. DS_ROOT/DS_DATA_DIR are exported
	# too: without them a worker would re-derive its own paths and could read a
	# different cache than the parent planned against.
	DS_SWEEP_RAW="$_SW_RAW"
	DS_SWEEP_ABORT="$_SW_ABORT"
	export DS_SWEEP_RAW DS_SWEEP_ABORT DS_ROOT DS_DATA_DIR

	_sw_order="$_SW_TMPDIR/order.txt"
	_sw_valid="$_SW_TMPDIR/valid.txt"
	_sw_invalid="$_SW_TMPDIR/invalid.tsv"
	_sw_instats="$_SW_TMPDIR/input-stats.tsv"
	: >"$_sw_order"
	: >"$_sw_valid"
	: >"$_sw_invalid"
	: >"$_sw_instats"

	# --- 1. read and validate the input --------------------------------
	_sw_read_input "$_sw_order" "$_sw_valid" "$_sw_invalid" "$_sw_instats"

	_sw_n_total=$(_sw_stat "$_sw_instats" total)
	_sw_n_valid=$(_sw_stat "$_sw_instats" valid)
	_sw_n_invalid=$(_sw_stat "$_sw_instats" invalid)
	_sw_n_dup=$(_sw_stat "$_sw_instats" duplicate)
	_sw_n_blank=$(_sw_stat "$_sw_instats" blank)
	_sw_n_comment=$(_sw_stat "$_sw_instats" comment)

	if [ "$_sw_n_total" = "0" ]; then
		ds_die "no usable domains in the input (blank=$_sw_n_blank comment=$_sw_n_comment)"
	fi
	ds_log "input: $_sw_n_total unique name(s) to probe ($_sw_n_valid routable, $_sw_n_invalid unusable)"
	[ "$_sw_n_blank" = "0" ] && [ "$_sw_n_comment" = "0" ] ||
		ds_log "  skipped $_sw_n_blank blank and $_sw_n_comment comment line(s)"
	[ "$_sw_n_dup" = "0" ] ||
		ds_warn "collapsed $_sw_n_dup duplicate line(s): the output has one row per UNIQUE name, so it is shorter than the input"

	# Unusable names become ERROR rows immediately (round 'pre'), so they
	# appear in the output instead of quietly disappearing.
	if [ -s "$_sw_invalid" ]; then
		ds_warn "$_sw_n_invalid input line(s) are not usable domain names; each is reported as an ERROR row"
		awk -F'\t' '{ printf "pre\tERROR\t%s\t-\t%s\n", $1, $2 }' "$_sw_invalid" >>"$_SW_RAW"
	fi

	# --- 2. resolve every distinct TLD once ----------------------------
	_sw_tlds="$_SW_TMPDIR/tlds.tsv"
	_sw_unroutable="$_SW_TMPDIR/unroutable.tsv"
	_sw_resolve_tlds "$_sw_valid" auto "$_sw_tlds" "$_sw_unroutable"

	_sw_round_dir="$_SW_TMPDIR/r1"
	mkdir -p "$_sw_round_dir"
	_sw_groups="$_sw_round_dir/groups.tsv"
	_sw_build_groups "$_sw_valid" "$_sw_tlds" "$_sw_round_dir" "$_sw_groups"

	# Names whose TLD has no route at all: ERROR rows, loudly.
	if [ -s "$_sw_round_dir/unrouted.txt" ]; then
		_sw_n_unrouted=$(_sw_count_lines "$_sw_round_dir/unrouted.txt")
		ds_warn "$_sw_n_unrouted name(s) have no reachable registry (no RDAP endpoint and no whois server); reported as ERROR rows"
		[ -s "$_sw_unroutable" ] &&
			awk -F'\t' '{ printf "[ds] WARN:   .%s - %s\n", $1, $2 }' "$_sw_unroutable" >&2
		awk '{ printf "pre\tERROR\t%s\t-\tno reachable registry for this TLD (no RDAP endpoint, no whois server)\n", $0 }' \
			"$_sw_round_dir/unrouted.txt" >>"$_SW_RAW"
	fi

	_sw_report_plan "$_sw_groups" "work plan by registry:"

	if [ "$_SW_DRYRUN" = "1" ]; then
		ds_log "dry run: nothing was probed."
		return 0
	fi

	# Require only the tools this particular sweep actually needs: an all-RDAP
	# list must not be blocked because whois is missing, and vice versa.
	if awk -F'\t' '$3 == "rdap" { found = 1 } END { exit !found }' "$_sw_groups" 2>/dev/null; then
		ds_require curl
	fi
	if awk -F'\t' '$3 == "whois" { found = 1 } END { exit !found }' "$_sw_groups" 2>/dev/null; then
		ds_require whois
	fi

	# --- 3. probe, then retry what the registries refused --------------
	_sw_round=1
	_sw_round_total=$(_sw_count_lines "$_sw_valid")
	_sw_retry_list="$_SW_TMPDIR/retry.txt"
	_sw_retry_details="$_SW_TMPDIR/retry-details.tsv"
	_sw_n_capped=0

	while :; do
		_sw_run_round "$_sw_round_dir" "$_sw_groups" "$_sw_round" "$_sw_round_total"
		_sw_progress_close

		[ "$_SW_INTERRUPTED" = "0" ] || {
			ds_warn "run interrupted during round $_sw_round; names that never got a result are reported as ERROR"
			break
		}
		[ "$_sw_round" -lt "$_SW_ROUNDS" ] || break

		_sw_collect_retries "$_sw_round" "$_sw_retry_list" "$_sw_retry_details"
		_sw_n_retry=$(_sw_count_lines "$_sw_retry_list")
		[ "$_sw_n_retry" -gt 0 ] || break

		# Bounded retry queue. Over the cap we do NOT quietly stop retrying:
		# the excess is written back as an explicit ERROR row that says so.
		if [ "$_SW_RETRY_CAP" -gt 0 ] && [ "$_sw_n_retry" -gt "$_SW_RETRY_CAP" ]; then
			ds_warn "retry queue holds $_sw_n_retry name(s) but the cap is $_SW_RETRY_CAP (--retry-cap)"
			ds_warn "  the first $_SW_RETRY_CAP will be retried; the remaining $((_sw_n_retry - _SW_RETRY_CAP)) stay ERROR and say so in their detail column"
			awk -v cap="$_SW_RETRY_CAP" 'NR > cap' "$_sw_retry_list" >"$_sw_retry_list.over"
			_sw_n_capped=$((_sw_n_capped + $(_sw_count_lines "$_sw_retry_list.over")))
			awk -F'\t' -v cap="$_SW_RETRY_CAP" -v over="$_sw_retry_list.over" '
				FNR == NR { skip[$0] = 1; next }
				($1 in skip) {
					printf "cap\tERROR\t%s\t%s\tnot retried: retry queue cap of %d reached; last error: %s\n",
						$1, $2, cap, $3
				}
			' "$_sw_retry_list.over" "$_sw_retry_details" >>"$_SW_RAW"
			awk -v cap="$_SW_RETRY_CAP" 'NR <= cap' "$_sw_retry_list" >"$_sw_retry_list.keep"
			mv "$_sw_retry_list.keep" "$_sw_retry_list"
			_sw_n_retry="$_SW_RETRY_CAP"
		fi

		_sw_round=$((_sw_round + 1))

		# Round-level backoff on top of lib.sh's per-request backoff: if a
		# registry has just throttled us, hitting it again immediately is how
		# a soft rate limit becomes a hard ban.
		_sw_sleep=$((DS_RDAP_BACKOFF_BASE * (1 << (_sw_round - 2))))
		[ "$_sw_sleep" -gt "$DS_RDAP_BACKOFF_MAX" ] && _sw_sleep="$DS_RDAP_BACKOFF_MAX"
		ds_log "retry round $_sw_round: $_sw_n_retry name(s) were rate-limited or timed out; backing off ${_sw_sleep}s"
		sleep "$_sw_sleep"
		# A Ctrl-C during the backoff must not be followed by a fresh round of
		# endpoint resolution and probing.
		if [ "$_SW_INTERRUPTED" != "0" ]; then
			ds_warn "run interrupted during the round $_sw_round backoff; remaining names are reported as ERROR"
			break
		fi

		_sw_round_dir="$_SW_TMPDIR/r$_sw_round"
		mkdir -p "$_sw_round_dir"
		_sw_groups="$_sw_round_dir/groups.tsv"

		# Final round: fall back from RDAP to whois, exactly as ds_probe does
		# for a single name. A throttled RDAP endpoint must never be the last
		# word on a name when a second source of truth exists.
		_sw_mode="auto"
		if [ "$_SW_FALLBACK" = "1" ] && [ "$_sw_round" -ge "$_SW_ROUNDS" ]; then
			_sw_mode="whois"
			ds_log "  final round: routing retries to whois instead of RDAP"
		fi
		_sw_tlds_round="$_sw_round_dir/tlds.tsv"
		_sw_resolve_tlds "$_sw_retry_list" "$_sw_mode" "$_sw_tlds_round" "$_sw_round_dir/unroutable.tsv"
		_sw_build_groups "$_sw_retry_list" "$_sw_tlds_round" "$_sw_round_dir" "$_sw_groups"

		if [ -s "$_sw_round_dir/unrouted.txt" ]; then
			awk '{ printf "pre\tERROR\t%s\t-\tno reachable registry for this TLD on retry (no RDAP endpoint, no whois server)\n", $0 }' \
				"$_sw_round_dir/unrouted.txt" >>"$_SW_RAW"
		fi
		[ -s "$_sw_groups" ] || break
		_sw_round_total="$_sw_n_retry"
		_sw_report_plan "$_sw_groups" "retry plan by registry:"
	done

	# --- 4. assemble one row per input name ----------------------------
	_sw_outstats="$_SW_TMPDIR/out-stats.tsv"
	_sw_result="$_SW_TMPDIR/result.tsv"
	_sw_assemble "$_sw_order" "$_SW_RAW" "$_sw_result" "$_sw_outstats"

	_sw_rows=$(_sw_stat "$_sw_outstats" rows)
	_sw_reg=$(_sw_stat "$_sw_outstats" REGISTERED)
	_sw_unreg=$(_sw_stat "$_sw_outstats" UNREGISTERED)
	_sw_err=$(_sw_stat "$_sw_outstats" ERROR)
	_sw_missing=$(_sw_stat "$_sw_outstats" missing)
	_sw_retried=$(_sw_stat "$_sw_outstats" retried)

	if [ -n "$_SW_OUT" ]; then
		# Write-then-rename: a reader of -o never sees a half-written sweep.
		if ! cp "$_sw_result" "$_SW_OUT.tmp.$$"; then
			ds_die "failed to write $_SW_OUT.tmp.$$"
		fi
		if ! mv "$_SW_OUT.tmp.$$" "$_SW_OUT"; then
			rm -f "$_SW_OUT.tmp.$$" 2>/dev/null || true
			ds_die "failed to write $_SW_OUT"
		fi
	else
		cat "$_sw_result"
	fi

	# --- 5. summary, and every caveat said out loud --------------------
	_sw_elapsed=$(($(date +%s) - _SW_T0))
	ds_log "-----------------------------------------------------------------"
	ds_log "swept $_sw_rows name(s) in ${_sw_elapsed}s over $_sw_round round(s)"
	ds_log "  REGISTERED   $_sw_reg"
	ds_log "  UNREGISTERED $_sw_unreg"
	ds_log "  ERROR        $_sw_err"
	[ "$_sw_retried" = "0" ] || ds_log "  retried      $_sw_retried name(s) after a rate limit or timeout"
	[ -n "$_SW_OUT" ] && ds_log "results written to $_SW_OUT"

	if [ "$_sw_rows" != "$_sw_n_total" ]; then
		ds_warn "BUG: emitted $_sw_rows rows for $_sw_n_total input names - please report this."
	fi
	if [ "$_sw_missing" != "0" ]; then
		ds_warn "$_sw_missing name(s) never produced a result and are ERROR rows saying so."
		ds_warn "  they were NOT dropped; re-run just those names to finish the job."
	fi
	if [ "$_sw_n_capped" != "0" ]; then
		ds_warn "$_sw_n_capped name(s) hit the retry-queue cap and were never retried (see their detail column)."
	fi
	if [ -s "$_SW_TMPDIR/r1/workers.err" ] || [ -s "$_SW_TMPDIR/r$_sw_round/workers.err" ]; then
		_sw_werr=$(cat "$_SW_TMPDIR"/r*/workers.err 2>/dev/null | sort | uniq -c | sort -rn | head -n 5)
		if [ -n "$_sw_werr" ]; then
			ds_warn "workers wrote to stderr; most frequent messages:"
			printf '%s\n' "$_sw_werr" | sed -e 's/^/[ds] WARN:   /' >&2
		fi
	fi
	if [ "$_SW_LIMITS_BUILTIN" = "1" ]; then
		ds_warn "ran with built-in fallback concurrency limits ($_SW_LIMITS_FILE was missing)."
	fi
	if [ "$_sw_unreg" != "0" ]; then
		ds_log "REMINDER: UNREGISTERED is not AVAILABLE. Those $_sw_unreg name(s) are absent"
		ds_log "  from the registry, which also covers registry-RESERVED and PREMIUM-priced."
		ds_log "  Price them before believing any of them is purchasable."
	fi

	[ "$_SW_INTERRUPTED" = "0" ] || {
		ds_warn "PARTIAL RESULTS: the run was interrupted."
		return 130
	}
	[ "$_sw_err" = "0" ] || return 2
	return 0
}

# ---------------------------------------------------------------------------
# SECTION 16: entry point
# ---------------------------------------------------------------------------

# Worker mode first: xargs re-executes this file once per domain, and that path
# must not touch argument parsing, temp files or traps.
if [ "${1:-}" = "--probe-one" ]; then
	shift
	_sw_probe_one "$@"
	exit 0
fi

_sw_main "$@"
exit $?

# End of sweep.sh
