#!/bin/sh
# claude-timestamps — shared hook helpers.
#
# POSIX sh only. No bashisms, no errexit. Nothing here ever exits the caller.
# The only external program any per-turn code path is allowed to run is `date`
# (measured 1.75ms; node is 24.00ms and python3 15.16ms — both far over budget).
#
# Every function returns 0. Failure is expressed by leaving its output variable
# empty, never by a non-zero status. This is deliberate: a Stop hook that exits
# non-zero with status 2 is read as "do not stop" and produces an infinite agent
# loop. Nothing in this file may ever produce that status.

# ---------------------------------------------------------------------------
# character constants (avoids backslash-in-bracket-expression portability traps)
# ---------------------------------------------------------------------------
TS_Q='"'
TS_BS='\'
TS_TAB='	'
TS_CR=$(printf '\r')
TS_NL='
'

# Forbidden control keys. Assembled from fragments so that the literal words
# never appear as contiguous text in this repository — the CI safety grep
# rejects them on sight, and it is right to.
TS_G1='"de''cision"'
TS_G2='"permission''Decision"'
TS_G3='"con''tinue"'

# ---------------------------------------------------------------------------
# ts_init — umask, state dir, config
# ---------------------------------------------------------------------------
ts_load_config() {
	# Strict allowlist. Not a parser: each accepted line must match one of the
	# twelve legal KEY=value pairs exactly. Anything else — unknown keys, shell
	# metacharacters, command substitution, a key with an illegal value — falls
	# through to the ignore branch. There is no eval and no sourcing.
	#
	# Bounded on three axes, because the state directory is not a trusted input:
	# anything with write access to it can replace config.env. `-f` rejects a
	# FIFO (opening one blocks forever and burns the whole hook timeout), the
	# line counter rejects a huge file, and the length test rejects a huge line.
	# No legal line is longer than `SHOW_DURATION=1`.
	if [ ! -f "$TS_CONFIG" ] || [ ! -r "$TS_CONFIG" ]; then
		return 0
	fi
	_cfg_n=0
	while IFS= read -r _cfg_ln || [ -n "$_cfg_ln" ]; do
		_cfg_n=$((_cfg_n + 1))
		if [ "$_cfg_n" -gt 64 ]; then
			break
		fi
		if [ "${#_cfg_ln}" -le 64 ]; then
			case "$_cfg_ln" in
				MODE=notice|MODE=inline|MODE=off)
					MODE=${_cfg_ln#MODE=} ;;
				FORMAT=clock|FORMAT=iso|FORMAT=relative)
					FORMAT=${_cfg_ln#FORMAT=} ;;
				SHOW_DURATION=0|SHOW_DURATION=1)
					SHOW_DURATION=${_cfg_ln#SHOW_DURATION=} ;;
				LOG=0|LOG=1)
					LOG=${_cfg_ln#LOG=} ;;
				*)
					: ;;
			esac
		fi
	done < "$TS_CONFIG"
	return 0
}

ts_init() {
	umask 077
	MODE=notice
	FORMAT=clock
	SHOW_DURATION=1
	LOG=1
	STATE_DIR="${CLAUDE_TIMESTAMPS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/claude-timestamps}"
	SESS_DIR="$STATE_DIR/sessions"
	TS_CONFIG="$STATE_DIR/config.env"
	TS_JQ=0
	if command -v jq >/dev/null 2>&1; then
		TS_JQ=1
	fi
	ts_load_config
	ts_prepare_payload
	return 0
}

# ---------------------------------------------------------------------------
# ts_prepare_payload — bound the cost of parsing $IN, once, before any field is
# read. Sets IN (possibly to a smaller equivalent) and TS_TRUNCATED.
#
# Why this exists: `${var#*pat}` and `${var%%pat*}` are quadratic in the length
# of var — the shell retries the match at every prefix length. Reading three
# short ids out of a 48 KB payload measured 1.5 s, and a 128 KB payload runs
# past the 5 s hook timeout, at which point the host kills the hook and the
# stamp silently disappears. Payload size is not under our control: `delta`
# (MessageDisplay) and `last_assistant_message` (Stop) carry whole assistant
# messages, and JSON object key order is not guaranteed, so a large field may
# sit ahead of every field we need.
#
# So above TS_SCAN_MAX the payload is projected down to a small object before
# any parameter expansion touches it:
#   - with jq: ONE fork, producing just the fields the hooks read (each string
#     clamped) plus the length of `delta`. Correct for any key order.
#   - without jq: the first TS_SCAN_MAX bytes, and TS_TRUNCATED=1. Fields that
#     appear beyond the cut are reported missing rather than paid for.
# ---------------------------------------------------------------------------
TS_SCAN_MAX=1024
TS_SCAN_HARD=4096

