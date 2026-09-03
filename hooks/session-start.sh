#!/bin/sh
# claude-timestamps — SessionStart.
#
# Creates the state directory, writes a default config on first run, records the
# session's start time (used by FORMAT=relative), and runs the garbage collector.
# Emits nothing. This is the only hook allowed to do housekeeping: it runs once
# per session, so a few forks here cost nothing, whereas a per-turn hook costs
# about 9 ms in total and pays that on every turn.

umask 077

IN=$(cat)

TS_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib.sh"
[ -r "$TS_LIB" ] && . "$TS_LIB"

ts_session_start_main() {
	ts_init

	json_field session_id
	ts_paths "$JF"

	[ -d "$SESS_DIR" ] || mkdir -p "$SESS_DIR" 2>/dev/null || return 0

	# Default config, written only when absent so the user's edits survive.
	if [ ! -e "$TS_CONFIG" ]; then
		{
			printf '%s\n' '# claude-timestamps configuration.'
			printf '%s\n' '# Only these four keys with these exact values are read.'
			printf '%s\n' '# Anything else on a line is ignored, not evaluated.'
			printf '%s\n' 'MODE=notice'
			printf '%s\n' 'FORMAT=clock'
			printf '%s\n' 'SHOW_DURATION=1'
			printf '%s\n' 'LOG=1'
		} > "$TS_CONFIG.$$.tmp" 2>/dev/null || return 0
		mv -f "$TS_CONFIG.$$.tmp" "$TS_CONFIG" 2>/dev/null || rm -f "$TS_CONFIG.$$.tmp" 2>/dev/null
	fi

	now_parts

	# Session origin, written once. A resumed or compacted session reports the
	# same session_id, and the original start is the one we want to measure from.
	if [ ! -e "$TS_META_F" ] && [ "$EPOCH_MS" != 0 ]; then
		json_field source
		sanitize_id "$JF"
		state_replace "$TS_META_F" \
			"{\"t\":\"session_start\",\"epoch_ms\":$EPOCH_MS,\"clock\":\"$CLOCK\",\"source\":\"$SID_OUT\"}"
	fi

	# Garbage collection. Triple-constrained on purpose: depth, file type, and
	# name, plus an age test. Every state file this plugin writes ends in .jsonl
	# so this single invocation covers all of them. The state directory itself is
	# never removed, and nothing recursive ever runs here.
	if [ -d "$SESS_DIR" ]; then
		find "$SESS_DIR" -maxdepth 1 -type f -name '*.jsonl' -mtime +7 -exec rm -f {} + 2>/dev/null
	fi

	return 0
}

out=$( ts_session_start_main 2>/dev/null ) || out=""
case "$out" in
	*"$TS_G1"*|*"$TS_G2"*|*"$TS_G3"*) out="" ;;
esac
case "$out" in
	'{'*) : ;;
	*) out="" ;;
esac
[ -n "$out" ] && printf '%s\n' "$out"

exit 0