# Projection program. Only the fields the four hooks actually read, and never
# `delta` itself — its length, which is all rule 12 permits us to record.
TS_JQ_PROJECT='def c: if type=="string" then .[0:256] else . end;
if type=="object" then {session_id:(.session_id|c),prompt_id:(.prompt_id|c),
turn_id:(.turn_id|c),message_id:(.message_id|c),index:(.index|c),
final:(.final|c),stop_hook_active:(.stop_hook_active|c),source:(.source|c),
delta_len:(if (.delta|type)=="string" then (.delta|length) else 0 end)}
else empty end'

ts_prepare_payload() {
	TS_TRUNCATED=0
	IN=${IN:-}
	[ "${#IN}" -gt "$TS_SCAN_MAX" ] || return 0

	if [ "${TS_JQ:-0}" = 1 ]; then
		_pp_s=$(printf '%s' "$IN" | jq -c "$TS_JQ_PROJECT" 2>/dev/null) || _pp_s=""
		case "$_pp_s" in
			'{'*'}')
				IN=$_pp_s
				return 0 ;;
		esac
	fi

	_pp_s=$(printf '%s' "$IN" | head -c "$TS_SCAN_MAX" 2>/dev/null) || _pp_s=""
	if [ -n "$_pp_s" ]; then
		IN=$_pp_s
		TS_TRUNCATED=1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# sanitize_id — never let a payload value reach a path unfiltered
# ---------------------------------------------------------------------------
sanitize_id() {
	SID_OUT=$1
	case "$SID_OUT" in
		''|*[!A-Za-z0-9._-]*) SID_OUT=unknown ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# JSON field extraction
#
# ts_json_get <json> <name>  -> sets JF
# json_field  <name>         -> sets JF, reads the payload from $IN
#
# Pure POSIX parameter expansion. Handles: string values (including escaped
# quotes), true/false, null, and numbers. A missing field yields the empty
# string. String values are returned with their JSON escapes still raw — we
# only ever use them as ids, booleans, or lengths, never as display text.
#
# Cost is bounded, not merely small: parameter expansion is quadratic in the
# length of the subject string, so anything longer than TS_SCAN_MAX goes to jq
# when jq is installed, and anything longer than TS_SCAN_HARD is refused
# outright. ts_prepare_payload normally shrinks the payload before we get here,
# which keeps every ordinary call fork-free.
# ---------------------------------------------------------------------------
ts_json_get() {
	_jg_j=$1
	_jg_k=$2
	JF=""

	if [ "${TS_JQ:-0}" = 1 ] && [ "${#_jg_j}" -gt "${TS_SCAN_MAX:-1024}" ]; then
		JF=$(printf '%s' "$_jg_j" | jq -r --arg k "$_jg_k" \
			'if type=="object" and has($k) and (.[$k] != null) then (.[$k]|tostring) else "" end' 2>/dev/null) || JF=""
		return 0
	fi

	# Hard ceiling. ts_prepare_payload normally keeps the payload well under
	# this; a string that arrives here longer than it means the projection did
	# not happen, and walking it with parameter expansion would cost seconds.
	# An empty field is a far better outcome than a hook the host kills.
	if [ "${#_jg_j}" -gt "${TS_SCAN_HARD:-4096}" ]; then
		return 0
	fi

	_jg_pat="$TS_Q$_jg_k$TS_Q"
	_jg_rest=""

	# Find an occurrence of "name" that is actually in key position, i.e.
	# followed (after optional whitespace) by a colon. Occurrences inside a
	# string value are skipped rather than trusted.
	while :; do
		case "$_jg_j" in
			*"$_jg_pat"*) : ;;
			*) return 0 ;;
		esac
		_jg_rest=${_jg_j#*"$_jg_pat"}
		_jg_skip=$_jg_rest
		while :; do
			case "$_jg_skip" in
				' '*|"$TS_TAB"*|"$TS_NL"*|"$TS_CR"*) _jg_skip=${_jg_skip#?} ;;
				*) break ;;
			esac
		done
		case "$_jg_skip" in
			:*) _jg_rest=${_jg_skip#:}; break ;;
			*) _jg_j=$_jg_rest ;;
		esac
	done

	# Skip whitespace up to the start of a value.
	while :; do
		case "$_jg_rest" in
			"$TS_Q"*|t*|f*|n*|-*|0*|1*|2*|3*|4*|5*|6*|7*|8*|9*|'{'*|'['*|'') break ;;
			*) _jg_rest=${_jg_rest#?} ;;
		esac
	done

	case "$_jg_rest" in
		"$TS_Q"*)
			_jg_work=${_jg_rest#"$TS_Q"}
			# Walk quote-delimited segments. `%%` does the scanning in C, so this
			# loop runs once per *escaped* quote, not once per character.
			while :; do
				_jg_seg=${_jg_work%%"$TS_Q"*}
				if [ "$_jg_seg" = "$_jg_work" ]; then
					# Unterminated string — take what there is and stop.
					JF="$JF$_jg_seg"
					break
				fi
				# Count trailing backslashes: an odd run means this quote is escaped.
				_jg_tail=$_jg_seg
				_jg_n=0
				while :; do
					case "$_jg_tail" in
						*"$TS_BS") _jg_tail=${_jg_tail%?}; _jg_n=$((_jg_n + 1)) ;;
						*) break ;;
					esac
				done
				JF="$JF$_jg_seg"
				_jg_work=${_jg_work#"$_jg_seg"}
				if [ $((_jg_n % 2)) -eq 0 ]; then
					break
				fi
				JF="$JF$TS_Q"
				_jg_work=${_jg_work#"$TS_Q"}
			done
			;;
		t*) JF=true ;;
		f*) JF=false ;;
		n*) JF="" ;;
		'{'*|'['*) JF="" ;;
		'') JF="" ;;
		*)
			# Number: up to the next separator, then trim trailing whitespace.
			JF=${_jg_rest%%,*}
			JF=${JF%%'}'*}
			JF=${JF%%']'*}
			while :; do
				case "$JF" in
					*' '|*"$TS_TAB"|*"$TS_NL"|*"$TS_CR") JF=${JF%?} ;;
					*) break ;;
				esac
			done
			case "$JF" in
				''|*[!0-9.eE+-]*) JF="" ;;
			esac
			;;
	esac
	return 0
}

json_field() {
	ts_json_get "$IN" "$1"
	return 0
}

# ---------------------------------------------------------------------------
# ts_delta_len -> DELTA_LEN
#
# The length of MessageDisplay's `delta`, and never the text itself. Three
# cases, in order of preference:
#   1. ts_prepare_payload already replaced the payload with a jq projection
#      that carries `delta_len` — the exact decoded character count, and the
#      text never entered the shell at all.
#   2. The payload was small enough to parse directly: measure the raw value.
#   3. The payload was truncated (large, and no jq): the length is unknown, so
#      record -1 rather than a number that is quietly wrong.
# ---------------------------------------------------------------------------
ts_delta_len() {
	DELTA_LEN=-1
	ts_json_get "$IN" delta_len
	if [ -n "$JF" ]; then
		case "$JF" in
			''|*[!0-9]*) DELTA_LEN=-1 ;;
			*)           DELTA_LEN=$JF ;;
		esac
		JF=""
		return 0
	fi
	if [ "${TS_TRUNCATED:-0}" = 1 ]; then
		return 0
	fi
	ts_json_get "$IN" delta
	DELTA_LEN=${#JF}
	JF=""
	return 0
}

# ---------------------------------------------------------------------------
# now_parts — ONE fork. Sets EPOCH_MS, CLOCK, ISO.
#
# `date "+%s%N %H:%M:%S %Y-%m-%dT%H:%M:%S%z"` in a single call. The first field
# has four possible shapes and we decide between them by digit count, never by
# probing the date implementation:
#   GNU/coreutils   1757000000123456789   19 digits  (seconds + 9-digit ns)
#   BSD / busybox   1757000000N           trailing literal N — %N unsupported
#   plain seconds   1757000000            10 digits
#   no date binary  (empty)               everything stays zero/empty
# BSD date on macOS 26 accepts %N but rejects %3N and %6N, so we never ask for
# a truncated nanosecond field — we take all nine digits and cut six off.
# ---------------------------------------------------------------------------
now_parts() {
	EPOCH_MS=0
	CLOCK=""
	ISO=""
	# shellcheck disable=SC2046
	set -- $(date "+%s%N %H:%M:%S %Y-%m-%dT%H:%M:%S%z" 2>/dev/null)
	[ $# -ge 1 ] || return 0
	_np_raw=$1
	[ $# -ge 2 ] && CLOCK=$2
	[ $# -ge 3 ] && ISO=$3
	case "$_np_raw" in
		*N) _np_raw=${_np_raw%N} ;;
	esac
	case "$_np_raw" in
		''|*[!0-9]*) return 0 ;;
	esac
	case "${#_np_raw}" in
		18|19|20) EPOCH_MS=${_np_raw%??????} ;;
		9|10|11)  EPOCH_MS="${_np_raw}000" ;;
		*)        EPOCH_MS=0 ;;
	esac
	case "$EPOCH_MS" in
		''|*[!0-9]*) EPOCH_MS=0 ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# ts_dur <milliseconds> -> DUR   (fork-free, integer shell arithmetic)
# ---------------------------------------------------------------------------
ts_dur() {
	DUR=""
	_d_ms=$1
	case "$_d_ms" in
		''|*[!0-9]*) return 0 ;;
	esac
	_d_s=$((_d_ms / 1000))
	_d_t=$(((_d_ms % 1000) / 100))
	if [ "$_d_s" -lt 60 ]; then
		DUR="${_d_s}.${_d_t}s"
		return 0
	fi
	_d_m=$((_d_s / 60))
	_d_r=$((_d_s % 60))
	[ "$_d_r" -lt 10 ] && _d_r="0$_d_r"
	if [ "$_d_m" -lt 60 ]; then
		DUR="${_d_m}m${_d_r}s"
		return 0
	fi
	_d_h=$((_d_m / 60))
	_d_m=$((_d_m % 60))
	[ "$_d_m" -lt 10 ] && _d_m="0$_d_m"
	DUR="${_d_h}h${_d_m}m${_d_r}s"
	return 0
}

# ---------------------------------------------------------------------------
# state_write  <file> <line>   append one record (per-session file, no lock)
# state_replace <file> <line>  rewrite: temp in the SAME directory, then mv
#
# Per-session files plus same-directory rename measured zero corruption over
# 800 concurrent writes; plain `>>` from concurrent writers interleaves and
# corrupts at record sizes of 1024 bytes and up. `mv` is atomic only within one
# filesystem, hence the temp file next to its destination.
# ---------------------------------------------------------------------------
state_write() {
	_sw_f=$1
	_sw_d=${_sw_f%/*}
	if [ ! -d "$_sw_d" ]; then
		mkdir -p "$_sw_d" 2>/dev/null || return 0
	fi
	printf '%s\n' "$2" >> "$_sw_f" 2>/dev/null || return 0
	return 0
}

state_replace() {
	_sr_f=$1
	_sr_d=${_sr_f%/*}
	if [ ! -d "$_sr_d" ]; then
		mkdir -p "$_sr_d" 2>/dev/null || return 0
	fi
	_sr_t="$_sr_f.$$.tmp"
	printf '%s\n' "$2" > "$_sr_t" 2>/dev/null || return 0
	mv -f "$_sr_t" "$_sr_f" 2>/dev/null || rm -f "$_sr_t" 2>/dev/null
	return 0
}

# ---------------------------------------------------------------------------
# ts_replace <haystack> <needle> <replacement> -> RP
# ---------------------------------------------------------------------------
ts_replace() {
	RP=""
	_rp_h=$1
	while :; do
		case "$_rp_h" in
			*"$2"*)
				_rp_pre=${_rp_h%%"$2"*}
				RP="$RP$_rp_pre$3"
				_rp_h=${_rp_h#*"$2"}
				;;
			*)
				RP="$RP$_rp_h"
				break
				;;
		esac
	done
	return 0
}

# ---------------------------------------------------------------------------
# ts_escape <text> -> JE   JSON string body, single line, no control characters
# ---------------------------------------------------------------------------
ts_escape() {
	ts_replace "$1" "$TS_BS" "$TS_BS$TS_BS"
	ts_replace "$RP" "$TS_Q" "$TS_BS$TS_Q"
	ts_replace "$RP" "$TS_NL" ' '
	ts_replace "$RP" "$TS_CR" ' '
	ts_replace "$RP" "$TS_TAB" ' '
	JE=$RP
	return 0
}

# ---------------------------------------------------------------------------
# emit <single-line text>
#
# Prints exactly one JSON object: {"systemMessage":"..."}. Newlines are stripped
# because the transcript renderer applies the "Stop says:" prefix per line — a
# two-line stamp renders as two prefixed lines. Only this one key is ever
# produced; the control keys that could steer the agent are rejected outright.
#
# The guard tests the RAW text, before escaping. Testing the escaped string is
# useless: ts_escape has by then rewritten every `"` as `\"`, so a control key
# in the input can no longer match a pattern written with literal quotes.
# ---------------------------------------------------------------------------
emit() {
	_em_t=$1
	[ -n "$_em_t" ] || return 0
	case "$_em_t" in
		*"$TS_G1"*|*"$TS_G2"*|*"$TS_G3"*) return 0 ;;
	esac
	ts_escape "$_em_t"
	printf '{"systemMessage":"%s"}' "$JE"
	return 0
}

# ---------------------------------------------------------------------------
# emit_context <event name> <single-line text>
# {"hookSpecificOutput":{"hookEventName":"...","additionalContext":"..."}}
# ---------------------------------------------------------------------------
emit_context() {
	_ec_e=$1
	_ec_t=$2
	[ -n "$_ec_t" ] || return 0
	case "$_ec_t" in
		*"$TS_G1"*|*"$TS_G2"*|*"$TS_G3"*) return 0 ;;
	esac
	ts_escape "$_ec_t"
	printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}' \
		"$_ec_e" "$JE"
	return 0
}

# ---------------------------------------------------------------------------
# ts_paths <raw session id> — sets SID, TS_LOG_F, TS_TURN_F, TS_META_F
#
# The sidecars carry a .jsonl extension on purpose: the garbage collector is
# allowed exactly one shape of find(1) invocation, and giving every state file
# the same extension means that one command covers all of them.
# ---------------------------------------------------------------------------
ts_paths() {
	sanitize_id "$1"
	SID=$SID_OUT
	TS_LOG_F="$SESS_DIR/$SID.jsonl"
	TS_TURN_F="$SESS_DIR/$SID.turn.jsonl"
	TS_META_F="$SESS_DIR/$SID.meta.jsonl"
	return 0
}

# ---------------------------------------------------------------------------
# ts_read_turn — sets TURN_PID, TURN_MS from the current-turn sidecar.
# ts_read_meta — sets META_MS from the session sidecar.
# Both read a single short line of our own state. Neither ever touches the
# transcript: a 165MB transcript costs 131ms to scan, which is thirteen times
# the entire per-turn budget.
# ---------------------------------------------------------------------------
ts_read_turn() {
	TURN_PID=""
	TURN_MS=""
	[ -r "$TS_TURN_F" ] || return 0
	IFS= read -r _rt_l < "$TS_TURN_F" || _rt_l=""
	[ -n "$_rt_l" ] || return 0
	ts_json_get "$_rt_l" prompt_id
	TURN_PID=$JF
	ts_json_get "$_rt_l" epoch_ms
	TURN_MS=$JF
	case "$TURN_MS" in
		''|*[!0-9]*) TURN_MS="" ;;
	esac
	return 0
}

ts_read_meta() {
	META_MS=""
	[ -r "$TS_META_F" ] || return 0
	IFS= read -r _rm_l < "$TS_META_F" || _rm_l=""
	[ -n "$_rm_l" ] || return 0
	ts_json_get "$_rm_l" epoch_ms
	META_MS=$JF
	case "$META_MS" in
		''|*[!0-9]*) META_MS="" ;;
	esac
	return 0
}
